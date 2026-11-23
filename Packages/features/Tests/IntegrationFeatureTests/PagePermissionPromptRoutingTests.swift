import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Site permission prompts the engine hands to the app (DEV-963, ABI56): each shows on its page's
/// own window, answers go back to the engine for that token with the person's whole decision, a
/// withdrawn prompt goes away, and a page no window shows is dismissed, never blocked.
@Suite(.dependencies)
@MainActor
internal struct PagePermissionPromptRoutingTests {
	private static let tab = BrowserCore.Tab.ID(rawValue: UUID(3))
	private static let hidden = BrowserCore.Tab.ID(rawValue: UUID(4))

	private struct Answer: Equatable, Sendable {
		var tab: BrowserCore.Tab.ID
		var token: UInt64
		var decision: BrowserPagePermissionDecision
		var accuracy: BrowserPagePermissionPrompt.Accuracy?
	}

	private static func prompt(
		_ token: UInt64,
		permissions: [String] = ["notifications"],
		allowOnce: Bool = false,
		location: BrowserPagePermissionPrompt.Location? = nil,
		quiet: Bool = false
	) -> BrowserPagePermissionPrompt {
		.init(
			token: token,
			variant: .ask,
			requestingOrigin: "https://github.com",
			embeddingOrigin: nil,
			permissions: permissions,
			fragments: permissions.map { "Use \($0)" },
			allowOnce: allowOnce,
			location: location,
			quiet: quiet
		)
	}

