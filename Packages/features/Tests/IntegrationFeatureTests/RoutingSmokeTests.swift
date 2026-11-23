#if DEBUG
@testable import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import Testing

@Suite(.dependencies)
@MainActor
internal struct RoutingSmokeTests {
	@Test(arguments: [RoutingWindowMode.mainBrowser, .littleArx])
	internal func seedsOnlyFreshOwnedStorageWithExplicitOrderedRouting(mode: RoutingWindowMode) async throws {
		let fixture = try Fixture(mode: mode)
		defer { fixture.remove() }
		let loaded = try #require(try fixture.load())
		try loaded.seedWorkspace()
		let saved = try BrowserWorkspaceClient(file: loaded.profile.appendingPathComponent("arx-workspace.json"))
			.loadWithRecovery()
		expectNoDifference(saved.organization, loaded.organization)
		expectNoDifference(saved.preferences.routing, loaded.preferences.routing)
		for (index, url) in loaded.configuration.urls.enumerated() {
			let decision = URLRouter.decide(
				url,
				preferences: saved.preferences.routing,
				organization: try #require(saved.organization),
				currentSpaceID: nil
			)
			expectNoDifference(try decision.result.get(), loaded.target(at: index))
		}
		#expect(throws: RoutingSmokeFixture.Failure.invalidFixture) { try fixture.load() }
	}

	@Test(arguments: [
		"missing-environment",
		"missing-argument",
		"missing-profile",
		"different-profile",
		"wrong-application",
		"used-profile",
		"profile-symlink",
		"marker-permissions",
		"marker-content",
		"configuration-symlink",
		"foreign-url",
	])
	internal func refusesUnsafeStartupBeforeWorkspaceOrProfileFallback(change: String) async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		var environment = fixture.environment
		var arguments = fixture.arguments
		var application = fixture.application
		switch change {
		case "missing-environment":
			environment.removeValue(forKey: "ARX_ROUTING_SMOKE_ROOT")

		case "missing-argument":
			arguments = ["Arx"]

		case "missing-profile":
			environment.removeValue(forKey: "ARX_ENGINE_PROFILE")

		case "different-profile":
			environment["ARX_ENGINE_PROFILE"] = fixture.root.path

		case "wrong-application":
			application = URL(fileURLWithPath: "/unrelated/Arx.app")

		case "used-profile":
			try Data("existing".utf8).write(to: fixture.profile.appendingPathComponent("sentinel"))

		case "marker-permissions":
			try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.marker.path)

		case "marker-content":
			try Data("not authorized".utf8).write(to: fixture.marker)

		case "profile-symlink":
			try FileManager.default.removeItem(at: fixture.profile)
			try FileManager.default.createSymbolicLink(at: fixture.profile, withDestinationURL: fixture.root)

		case "configuration-symlink":
			try FileManager.default.removeItem(at: fixture.configurationFile)
			try FileManager.default.createSymbolicLink(at: fixture.configurationFile, withDestinationURL: fixture.marker)

