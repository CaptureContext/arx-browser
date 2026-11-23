import AppFeature
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import SidebarFeature
import Testing
import ViewerItemFeature
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct IntegrationFeatureTests {
	@Test
	func explicitTabNameSurvivesNavigationReselectionAndPersistence() async throws {
		let organization = fixture()
		let tab = organization.tabs[0]
		let sidebar = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { SidebarFeature() }

		await sidebar.send(.ui(.sidebar(.rename(.tab(tab.id.rawValue), "My reference")))) {
			$0.organization.tabs[0].customTitle = "My reference"
			$0.undo.append(.init(before: organization, spaceID: organization.spaces[0].id))
		}

		let main = TestStore(initialState: MainFeature.State(
			organization: sidebar.state.organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() }
		await main.send(.viewer(.item(.delegate(.navigation(tab.id, .init(
			url: URL(string: "https://capturecontext.dev/next"),
			title: "Updated page title"
		)))))) {
			$0.sidebar.organization.tabs[0].restoration.title = "Updated page title"
			$0.sidebar.organization.tabs[0].restoration.url = URL(string: "https://capturecontext.dev/next")!
		}
		await main.receive(\.delegate.organizationChanged)

		var selection = main.state.sidebar
		selection.select(organization.tabs[1].id)
		selection.select(tab.id)
		expectNoDifference(selection.tabItem(tab.id)?.title, "My reference")
		expectNoDifference(main.state.commandCandidates.first?.presentation.title, "My reference")

		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserWorkspaceClient(file: directory.appendingPathComponent("workspace.json"))
		try client.save(selection.organization)
		let restored = try #require(try client.load())
		expectNoDifference(restored.tabs[0].displayTitle, "My reference")
		expectNoDifference(restored.tabs[0].restoration.title, "Updated page title")

		var pinned = restored
		try pinned.move(.tab(tab.id.rawValue), to: .savedRoot, in: selection.spaceID)
		expectNoDifference(pinned.tabs[0].savedDestination?.title, "My reference")
		try pinned.move(.tab(tab.id.rawValue), to: .unpinnedRoot, in: selection.spaceID)
		expectNoDifference(pinned.tabs[0].displayTitle, "My reference")
	}

	@Test
	func provisionalAndFailedNavigationPreserveRestoration() async {
		let organization = fixture()
		let tab = organization.tabs[0]
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) {
			MainFeature()
		}
		await store.send(.viewer(.item(.delegate(.navigation(tab.id, .init(
			url: URL(string: "about:blank"),
			title: "about:blank",
			isLoading: true
		))))))
		await store.send(.viewer(.item(.delegate(.navigation(tab.id, .init(
			url: URL(string: "https://failed.example"),
			title: "Failed",
			errorCode: -105
		))))))
		expectNoDifference(store.state.sidebar.organization, organization)
	}

	@Test
	func viewerRejectsEventsFromOldTabsAndOldSubscriptions() async throws {
		let tab = fixture().tabs[1]
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 2)) {
			ViewerItemFeature()
		}
		let navigation = BrowserNavigation(
			url: URL(string: "https://capturecontext.dev/next"),
			title: "Next",
			canGoBack: true
		)
		await store.send(.event(.navigation(fixture().tabs[0].id, 2, navigation)))
		await store.send(.event(.navigation(tab.id, 1, navigation)))
		await store.send(.event(.navigation(tab.id, 2, navigation))) { $0.navigation = navigation }
		await store.receive(\.delegate.navigation)
	}

	@Test
	func viewerExplainsLocalDevelopmentFailuresAndKeepsOthersGeneric() async throws {
		let tab = fixture().tabs[0]
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 1)) {
			ViewerItemFeature()
		}
		let refused = BrowserNavigation(url: URL(string: "http://127.0.0.1:5173/"), errorCode: -102)
		await store.send(.event(.navigation(tab.id, 1, refused))) {
			$0.navigation = refused
			$0.failure = String.localized(.appUI.viewer.localServerUnreachable(5173))
		}
		await store.receive(\.delegate.navigation)
		let certificate = BrowserNavigation(url: URL(string: "https://app.localhost/"), errorCode: -202)
		await store.send(.event(.navigation(tab.id, 1, certificate))) {
			$0.navigation = certificate
			$0.failure = String.localized(.appUI.viewer.localCertificateRejected)
		}
		await store.receive(\.delegate.navigation)
		let remote = BrowserNavigation(url: URL(string: "https://capturecontext.dev/"), errorCode: -102)
		await store.send(.event(.navigation(tab.id, 1, remote))) {
			$0.navigation = remote
			$0.failure = String.localized(.appUI.viewer.navigationFailed(-102))
		}
		await store.receive(\.delegate.navigation)
		#expect(!String.localized(.appUI.viewer.localCertificateRejected).localizedCaseInsensitiveContains("bypass"))
		#expect(String.localized(.appUI.viewer.localServerUnreachable(5173)).contains("5173"))
	}

	@Test
	func viewerOffersPlainHTTPForLoopbackHTTPSProtocolErrors() async throws {
		let tab = fixture().tabs[0]
		let commands = LockIsolated<[BrowserEngineClient.Command]>([])
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab, generation: 1)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { _, command in commands.withValue { $0.append(command) } }
		}
		let httpURL = try #require(URL(string: "http://localhost:3000/app?q=1"))

		let remote = BrowserNavigation(url: URL(string: "https://capturecontext.dev/"), errorCode: -107)
		await store.send(.event(.navigation(tab.id, 1, remote))) {
			$0.navigation = remote
			$0.failure = String.localized(.appUI.viewer.navigationFailed(-107))
		}
		await store.receive(\.delegate.navigation)
		await store.send(.ui(.openPlainHTTP))

		let local = BrowserNavigation(url: URL(string: "https://localhost:3000/app?q=1"), errorCode: -107)
		await store.send(.event(.navigation(tab.id, 1, local))) {
			$0.navigation = local
			$0.failure = String.localized(.appUI.viewer.localServerWithoutEncryption)
		}
		await store.receive(\.delegate.navigation)
		await store.send(.ui(.openPlainHTTP))
		await store.receive(\.ui.command)
		expectNoDifference(commands.value, [.navigate(httpURL)])
		#expect(String.localized(.appUI.viewer.openUnencrypted(httpURL.absoluteString)).contains(httpURL.absoluteString))
	}

	@Test
	func viewerSubscribesBeforeOpeningAndSuspendingDoesNotCloseThePage() async throws {
		let tab = fixture().tabs[0]
		var calls: [String] = []
		let (stream, continuation) = AsyncStream<BrowserNavigation>.makeStream()
		let store = TestStore(initialState: ViewerItemFeature.State()) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.events = { _ in
				calls.append("subscribe")
				return stream
			}
			$0.browserEngine.open = { _ in calls.append("open") }
			$0.browserEngine.close = { _ in calls.append("close") }
		}
		await store.send(.show(tab)) {
			$0.tab = tab
			$0.navigation = .init(
				url: tab.restoration.url,
				title: tab.restoration.title
			)
			$0.generation = 1
			$0.isObserving = true
		}
		let loaded = BrowserNavigation(url: tab.restoration.url, title: "Loaded")
		continuation.yield(loaded)
		await store.receive(\.event.navigation) { $0.navigation = loaded }
		await store.receive(\.delegate.navigation)
		await store.send(.suspend) {
			$0.generation = 2
			$0.isObserving = false
		}
		await store.finish()
		expectNoDifference(calls, ["subscribe", "open"])
	}

	@Test
	func navigationCommandsTargetTheCurrentTab() async throws {
		let tab = fixture().tabs[1]
		var received: [BrowserEngineClient.Command] = []
		let store = TestStore(initialState: ViewerItemFeature.State(tab: tab)) {
			ViewerItemFeature()
		} withDependencies: {
			$0.browserEngine.command = { id, command in
				expectNoDifference(id, tab.id)
				received.append(command)
			}
		}
		await store.send(.ui(.command(.back)))
		await store.send(.ui(.command(.reload)))
		await store.finish()
		expectNoDifference(received, [.back, .reload])
	}

	@Test
	func commandSelectionUsesTypedIntentAndRejectsStaleResults() async throws {
		let tab = fixture().tabs[0]
		let entry = CommandBarFeature.Entry(
			presentation: .init(
				id: "opaque",
				title: "Example",
				actionTitle: "Switch",
				symbol: "globe"
			),
			intent: .selectTab(tab.id)
		)
		let store = TestStore(initialState: CommandBarFeature.State()) { CommandBarFeature() }
		await store.send(.present(.newTab, "", [entry])) {
			$0.isPresented = true
			$0.focusRequest = 1
			$0.candidates = [entry]
			$0.selectedID = "opaque"
		}
		await store.send(.ui(.selected("stale")))
		await store.send(.ui(.selected("opaque"))) { $0.isPresented = false }
		await store.receive(\.delegate.execute)
	}

	@Test
	func URLInputAndSearchRemainDistinct() async throws {
		expectNoDifference(
			CommandBarFeature.State.destination("capturecontext.dev/path")?.absoluteString,
			"https://capturecontext.dev/path"
		)
		expectNoDifference(
			CommandBarFeature.State.destination("https://capturecontext.dev/a?q=two")?.host(),
			"capturecontext.dev"
		)
		let search = try #require(CommandBarFeature.State.destination("two words & more"))
		expectNoDifference(
			URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value,
			"two words & more"
		)
		#expect(CommandBarFeature.State.destination("") == nil)
	}

	@Test
	func closeRemovesOnlyTheSelectedSession() async throws {
		let organization = fixture()
		var closed: [BrowserCore.Tab.ID] = []
		let store = TestStore(initialState: MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id
		)) { MainFeature() } withDependencies: {
			$0.browserEngine.close = { closed.append($0) }
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 100)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.closeTab))
		await store.receive(\.sidebar.event.closeApproved)
		await store.receive(\.synchronize)
		await store.finish()
		expectNoDifference(closed, [organization.tabs[0].id])
		expectNoDifference(store.state.sidebar.organization.tabs.map(\.id), [organization.tabs[1].id])
	}

	@Test
	func aMoveUsesItsCapturedDestinationEvenAfterSpaceSelectionChanges() async throws {
		let organization = fixture()
		let source = organization.spaces[0].id
		let destination = organization.spaces[1].id
		let tabID = organization.tabs[0].id
		let store = TestStore(initialState: SidebarFeature.State(
			organization: organization,
			spaceID: source
		)) { SidebarFeature() }
		await store.send(.ui(.move(.tab(tabID.rawValue), .unpinnedRoot, destination))) {
			$0.organization.spaces[0].unpinnedTabs.removeFirst()
			$0.organization.spaces[0].selectedTabID = nil
			$0.organization.spaces[1].unpinnedTabs.append(tabID)
			$0.undo.append(.init(before: organization, spaceID: source))
		}
		expectNoDifference(store.state.spaceID, source)
	}

	@Test
	func staleDropDestinationDoesNotChangeOrganization() async throws {
		var organization = fixture()
		let original = organization
		#expect(throws: (any Error).self) {
			try organization.move(
				.tab(original.tabs[0].id.rawValue),
				to: .unpinnedRoot,
				in: .init(rawValue: UUID())
			)
		}
		expectNoDifference(organization, original)
	}

	@Test
	func closingWindowSuspendsPresentationWithoutQuitting() async throws {
		let organization = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		await store.send(.ui(.closeWindow)) {
			$0.windowIsOpen = false

			// Reopen Closed Window can bring it back (DEV-908).
			$0.recentlyClosedWindows = [.init(
				id: $0.main.id,
				spaceID: organization.spaces[0].id,
				tabID: nil,
				isMain: true
			)]
			$0.main.canReopenClosedWindow = true
		}
		await store.receive(\.main.viewer.suspend)
		await store.receive(\.main.viewer.panes) {
			$0.main.viewer.item.generation = 1
			$0.main.viewer.observationGeneration = 1
		}
		expectNoDifference(store.state.shouldQuit, false)
		expectNoDifference(store.state.main.sidebar.organization, organization)
	}

	@Test
	func workspaceRoundTripsValidatedOrganizationAndRejectsDamagedData() async throws {
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let file = directory.appendingPathComponent("workspace.json")
		let client = BrowserWorkspaceClient(file: file)
		#expect(try client.load() == nil)
		try client.save(fixture())
		expectNoDifference(try client.load(), fixture())
		try Data("invalid".utf8).write(to: file)
		#expect(throws: (any Error).self) { try client.load() }
	}

	func fixture() -> BrowserOrganization {
		let profile = Profile.ID(rawValue: UUID(0))
		let first = Space.ID(rawValue: UUID(1))
		let second = Space.ID(rawValue: UUID(2))
		let tabs: [BrowserCore.Tab] = [3, 4].map {
			.init(
				id: .init(rawValue: UUID($0)),
				profileID: profile,
				restoration: .init(
					title: "Example",
					url: URL(string: "https://capturecontext.dev")!
				)
			)
		}
		return .init(
			profiles: [.init(
				id: profile,
				name: "Default"
			)],
			spaces: [
				.init(
					id: first,
					profileID: profile,
					name: "Work",
					unpinnedTabs: tabs.map(\.id),
					selectedTabID: tabs[0].id
				),
				.init(
					id: second,
					profileID: profile,
					name: "Personal"
				)
			],
			tabs: tabs
		)
	}
}
