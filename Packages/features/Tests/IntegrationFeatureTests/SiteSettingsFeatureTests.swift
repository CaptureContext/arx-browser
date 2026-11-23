import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@MainActor
@Suite(.dependencies, .serialized)
internal struct SiteSettingsFeatureTests {
	private static let profileID = Profile.ID(rawValue: UUID(0))

	@Test
	internal func onlyListedProfilesOpenTheirSiteSettings() async throws {
		let profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// A private or unknown profile isn't listed, so nothing opens.
		await store.send(.ui(.showSiteSettings(.init(rawValue: UUID()))))
		#expect(store.state.siteSettings == nil)

		await store.send(.ui(.showSiteSettings(profile.id)))
		#expect(store.state.siteSettings == .init(profileID: profile.id, profileName: "Work"))

		await store.send(.ui(.siteSettingsPresented(false)))
		#expect(store.state.siteSettings == nil)

		await store.send(.ui(.showSiteSettings(profile.id)))
		await store.send(.configureExtensions([]))
		#expect(store.state.siteSettings == nil)
	}

	@Test
	internal func appearingListsAndFollowsEngineChanges() async throws {
		let engine = SiteSettingsEngineDouble()
		let store = makeStore(engine)

		await store.send(.ui(.appeared))
		await store.receive(\.event.listed) {
			$0.isLoading = false
			$0.settings = SiteSettingsEngineDouble.initial
		}

		// Another place, a page's prompt included, changed this profile.
		engine.stored = SiteSettingsEngineDouble.changed
		engine.changes.yield(.init(rawValue: UUID(9)))
		engine.changes.yield(Self.profileID)
		await store.receive(\.event.engineChanged) {
			$0.isLoading = true
		}
		await store.receive(\.event.listed) {
			$0.isLoading = false
			$0.settings = SiteSettingsEngineDouble.changed
		}
		expectNoDifference(engine.listed, [Self.profileID, Self.profileID])

		await store.send(.ui(.done))
		await store.receive(\.delegate.dismiss)
	}

	@Test
	internal func searchFiltersSitesAndZoomHosts() {
		var state = SiteSettingsFeature.State(
			profileID: Self.profileID,
			profileName: "Work",
			settings: SiteSettingsEngineDouble.changed,
			isLoading: false
		)
		state.query = "MEET"
		expectNoDifference(state.visibleSites.map(\.origin), ["https://meet.example"])
		expectNoDifference(state.visibleZoom, [])
		state.query = "docs"
		expectNoDifference(state.visibleZoom.map(\.host), ["docs.example"])
	}

	@Test
	internal func editsGoThroughTheEngineAndTakeItsListing() async throws {
		let engine = SiteSettingsEngineDouble()
		let store = makeStore(engine, loaded: true)
		let edit = SiteSettingsEdit.setPermission(origin: nil, .notifications, .block)

		await store.send(.ui(.apply(edit))) {
			$0.isApplying = true
		}
		await store.receive(\.event.applied) {
			$0.isApplying = false
			$0.settings = SiteSettingsEngineDouble.changed
		}
		expectNoDifference(engine.edits, [edit])
	}

	@Test
	internal func invalidEditsNeverReachTheEngine() async throws {
		let engine = SiteSettingsEngineDouble()
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.apply(.setPermission(origin: "https://a.example", .popups, .ask)))) {
			$0.notice = .invalid
		}
		await store.send(.ui(.addPermission)) {
			$0.notice = nil
			$0.permissionDraft = .init()
		}
		await store.send(.ui(.permissionDraftChanged(.init(origin: "javascript:alert(1)", permission: .popups, setting: .ask)))) {
			// Pop-ups take no ask, so the draft falls back to allow.
			$0.permissionDraft = .init(origin: "javascript:alert(1)", permission: .popups, setting: .allow)
		}
		await store.send(.ui(.savePermissionDraft)) {
			$0.notice = .invalid
		}
		expectNoDifference(engine.edits, [])
	}

	@Test
	internal func draftsNormalizeTheSite() async throws {
		let engine = SiteSettingsEngineDouble()
		let store = makeStore(engine, loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.addPermission))
		await store.send(.ui(.permissionDraftChanged(.init(origin: "Meet.Example/room", permission: .camera, setting: .allow))))
		await store.send(.ui(.savePermissionDraft))
		await store.receive(\.event.applied)
		await store.send(.ui(.addZoom))
		await store.send(.ui(.zoomDraftChanged(.init(host: "https://Docs.Example/a", factor: 1.5))))
		await store.send(.ui(.saveZoomDraft))
		await store.receive(\.event.applied)
		expectNoDifference(engine.edits, [
			.setPermission(origin: "https://meet.example", .camera, .allow),
			.setZoom(host: "docs.example", factor: 1.5),
		])
		#expect(store.state.permissionDraft == nil)
		#expect(store.state.zoomDraft == nil)
	}

	@Test
	internal func removingASiteKeepsManagedSettings() async throws {
		let engine = SiteSettingsEngineDouble()
		let store = makeStore(engine, loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.removeSite("https://meet.example")))
		await store.receive(\.event.applied)
		expectNoDifference(engine.edits, [.setPermission(origin: "https://meet.example", .camera, nil)])
	}

	@Test
	internal func failuresShowAndReload() async throws {
		let engine = SiteSettingsEngineDouble()
		engine.failure = .managed
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.apply(.setPermission(origin: "https://meet.example", .camera, .block)))) {
			$0.isApplying = true
		}
		await store.receive(\.event.applied) {
			$0.isApplying = false
			$0.notice = .managed
			$0.isLoading = true
		}
		await store.receive(\.event.listed) {
			$0.isLoading = false
		}
	}

	private func makeStore(
		_ engine: SiteSettingsEngineDouble,
		loaded: Bool = false
	) -> TestStoreOf<SiteSettingsFeature> {
		TestStore(
			initialState: .init(
				profileID: Self.profileID,
				profileName: "Work",
				settings: loaded ? SiteSettingsEngineDouble.initial : .init(),
				isLoading: !loaded
			)
		) {
			SiteSettingsFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
		}
	}
}

/// Records what Settings asks the engine.
@MainActor
private final class SiteSettingsEngineDouble {
	static let initial = SiteSettings(
		defaults: SitePermission.allCases.map { .init(permission: $0, setting: $0 == .popups ? .block : .ask) },
		exceptions: [
			.init(origin: "https://meet.example", permission: .camera, setting: .allow),
			.init(origin: "https://meet.example", permission: .microphone, setting: .allow, isManaged: true),
		]
	)

	static let changed = SiteSettings(
		defaults: [.init(permission: .notifications, setting: .block)],
		exceptions: [.init(origin: "https://meet.example", permission: .camera, setting: .block)],
		zoom: [.init(host: "docs.example", factor: 1.5)]
	)

	var stored: SiteSettings = initial

	/// Every change fails with this.
	var failure: SiteSettingsFailure?
	var listed: [Profile.ID] = []
	var edits: [SiteSettingsEdit] = []
	let (stream, changes) = AsyncStream<Profile.ID>.makeStream()

	var client: BrowserEngineClient {
		var client = BrowserEngineClient(status: { .ready })
		client.siteSettingsAreAvailable = { true }
		client.siteSettings = { [self] id throws(SiteSettingsFailure) in
			listed.append(id)
			return stored
		}
		client.changeSiteSettings = { [self] _, edit throws(SiteSettingsFailure) in
			edits.append(edit)
			if let failure { throw failure }
			return Self.changed
		}
		client.siteSettingsChanges = { [stream] in stream }
		return client
	}
}
