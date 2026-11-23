import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Open Focused Link in Peek (DEV-713).
@Suite(.dependencies)
@MainActor
internal struct FocusedLinkPeekTests {
	private static let link = URL(string: "https://child.example/focused")!

	private func state(isPrivate: Bool = false) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = withDependencies {
			$0.workspaceDocument = .unsaved(.init())
		} operation: {
			AppFeature.State(main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id,
				isPrivate: isPrivate
			))
		}
		state.main.sidebar.select(organization.spaces[0].unpinnedTabs[0])
		state.main.viewer.item.tab = organization.tabs[id: organization.spaces[0].unpinnedTabs[0]]
		return state
	}

	private func focusedLink(
		_ state: AppFeature.State,
		url: URL = link,
		sessionRevision: UInt64 = 3,
		isPrivate: Bool = false
	) -> BrowserFocusedLink {
		let tab = state.main.viewer.item.tab!
		return .init(
			sourceTabID: tab.id,
			profileID: tab.profileID,
			sourceSessionRevision: sessionRevision,
			sourceDocumentRevision: 7,
			url: url,
			isPrivate: isPrivate
		)
	}

	private func store(
		_ state: AppFeature.State,
		answer: BrowserFocusedLink?,
		asked: LockIsolated<[BrowserCore.Tab.ID]>
	) -> TestStoreOf<AppFeature> {
		let profileID = state.main.viewer.item.tab!.profileID
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserSurface = .init(attach: { _, _ in }, detach: { _ in })
			$0.uuid = .incrementing
			$0.browserEngine.open = { _ in }
			$0.browserEngine.close = { _ in }
			$0.browserEngine.snapshot = { _ in
				.init(navigation: .init(), revision: 3, documentRevision: 7, nativeProfileID: profileID)
			}
			$0.browserEngine.focusedLink = { id in
				asked.withValue { $0.append(id) }
				return answer
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		return store
	}

	private func target(_ state: AppFeature.State) -> AppFeature.CommandTarget {
		.window(state.main.id, paneID: state.main.viewer.activePaneID)
	}

	@Test
	internal func theCommandOpensTheFocusedLinkInPeekFromThePane() async throws {
		let state = state()
		let asked = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = store(state, answer: focusedLink(state), asked: asked)

		await store.send(.ui(.command(.openFocusedLinkInPeek, target(state))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(asked.value, [state.main.viewer.item.tab!.id])
		let peek = try #require(store.state.peeks.first)
		expectNoDifference(peek.tab.restoration.url, Self.link)
		expectNoDifference(peek.origin, nil)
		expectNoDifference(peek.source.windowID, state.main.id)
	}

	@Test
	internal func noFocusedLinkOpensNothing() async {
		let state = state()
		let asked = LockIsolated<[BrowserCore.Tab.ID]>([])
		let store = store(state, answer: nil, asked: asked)

		await store.send(.ui(.command(.openFocusedLinkInPeek, target(state))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		expectNoDifference(asked.value.count, 1)
		#expect(store.state.peeks.isEmpty)
	}

	@Test
	internal func staleAnswersPrivatePagesAndOtherSchemesOpenNothing() async {
		let state = state()
		let answers = [
			focusedLink(state, sessionRevision: 4),
			focusedLink(state, isPrivate: true),
			focusedLink(state, url: URL(string: "mailto:someone@example.com")!),
		]
		for answer in answers {
			let store = store(state, answer: answer, asked: .init([]))
			await store.send(.ui(.command(.openFocusedLinkInPeek, target(state))))
			await store.finish()
			await store.skipReceivedActions(strict: false)
		await store.skipReceivedActions(strict: false)
			#expect(store.state.peeks.isEmpty, "\(answer)")
		}
	}

	@Test
	internal func privateWindowsAndPeekNeverAskTheEngine() async throws {
		let privateState = state(isPrivate: true)
		let asked = LockIsolated<[BrowserCore.Tab.ID]>([])
		let privateStore = store(privateState, answer: focusedLink(privateState), asked: asked)
		await privateStore.send(.ui(.command(.openFocusedLinkInPeek, target(privateState))))
		await privateStore.finish()
		await privateStore.skipReceivedActions(strict: false)
		#expect(privateStore.state.peeks.isEmpty)

		// Inside Peek the command is unavailable, so the page under it is never read.
		let state = state()
		let opened = store(state, answer: focusedLink(state), asked: asked)
		await opened.send(.ui(.command(.openFocusedLinkInPeek, target(state))))
		await opened.finish()
		await opened.skipReceivedActions(strict: false)
		let peek = try #require(opened.state.peeks.first)
		asked.setValue([])
		await opened.send(.ui(.command(.openFocusedLinkInPeek, .peek(peek.id))))
		await opened.finish()
		await opened.skipReceivedActions(strict: false)
		#expect(asked.value.isEmpty)
		expectNoDifference(opened.state.peeks.count, 1)
	}

	@Test
	internal func aPageInsidePeekNeverOpensAnotherPeek() throws {
		let state = state()
		let tab = state.main.viewer.item.tab!
		let placement = try #require(
			state.nativeContentPlacement(tabID: tab.id, profileID: tab.profileID, isPrivate: false)
		)
		let nested = LinkContextPlacement(
			windowID: placement.windowID,
			paneID: placement.paneID,
			peekID: UUID(),
			generation: placement.generation
		)
		#expect(state.linkOpenAction(Self.link, route: .peek, placement: nested, origin: nil) == nil)
	}

	@Test
	internal func theDefaultShortcutIsFreeAndCanBeRebound() throws {
		var preferences = BrowserPreferences()
		let shortcut = try #require(preferences.shortcut(for: .openFocusedLinkInPeek))
		expectNoDifference(shortcut, .init(key: "p", modifiers: [.command, .shift]))
		expectNoDifference(preferences.conflicts(for: shortcut, excluding: .openFocusedLinkInPeek), [])
		#expect(!shortcut.isReserved)
		try preferences.validateKeyboardShortcuts()

		preferences.setShortcut(.init(key: "o", modifiers: [.command, .option]), for: .openFocusedLinkInPeek)
		try preferences.validateKeyboardShortcuts()
		expectNoDifference(
			preferences.shortcut(for: .openFocusedLinkInPeek),
			.init(key: "o", modifiers: [.command, .option])
		)
	}
}
