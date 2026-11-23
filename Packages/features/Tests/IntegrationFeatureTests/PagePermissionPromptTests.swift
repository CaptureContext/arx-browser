import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Arx's site permission prompt (DEV-963): the request read from the ABI31 dialog MCP reads,
/// one answer per prompt, Cancel as a dismissal, and the `ARX_PAGE_PROMPTS` feature flag.
@Suite(.dependencies)
@MainActor
internal struct PagePermissionPromptTests {
	// MARK: - Reading the request

	@Test
	internal func aPermissionDialogNamesTheSiteAndItsPermissions() throws {
		let dialog = BrowserPageDialog(
			token: "a1",
			kind: .permission,
			message: "Use your camera\nUse your microphone",
			origin: "https://meet.example.com"
		)

		let request = try #require(PagePermissionRequest(dialog: dialog))

		expectNoDifference(request, .init(token: "a1", site: "meet.example.com", permissions: [.camera, .microphone]))
	}

	@Test
	internal func anEmbeddedFrameNamesItsEmbedderAndKeepsUnknownWording() throws {
		let dialog = BrowserPageDialog(
			token: "b2",
			kind: .permission,
			message: "See text and images copied to the clipboard\nControl and reprogram your MIDI devices",
			origin: "https://docs.example.com\nEmbedded in https://notes.example.org"
		)

		let request = try #require(PagePermissionRequest(dialog: dialog))

		expectNoDifference(request.site, "docs.example.com")
		expectNoDifference(request.embedder, "notes.example.org")
		expectNoDifference(request.permissions, [.clipboard])
		expectNoDifference(request.otherRequests, ["Control and reprogram your MIDI devices"])

		// ABI31 can't say either, so neither shows yet.
		#expect(!request.offersAllowOnce)
		#expect(request.accuracies.isEmpty)
	}

	@Test
	internal func otherSchemesStayAndOtherDialogsAreNoPermissionRequest() {
		let local = BrowserPageDialog(token: "c3", kind: .permission, message: "Show notifications", origin: "http://localhost:8080")
		expectNoDifference(PagePermissionRequest(dialog: local)?.site, "http://localhost:8080")
		expectNoDifference(PagePermissionRequest(dialog: local)?.permissions, [.notifications])

		#expect(PagePermissionRequest(dialog: .init(token: "d4", kind: .confirm, message: "Sure?")) == nil)
		#expect(PagePermissionRequest(dialog: .init(token: "e5", kind: .permission, message: "Show notifications")) == nil)
	}

	// MARK: - Answering

	@Test
	internal func allowAnswersOnceWithThePickedAccuracy() async {
		let request = PagePermissionRequest(
			token: "f6",
			site: "maps.example.com",
			permissions: [.location],
			offersAllowOnce: true,
			accuracies: [.approximate, .precise]
		)
		let store = TestStore(initialState: Self.state(request)) { PagePermissionPrompt() }

		await store.send(.ui(.accuracyChanged(.precise))) { $0.accuracy = .precise }
		await store.send(.ui(.allowOnce)) { $0.isAnswered = true }
		await store.receive(\.delegate.answered, .init(token: "f6", decision: .allowOnce, accuracy: .precise))

		// A second press while the host closes the prompt does nothing.
		await store.send(.ui(.allow))
		await store.send(.ui(.accuracyChanged(.approximate)))
	}

	@Test
	internal func cancelDismissesAndNeverBlocks() async {
		let request = PagePermissionRequest(token: "g7", site: "github.com", permissions: [.notifications])
		let store = TestStore(initialState: Self.state(request)) { PagePermissionPrompt() }

		await store.send(.ui(.cancel)) { $0.isAnswered = true }
		await store.receive(\.delegate.answered, .init(token: "g7", decision: .dismiss, accuracy: nil))
	}

	@Test
	internal func blockAnswersAndAllowOnceNeedsAnOffer() async {
		let request = PagePermissionRequest(token: "h8", site: "github.com", permissions: [.notifications])
		let store = TestStore(initialState: Self.state(request)) { PagePermissionPrompt() }

		// Not offered: nothing happens.
		await store.send(.ui(.allowOnce))
		await store.send(.ui(.accuracyChanged(.precise)))
		await store.send(.ui(.block)) { $0.isAnswered = true }
		await store.receive(\.delegate.answered, .init(token: "h8", decision: .block, accuracy: nil))
	}

	// MARK: - Feature flag

	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let defaults = try #require(UserDefaults(suiteName: "PagePermissionPromptTests-\(UUID().uuidString)"))

		// On by default (DEV-1143).
		#expect(PagePrompts.isEnabled(environment: [:], defaults: defaults))

		defaults.set("no", forKey: PagePrompts.featureFlag)
		#expect(!PagePrompts.isEnabled(environment: [:], defaults: defaults))
		// The environment wins over defaults.
		#expect(PagePrompts.isEnabled(environment: [PagePrompts.featureFlag: "1"], defaults: defaults))
		#expect(!PagePrompts.isEnabled(environment: [PagePrompts.featureFlag: "0"], defaults: .init(suiteName: UUID().uuidString)!))
	}

	private static func state(_ request: PagePermissionRequest) -> PagePermissionPrompt.State {
		.init(windowID: UUID(1), tabID: .init(rawValue: UUID(2)), request: request)
	}
}
