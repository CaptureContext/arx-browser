import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// One ordinary profile's site permissions and page zoom (DEV-716): the default for
/// each permission, each site's own settings, and default and per-site zoom. Chromium
/// holds them; this state is the last listing. Every change, from here or from
/// automation, is a `SiteSettingsEdit` applied by the engine, and any change the
/// engine reports for this profile (a page's permission prompt included) reloads it.
@Reducer
public struct SiteSettingsFeature {
	@ObservableState
	public struct State: Equatable {
		public var profileID: Profile.ID
		public var profileName: String
		public var settings: SiteSettings
		public var isLoading: Bool
		public var isApplying: Bool
		public var query: String
		public var permissionDraft: PermissionDraft?
		public var zoomDraft: ZoomDraft?
		public var notice: SiteSettingsFailure?

		/// The devices sites in the profile may use (DEV-905).
		public var devices: [BrowserDeviceGrant]

		public init(
			profileID: Profile.ID,
			profileName: String,
			settings: SiteSettings = .init(),
			isLoading: Bool = true
		) {
			self.profileID = profileID
			self.profileName = profileName
			self.settings = settings
			self.isLoading = isLoading
			self.isApplying = false
			self.query = ""
			self.permissionDraft = nil
			self.zoomDraft = nil
			self.notice = nil
			self.devices = []
		}

		/// Listed origins containing the query, each with its own settings.
		public var visibleSites: [Site] {
			let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
			return settings.origins
				.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
				.map { origin in
					.init(origin: origin, exceptions: settings.exceptions.filter { $0.origin == origin })
				}
		}

		public var visibleZoom: [SiteZoom] {
			let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
			return settings.zoom.filter { query.isEmpty || $0.host.localizedCaseInsensitiveContains(query) }
		}
	}

	public struct Site: Equatable, Identifiable, Sendable {
		public var origin: String
		public var exceptions: [SitePermissionException]

		public var id: String { origin }

		/// Some setting here is managed, so the site can't be removed as a whole.
		public var hasManaged: Bool {
			exceptions.contains(where: \.isManaged)
		}
	}

	/// A site's permission being added.
	public struct PermissionDraft: Equatable, Identifiable, Sendable {
		public var origin: String
		public var permission: SitePermission
		public var setting: SitePermissionSetting

		public var id: String { "permission" }

		public init(
			origin: String = "",
			permission: SitePermission = .camera,
			setting: SitePermissionSetting = .allow
		) {
			self.origin = origin
			self.permission = permission
			self.setting = setting
		}
	}

	/// A site's zoom being added.
	public struct ZoomDraft: Equatable, Identifiable, Sendable {
		public var host: String
		public var factor: Double

		public var id: String { "zoom" }

		public init(
			host: String = "",
			factor: Double = 1.25
		) {
			self.host = host
			self.factor = factor
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case appeared
			case queryChanged(String)

			/// Any change the sheet makes: a default, a site's setting, a zoom.
			case apply(SiteSettingsEdit)

			/// Removes every setting of a site that isn't managed.
			case removeSite(String)

			/// Reads the profile again, as when another place changed it.
			case refresh
			case addPermission
			case permissionDraftChanged(PermissionDraft)
			case savePermissionDraft
			case cancelPermissionDraft
			case addZoom
			case zoomDraftChanged(ZoomDraft)
			case saveZoomDraft
			case cancelZoomDraft
			case dismissNotice

			/// Forget: the device's site has to ask for it again (DEV-905).
			case forgetDevice(String)
			case done
		}

		@CasePathable
		public enum Event: Sendable {
			case listed(Result<SiteSettings, SiteSettingsFailure>)
			case applied(Result<SiteSettings, SiteSettingsFailure>)
			case engineChanged(Profile.ID)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case dismiss
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	public init() {}

	@Dependency(\.deviceChoosers)
	private var deviceChoosers

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			let profileID = state.profileID
			state.devices = MainActor.assumeIsolated { [deviceChoosers] in deviceChoosers.grants(profileID) } ?? []
			return .merge(
				load(&state),
				.run { [engine] send in
					for await changed in await engine.siteSettingsChanges() where changed == profileID {
						await send(.event(.engineChanged(changed)))
					}
				}
				.cancellable(id: Cancellation.observe, cancelInFlight: true)
			)
		}

		Pullback(\.ui.refresh) { state in
			load(&state)
		}

		Pullback(\.ui.forgetDevice) { state, id in
			guard let grant = state.devices.first(where: { $0.id == id }) else { return .none }
			let profileID = state.profileID
			_ = MainActor.assumeIsolated { [deviceChoosers] in deviceChoosers.revoke(profileID, grant) }
			state.devices = MainActor.assumeIsolated { [deviceChoosers] in deviceChoosers.grants(profileID) } ?? []
			return .none
		}