	private static func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: tab]
		return state
	}

	private static func store(
		_ state: AppFeature.State = Self.state(),
		prompts: [UInt64: BrowserPagePermissionPrompt],
		answers: LockIsolated<[Answer]>
	) -> TestStoreOf<AppFeature> {
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine.pagePermissionPrompt = { _, token in prompts[token] }
			$0.browserEngine.answerPagePermissionPrompt = { tab, token, decision, accuracy in
				answers.withValue { $0.append(.init(tab: tab, token: token, decision: decision, accuracy: accuracy)) }
				return .answered
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	@Test
	internal func aPromptShowsOnItsPagesWindowAndEachAnswerReachesTheEngine() async {
		let cases: [(PagePermissionPrompt.Action.UI, BrowserPagePermissionDecision)] = [
			(.allow, .allow),
			(.allowOnce, .allowOnce),
			(.block, .block),
			// Cancel, and Esc closing the sheet, dismiss: the page may ask again.
			(.cancel, .dismiss),
		]
		for (ui, decision) in cases {
			let answers = LockIsolated<[Answer]>([])
			let store = Self.store(prompts: [7: Self.prompt(7, allowOnce: true)], answers: answers)

			await store.send(.event(.pagePermissionPromptChanged(Self.tab, 7)))
			let prompt = store.state.pagePermissionPrompts.first
			expectNoDifference(prompt?.windowID, store.state.main.id)
			expectNoDifference(prompt?.request.site, "github.com")
			expectNoDifference(prompt?.request.permissions, [.notifications])
			#expect(prompt?.request.offersAllowOnce == true)
			#expect(prompt?.isRevealed == true)

			await store.send(.pagePermissionPrompts(.element(id: "7", action: .ui(ui))))
			await store.receive(\.pagePermissionPrompts)
			await store.finish()
			#expect(store.state.pagePermissionPrompts.isEmpty)
			expectNoDifference(answers.value, [.init(tab: Self.tab, token: 7, decision: decision, accuracy: nil)])
		}
	}

	@Test
	internal func aLocationPromptAnswersWithThePickedAccuracy() async {
		let answers = LockIsolated<[Answer]>([])
		let location = BrowserPagePermissionPrompt.Location(choice: .either, initial: .approximate)
		let store = Self.store(
			prompts: [9: Self.prompt(9, permissions: ["geolocation"], allowOnce: true, location: location)],
			answers: answers
		)

		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 9)))
		expectNoDifference(store.state.pagePermissionPrompts.first?.request.accuracies, [.approximate, .precise])
		await store.send(.pagePermissionPrompts(.element(id: "9", action: .ui(.accuracyChanged(.precise)))))
		await store.send(.pagePermissionPrompts(.element(id: "9", action: .ui(.allowOnce))))
		await store.finish()

		expectNoDifference(answers.value, [.init(tab: Self.tab, token: 9, decision: .allowOnce, accuracy: .precise)])
	}

	@Test
	internal func aWithdrawnPromptGoesAwayAndANewOneReplacesIt() async {
		let answers = LockIsolated<[Answer]>([])
		let store = Self.store(prompts: [7: Self.prompt(7), 8: Self.prompt(8)], answers: answers)

		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 7)))
		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 8)))
		expectNoDifference(store.state.pagePermissionPrompts.map(\.id), ["8"])

		// The page closed, navigated or was answered elsewhere.
		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 0)))
		#expect(store.state.pagePermissionPrompts.isEmpty)
		await store.finish()
		#expect(answers.value.isEmpty)
	}

	@Test
	internal func aPromptNoWindowShowsIsDismissedNeverBlocked() async {
		let answers = LockIsolated<[Answer]>([])
		let store = Self.store(prompts: [5: Self.prompt(5)], answers: answers)

		await store.send(.event(.pagePermissionPromptChanged(Self.hidden, 5)))
		await store.finish()

		#expect(store.state.pagePermissionPrompts.isEmpty)
		expectNoDifference(answers.value, [.init(tab: Self.hidden, token: 5, decision: .dismiss, accuracy: nil)])
	}

	@Test
	internal func aPeeksPromptShowsOnTheWindowItOpenedOver() async {
		let answers = LockIsolated<[Answer]>([])
		var state = Self.state()
		let tab = BrowserCore.Tab(
			id: .init(rawValue: UUID(80)),
			profileID: state.main.sidebar.space.profileID,
			restoration: .init(title: "Peek", url: URL(string: "https://github.com")!)
		)
		state.peeks.append(.init(
			id: UUID(81),
			source: .init(
				windowID: state.main.id,
				paneID: state.main.viewer.activePaneID,
				tabID: Self.tab,
				spaceID: state.main.sidebar.spaceID,
				profileID: tab.profileID,
				identity: "Fixture"
			),
			tab: tab,
			isTemporary: true
		))
		state.peeks[id: UUID(81)]?.viewer = .init(tab: tab)
		let store = Self.store(state, prompts: [5: Self.prompt(5)], answers: answers)

		await store.send(.event(.pagePermissionPromptChanged(tab.id, 5)))

		expectNoDifference(store.state.pagePermissionPrompts.first?.windowID, store.state.main.id)
		#expect(answers.value.isEmpty)
	}

	@Test
	internal func aPageFloatingInPictureInPictureIsDismissed() async {
		let answers = LockIsolated<[Answer]>([])
		var state = Self.state()
		state.pagePictureInPicture = .init(tabID: Self.tab, windowID: state.main.id)
		let store = Self.store(state, prompts: [5: Self.prompt(5)], answers: answers)

		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 5)))
		await store.finish()

		#expect(store.state.pagePermissionPrompts.isEmpty)
		expectNoDifference(answers.value, [.init(tab: Self.tab, token: 5, decision: .dismiss, accuracy: nil)])
	}

	@Test
	internal func anUnattendedRunDismissesAndAnUnreadablePromptIsLeftAlone() async {
		let answers = LockIsolated<[Answer]>([])
		var state = Self.state()
		state.automation.isUnattended = true
		let store = Self.store(state, prompts: [5: Self.prompt(5)], answers: answers)

		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 5)))

		// Gone before Arx read it: nothing to show or answer.
		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 6)))
		await store.finish()

		#expect(store.state.pagePermissionPrompts.isEmpty)
		expectNoDifference(answers.value, [.init(tab: Self.tab, token: 5, decision: .dismiss, accuracy: nil)])
	}

	@Test
	internal func aQuietRequestWaitsBehindItsAffordance() async {
		let answers = LockIsolated<[Answer]>([])
		let store = Self.store(prompts: [7: Self.prompt(7, quiet: true)], answers: answers)

		await store.send(.event(.pagePermissionPromptChanged(Self.tab, 7)))
		#expect(store.state.pagePermissionPrompts.first?.isRevealed == false)

		await store.send(.pagePermissionPrompts(.element(id: "7", action: .ui(.review))))
		#expect(store.state.pagePermissionPrompts.first?.isRevealed == true)
		#expect(answers.value.isEmpty)
	}

	@Test
	internal func theEnginePromptMapsToWhatThePromptShows() {
		let upgrade = BrowserPagePermissionPrompt.Location(choice: .upgradeToPrecise, initial: .precise)
		var prompt = Self.prompt(3, permissions: ["camera", "microphone", "midi"], location: upgrade)
		prompt.embeddingOrigin = "https://notes.example.org"
		prompt.requestingOrigin = "http://localhost:8080"

		let request = PagePermissionRequest(prompt: prompt)

		expectNoDifference(request.token, "3")
		expectNoDifference(request.site, "http://localhost:8080")
		expectNoDifference(request.embedder, "notes.example.org")
		expectNoDifference(request.permissions, [.camera, .microphone])
		expectNoDifference(request.otherRequests, ["Use midi"])

		// An upgrade to precise leaves one accuracy: shown, not picked.
		expectNoDifference(request.accuracies, [.precise])
		expectNoDifference(request.initialAccuracy, .precise)
	}
}