		default:
			let configuration = RoutingSmokeFixture.Configuration(
				application: fixture.application,
				mode: .mainBrowser,
				urls: Array(repeating: URL(string: "https://capturecontext.dev")!, count: 4)
			)
			try JSONEncoder().encode(configuration).write(to: fixture.configurationFile)
		}
		#expect(throws: (any Error).self) {
			try RoutingSmokeFixture.load(
				environment: environment,
				arguments: arguments,
				application: application
			)
		}
		let workspaceFile = fixture.profile.appendingPathComponent("arx-workspace.json")
		#expect(!FileManager.default.fileExists(atPath: workspaceFile.path))
	}

	@Test
	internal func acceptsTheSameBundleFileIdentityAndRejectsAnUnrelatedSibling() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let alias = fixture.root.appendingPathComponent("alias.app")
		try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.application)
		#expect(try RoutingSmokeFixture.load(
			environment: fixture.environment,
			arguments: fixture.arguments,
			application: alias
		) != nil)

		let alternateCase = fixture.root.appendingPathComponent("arx.app")
		if FileManager.default.fileExists(atPath: alternateCase.path) {
			#expect(try RoutingSmokeFixture.load(
				environment: fixture.environment,
				arguments: fixture.arguments,
				application: alternateCase
			) != nil)
		}

		let sibling = fixture.root.appendingPathComponent("other.app")
		try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: false)
		#expect(throws: RoutingSmokeFixture.Failure.invalidFixture) {
			try RoutingSmokeFixture.load(
				environment: fixture.environment,
				arguments: fixture.arguments,
				application: sibling
			)
		}
	}

	@Test
	internal func ordinaryStartupDoesNotOptIntoFixtureFromProfileEnvironmentAlone() async throws {
		let loaded = try RoutingSmokeFixture.load(
			environment: ["ARX_ENGINE_PROFILE": "/unused"],
			arguments: ["Arx"],
			application: URL(fileURLWithPath: "/unused/Arx.app")
		)
		#expect(loaded == nil)
	}

	@Test(arguments: [RoutingWindowMode.mainBrowser, .littleArx])
	internal func acceptsExactOrderedDestinationsIncludingDuplicateURLsWithDistinctSessions(mode: RoutingWindowMode) async throws {
		let fixture = try Fixture(mode: mode)
		defer { fixture.remove() }
		let loaded = try #require(try fixture.load())
		let smoke = RoutingSmoke(fixture: loaded)
		let state = state(for: loaded)
		loaded.configuration.urls.forEach(smoke.received)
		smoke.observe(state: state)
		try smoke.validate(state: state)
	}

	@Test(arguments: [
		"reordered-events",
		"dropped-event",
		"duplicate-event",
		"reordered-commits",
		"wrong-profile",
		"wrong-space",
		"temporary-history",
		"temporary-workspace",
	])
	internal func refusesLossSubstitutionWrongProfileAndTemporaryPersistence(change: String) async throws {
		let fixture = try Fixture(mode: .littleArx)
		defer { fixture.remove() }
		let loaded = try #require(try fixture.load())
		let smoke = RoutingSmoke(fixture: loaded)
		var state = state(for: loaded)
		var received = loaded.configuration.urls
		switch change {
		case "reordered-events":
			received.swapAt(0, 1)

		case "dropped-event":
			received.removeLast()

		case "duplicate-event":
			received.append(received[0])

		case "reordered-commits":
			state.littleWindows.swapAt(0, 1)

		case "wrong-profile":
			let old = state.littleWindows[1].tab
			state.littleWindows[1].tab = .init(
				id: old.id,
				profileID: RoutingSmokeFixture.profileA,
				restoration: old.restoration
			)

		case "wrong-space":
			state.littleWindows[1].spaceID = RoutingSmokeFixture.spaceA

		case "temporary-history":
			state.history.snapshots[RoutingSmokeFixture.profileA] = .init(
				profileID: RoutingSmokeFixture.profileA,
				// Routed Little Arx pages may reach history (DEV-728); nothing else may.
				entries: [.init(
					id: UUID(),
					url: URL(string: "https://unexpected.example/")!,
					title: "Unexpected visit",
					lastVisited: Date()
				)]
			)

		default:
			state.workspace.tabs.append(state.littleWindows[0].tab)
		}
		received.forEach(smoke.received)
		smoke.observe(state: state)
		#expect(throws: (any Error).self) { try smoke.validate(state: state) }
	}

	@Test
	internal func nativeAcceptanceRequiresCurrentLoadedDocumentAndIsolatedProfileStorage() async throws {
		let fixture = try Fixture()
		defer { fixture.remove() }
		let loaded = try #require(try fixture.load())
		let smoke = RoutingSmoke(fixture: loaded)
		let expected = loaded.configuration.urls[1]
		let navigation = BrowserNavigation(
			url: expected,
			title: "Arx routing|b|\(expected.absoluteString)",
			history: [.init(id: 1, url: expected, title: "Fixture", isCurrent: true)]
		)
		#expect(smoke.matches(navigation, at: 1))
		#expect(!smoke.matches(nil, at: 1))
		var changed = navigation
		changed.title = "Arx routing|a|\(expected.absoluteString)"
		#expect(!smoke.matches(changed, at: 1))
		changed = navigation
		changed.isLoading = true
		#expect(!smoke.matches(changed, at: 1))
		changed = navigation
		changed.errorCode = -1
		#expect(!smoke.matches(changed, at: 1))
		changed = navigation
		changed.url = loaded.configuration.urls[0]
		#expect(!smoke.matches(changed, at: 1))
		changed = navigation
		changed.history[0].isCurrent = false
		#expect(!smoke.matches(changed, at: 1))
	}

	private func state(for fixture: RoutingSmokeFixture) -> AppFeature.State {
		var state = AppFeature.State(main: .init(
			organization: fixture.organization,
			spaceID: RoutingSmokeFixture.spaceA
		))
		for (index, url) in fixture.configuration.urls.enumerated() {
			let target = fixture.target(at: index)
			let tab = BrowserCore.Tab(
				id: .init(rawValue: UUID()),
				profileID: target.profileID,
				restoration: .init(title: "Fixture", url: url)
			)
			switch fixture.configuration.mode {
			case .littleArx:
				state.littleWindows.append(.init(id: UUID(), spaceID: target.spaceID, tab: tab))

			case .mainBrowser:
				state.workspace.tabs.append(tab)
				let spaceIndex = index == 0 || index == 2 ? 0 : 1
				state.workspace.spaces[spaceIndex].unpinnedTabs.append(tab.id)
				state.workspace.spaces[spaceIndex].selectedTabID = tab.id
				state.main.sidebar.organization = state.workspace
				state.main.sidebar.selectSpace(target.spaceID)
				state.main.sidebar.select(tab.id)
				state.main.viewer.item.tab = tab
			}
		}
		return state
	}

	private struct Fixture {
		let root: URL
		let application: URL
		var profile: URL { root.appendingPathComponent("profile") }
		var marker: URL { root.appendingPathComponent(".arx-routing-smoke") }
		var configurationFile: URL { root.appendingPathComponent("fixture.json") }
		var environment: [String: String] {
			["ARX_ROUTING_SMOKE_ROOT": root.path, "ARX_ENGINE_PROFILE": profile.path]
		}
		var arguments: [String] { ["Arx", RoutingSmokeFixture.argument, root.path] }

		init(mode: RoutingWindowMode = .mainBrowser) throws {
			self.root = URL.temporaryDirectory.resolvingSymlinksInPath()
				.appendingPathComponent("routing-smoke-\(UUID().uuidString)")
			self.application = root.appendingPathComponent("Arx.app")
			try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: application, withIntermediateDirectories: false)
			for path in [root, profile] {
				try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
			}
			try Data(RoutingSmokeFixture.sentinel.utf8).write(to: marker)
			let configuration = RoutingSmokeFixture.Configuration(
				application: application,
				mode: mode,
				urls: RoutingSmokeFixture.expectedURLs(port: 48123)
			)
			try JSONEncoder().encode(configuration).write(to: configurationFile)
			for path in [marker, configurationFile] {
				try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
			}
		}

		func load() throws -> RoutingSmokeFixture? {
			try RoutingSmokeFixture.load(
				environment: environment,
				arguments: arguments,
				application: application
			)
		}

		func remove() {
			do {
				try FileManager.default.removeItem(at: root)
			} catch {
				Issue.record(error)
			}
		}
	}
}
#endif