		Pullback(\.event.engineChanged) { state, _ in

			// A change of our own comes back with its listing.
			state.isApplying ? .none : load(&state)
		}

		Pullback(\.ui.queryChanged) { state, query in
			state.query = query
			return .none
		}

		Pullback(\.event.listed) { state, result in

			// The profile is loaded now, so its devices can be read too (DEV-905).
			let profileID = state.profileID
			state.devices = MainActor.assumeIsolated { [deviceChoosers] in deviceChoosers.grants(profileID) } ?? state.devices
			state.isLoading = false
			switch result {
			case let .success(settings):
				state.settings = settings
			case let .failure(failure):
				state.notice = failure
			}
			return .none
		}

		applying
		drafting

		Pullback(\.ui.dismissNotice) { state in
			state.notice = nil
			return .none
		}

		Pullback(\.ui.done) { _ in
			.merge(
				.cancel(id: Cancellation.observe),
				.send(.delegate(.dismiss))
			)
		}
	}

	@ReducerBuilder<State, Action>
	private var applying: some ReducerOf<Self> {
		Pullback(\.ui.apply) { state, edit in
			apply([edit], to: &state)
		}

		Pullback(\.ui.removeSite) { state, origin in
			let edits = state.settings.exceptions
				.filter { $0.origin == origin && !$0.isManaged }
				.map { SiteSettingsEdit.setPermission(origin: origin, $0.permission, nil) }
			return apply(edits, to: &state)
		}

		Pullback(\.event.applied) { state, result in
			state.isApplying = false
			switch result {
			case let .success(settings):
				state.settings = settings
				return .none

			case let .failure(failure):
				state.notice = failure
				return load(&state)
			}
		}
	}

	@ReducerBuilder<State, Action>
	private var drafting: some ReducerOf<Self> {
		Pullback(\.ui.addPermission) { state in
			state.permissionDraft = .init()
			state.notice = nil
			return .none
		}

		Pullback(\.ui.permissionDraftChanged) { state, draft in
			var draft = draft
			if !draft.permission.siteSettings.contains(draft.setting) {
				draft.setting = .allow
			}
			state.permissionDraft = draft
			return .none
		}

		Pullback(\.ui.cancelPermissionDraft) { state in
			state.permissionDraft = nil
			return .none
		}

		Pullback(\.ui.savePermissionDraft) { state in
			guard let draft = state.permissionDraft else { return .none }
			guard let origin = SiteSettings.origin(draft.origin) else {
				state.notice = .invalid
				return .none
			}

			state.permissionDraft = nil
			return apply([.setPermission(origin: origin, draft.permission, draft.setting)], to: &state)
		}

		Pullback(\.ui.addZoom) { state in
			state.zoomDraft = .init()
			state.notice = nil
			return .none
		}

		Pullback(\.ui.zoomDraftChanged) { state, draft in
			state.zoomDraft = draft
			return .none
		}

		Pullback(\.ui.cancelZoomDraft) { state in
			state.zoomDraft = nil
			return .none
		}

		Pullback(\.ui.saveZoomDraft) { state in
			guard let draft = state.zoomDraft else { return .none }
			guard let host = SiteSettings.zoomHost(draft.host) else {
				state.notice = .invalid
				return .none
			}

			state.zoomDraft = nil
			return apply([.setZoom(host: host, factor: draft.factor)], to: &state)
		}
	}

	/// Applies edits in order; the last listing wins. The first failure stops the rest.
	private func apply(
		_ edits: [SiteSettingsEdit],
		to state: inout State
	) -> Effect<Action> {
		guard !edits.isEmpty else { return .none }

		for edit in edits {
			do throws(SiteSettingsFailure) {
				try edit.validate()
			} catch {
				state.notice = error
				return .none
			}
		}
		state.isApplying = true
		state.notice = nil
		let profileID = state.profileID
		return .run { [engine] send in
			var result: Result<SiteSettings, SiteSettingsFailure> = .failure(.failed)
			for edit in edits {
				do throws(SiteSettingsFailure) {
					result = .success(try await engine.changeSiteSettings(profileID, edit))
				} catch {
					result = .failure(error)
					break
				}
			}
			await send(.event(.applied(result)))
		}
		.cancellable(id: Cancellation.apply)
	}

	private func load(_ state: inout State) -> Effect<Action> {
		state.isLoading = true
		let profileID = state.profileID
		return .run { [engine] send in
			let result: Result<SiteSettings, SiteSettingsFailure>
			do throws(SiteSettingsFailure) {
				result = .success(try await engine.siteSettings(profileID))
			} catch {
				result = .failure(error)
			}
			await send(.event(.listed(result)))
		}
		.cancellable(id: Cancellation.load, cancelInFlight: true)
	}

	private enum Cancellation: Hashable {
		case load
		case apply
		case observe
	}
}
