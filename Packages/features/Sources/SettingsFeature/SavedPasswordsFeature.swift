import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// One ordinary profile's saved passwords (DEV-721): list, search, add, edit,
/// remove, reveal and CSV import. State holds sites and usernames only. A
/// password goes from an AppKit field the view lends straight to the engine,
/// and a revealed one from the engine straight to the pasteboard or a field.
@Reducer
public struct SavedPasswordsFeature {
	@ObservableState
	public struct State: Equatable {
		public var profileID: Profile.ID
		public var profileName: String
		public var list: BrowserSavedPasswordList
		public var isLoading: Bool
		public var query: String
		public var editor: Editor?
		public var removal: Removal?
		public var reveal: Reveal?
		public var isImporting: Bool
		public var importSummary: BrowserPasswordImportSummary?
		public var notice: Notice?

		public init(
			profileID: Profile.ID,
			profileName: String,
			list: BrowserSavedPasswordList = .init(),
			isLoading: Bool = true
		) {
			self.profileID = profileID
			self.profileName = profileName
			self.list = list
			self.isLoading = isLoading
			self.query = ""
			self.editor = nil
			self.removal = nil
			self.reveal = nil
			self.isImporting = false
			self.importSummary = nil
			self.notice = nil
		}

		/// Saved passwords whose site or username contains the query.
		public var visiblePasswords: [BrowserSavedPassword] {
			let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
			let sorted = list.passwords.sorted {
				($0.site, $0.username) < ($1.site, $1.username)
			}
			guard !query.isEmpty else { return sorted }

			return sorted.filter {
				$0.site.localizedCaseInsensitiveContains(query)
				|| $0.username.localizedCaseInsensitiveContains(query)
			}
		}
	}

	/// The add or edit form. The password is in the lent field, never here.
	public struct Editor: Equatable, Sendable {
		public enum Mode: Equatable, Sendable {
			case add
			case edit(UInt32)
		}

		public var mode: Mode
		public var site: String
		public var username: String
		public var passwordField: BrowserPasswordFieldID
		public var isSaving: Bool

		public init(
			mode: Mode,
			site: String,
			username: String,
			passwordField: BrowserPasswordFieldID,
			isSaving: Bool = false
		) {
			self.mode = mode
			self.site = site
			self.username = username
			self.passwordField = passwordField
			self.isSaving = isSaving
		}
	}

	public struct Removal: Equatable, Sendable {
		public var id: UInt32
		public var site: String

		/// A "never saved" site rather than a password.
		public var isNeverSaved: Bool

		public init(
			id: UInt32,
			site: String,
			isNeverSaved: Bool
		) {
			self.id = id
			self.site = site
			self.isNeverSaved = isNeverSaved
		}
	}

	/// A password shown in a lent field after the device owner authenticates.
	public struct Reveal: Equatable, Sendable {
		public var id: UInt32
		public var site: String
		public var username: String
		public var field: BrowserPasswordFieldID

		public init(
			id: UInt32,
			site: String,
			username: String,
			field: BrowserPasswordFieldID
		) {
			self.id = id
			self.site = site
			self.username = username
			self.field = field
		}
	}

	public enum Notice: Equatable, Sendable {
		case copied
		case failure(BrowserSavedPasswordFailure)
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
			case addPassword
			case editPassword(UInt32)
			case editorSiteChanged(String)
			case editorUsernameChanged(String)
			case saveEditor
			case cancelEditor
			case removePassword(UInt32)
			case removeNeverSavedSite(UInt32)
			case confirmRemoval
			case cancelRemoval
			case copyPassword(UInt32)
			case showPassword(UInt32)

			/// The reveal sheet's field is in a window and can take the password.
			case revealFieldReady
			case closeReveal
			case importPresented(Bool)
			case importFile(URL)
			case dismissImportSummary
			case dismissNotice
			case done
		}

		@CasePathable
		public enum Event: Sendable {
			case listed(Result<BrowserSavedPasswordList, BrowserSavedPasswordFailure>)
			case saved(Result<BrowserSavedPasswordList, BrowserSavedPasswordFailure>)
			case removed(Result<BrowserSavedPasswordList, BrowserSavedPasswordFailure>)
			case copied(BrowserSavedPasswordFailure?)
			case revealed(BrowserSavedPasswordFailure?)
			case imported(Result<BrowserPasswordImportSummary, BrowserSavedPasswordFailure>)
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

	@Dependency(\.uuid)
	private var uuid

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			load(&state)
		}

		Pullback(\.ui.queryChanged) { state, query in
			state.query = query
			return .none
		}

		Pullback(\.event.listed) { state, result in
			state.isLoading = false
			switch result {
			case let .success(list):
				state.list = list
			case let .failure(failure):
				state.notice = .failure(failure)
			}
			return .none
		}

		editing
		removing
		revealing
		importing

		Pullback(\.ui.dismissNotice) { state in
			state.notice = nil
			return .none
		}

		Pullback(\.ui.done) { _ in
			.merge(
				.cancel(id: Cancellation.reveal),
				.send(.delegate(.dismiss))
			)
		}
	}

	@ReducerBuilder<State, Action>
	private var editing: some ReducerOf<Self> {
		Pullback(\.ui.addPassword) { state in
			state.editor = .init(mode: .add, site: "", username: "", passwordField: .init(rawValue: uuid()))
			state.notice = nil
			return .none
		}

		Pullback(\.ui.editPassword) { state, id in
			guard let password = state.list.passwords.first(where: { $0.id == id })
			else { return .none }

			state.editor = .init(
				mode: .edit(id),
				site: password.site,
				username: password.username,
				passwordField: .init(rawValue: uuid())
			)
			state.notice = nil
			return .none
		}

		Pullback(\.ui.editorSiteChanged) { state, site in
			state.editor?.site = site
			return .none
		}

		Pullback(\.ui.editorUsernameChanged) { state, username in
			state.editor?.username = username
			return .none
		}

		Pullback(\.ui.cancelEditor) { state in
			state.editor = nil
			return .cancel(id: Cancellation.save)
		}

		Pullback(\.ui.saveEditor) { state in
			guard let editor = state.editor, !editor.isSaving
			else { return .none }

			let target: BrowserPasswordEdit.Target
			switch editor.mode {
			case .add:
				let site = editor.site.trimmingCharacters(in: .whitespacesAndNewlines)
				guard !site.isEmpty else {
					state.notice = .failure(.invalid)
					return .none
				}
				target = .new(url: site)

			case let .edit(id):
				target = .existing(listing: state.list.listing, id: id)
			}
			state.editor?.isSaving = true
			state.notice = nil
			let edit = BrowserPasswordEdit(
				profileID: state.profileID,
				target: target,
				username: editor.username.trimmingCharacters(in: .whitespacesAndNewlines),
				passwordField: editor.passwordField
			)
			return .run { [engine] send in
				await send(.event(.saved(await Self.result { () async throws(BrowserSavedPasswordFailure) in
					try await engine.savePassword(edit)
				})))
			}
			.cancellable(id: Cancellation.save, cancelInFlight: true)
		}

		Pullback(\.event.saved) { state, result in
			switch result {
			case let .success(list):
				state.list = list
				state.editor = nil
				return .none

			case let .failure(failure):
				state.editor?.isSaving = false
				state.notice = .failure(failure)
				return failure == .stale ? load(&state) : .none
			}
		}
	}

	@ReducerBuilder<State, Action>
	private var removing: some ReducerOf<Self> {
		Pullback(\.ui.removePassword) { state, id in
			guard let password = state.list.passwords.first(where: { $0.id == id })
			else { return .none }

			state.removal = .init(id: id, site: password.site, isNeverSaved: false)
			return .none
		}

		Pullback(\.ui.removeNeverSavedSite) { state, id in
			guard let site = state.list.neverSaved.first(where: { $0.id == id })
			else { return .none }

			state.removal = .init(id: id, site: site.site, isNeverSaved: true)
			return .none
		}

		Pullback(\.ui.cancelRemoval) { state in
			state.removal = nil
			return .none
		}

		Pullback(\.ui.confirmRemoval) { state in
			guard let removal = state.removal
			else { return .none }

			state.removal = nil
			state.notice = nil
			let profileID = state.profileID
			let listing = state.list.listing
			return .run { [engine] send in
				await send(.event(.removed(await Self.result { () async throws(BrowserSavedPasswordFailure) in
					try await engine.removeSavedPassword(profileID, listing, removal.id)
				})))
			}
			.cancellable(id: Cancellation.remove, cancelInFlight: true)
		}

		Pullback(\.event.removed) { state, result in
			switch result {
			case let .success(list):
				state.list = list
				return .none

			case let .failure(failure):
				state.notice = .failure(failure)
				return failure == .stale ? load(&state) : .none
			}
		}
	}

	@ReducerBuilder<State, Action>
	private var revealing: some ReducerOf<Self> {
		Pullback(\.ui.copyPassword) { state, id in
			guard state.list.passwords.contains(where: { $0.id == id })
			else { return .none }

			state.notice = nil
			let profileID = state.profileID
			let listing = state.list.listing
			let reason = String.localized(.appUI.savedPasswords.copyReason)
			return .run { [engine] send in
				let result = await Self.result { () async throws(BrowserSavedPasswordFailure) in
					try await engine.revealSavedPassword(profileID, listing, id, reason, .copy)
				}
				await send(.event(.copied(result.failure)))
			}
			.cancellable(id: Cancellation.reveal, cancelInFlight: true)
		}

		Pullback(\.event.copied) { state, failure in
			state.notice = failure.map(Notice.failure) ?? .copied
			return failure == .stale ? load(&state) : .none
		}

		Pullback(\.ui.showPassword) { state, id in
			guard let password = state.list.passwords.first(where: { $0.id == id })
			else { return .none }

			state.notice = nil
			state.reveal = .init(
				id: id,
				site: password.site,
				username: password.username,
				field: .init(rawValue: uuid())
			)
			return .none
		}

		Pullback(\.ui.revealFieldReady) { state in
			guard let reveal = state.reveal
			else { return .none }

			let profileID = state.profileID
			let listing = state.list.listing
			let reason = String.localized(.appUI.savedPasswords.revealReason)
			return .run { [engine] send in
				let result = await Self.result { () async throws(BrowserSavedPasswordFailure) in
					try await engine.revealSavedPassword(profileID, listing, reveal.id, reason, .show(reveal.field))
				}
				await send(.event(.revealed(result.failure)))
			}
			.cancellable(id: Cancellation.reveal, cancelInFlight: true)
		}

		Pullback(\.event.revealed) { state, failure in
			guard let failure
			else { return .none }

			state.reveal = nil
			state.notice = .failure(failure)
			return failure == .stale ? load(&state) : .none
		}

		Pullback(\.ui.closeReveal) { state in
			state.reveal = nil
			return .cancel(id: Cancellation.reveal)
		}
	}

	@ReducerBuilder<State, Action>
	private var importing: some ReducerOf<Self> {
		Pullback(\.ui.importPresented) { state, isPresented in
			state.isImporting = isPresented
			return .none
		}

		Pullback(\.ui.importFile) { state, file in
			state.isImporting = false
			state.notice = nil
			state.isLoading = true
			let profileID = state.profileID
			return .run { [engine] send in
				await send(.event(.imported(await Self.result { () async throws(BrowserSavedPasswordFailure) in
					try await engine.importPasswords(profileID, file)
				})))
			}
			.cancellable(id: Cancellation.import, cancelInFlight: true)
		}

		Pullback(\.event.imported) { state, result in
			switch result {
			case let .success(summary):
				state.importSummary = summary
			case let .failure(failure):
				state.notice = .failure(failure)
			}
			return load(&state)
		}

		Pullback(\.ui.dismissImportSummary) { state in
			state.importSummary = nil
			return .none
		}
	}

	private func load(_ state: inout State) -> Effect<Action> {
		state.isLoading = true
		let profileID = state.profileID
		return .run { [engine] send in
			await send(.event(.listed(await Self.result { () async throws(BrowserSavedPasswordFailure) in
				try await engine.savedPasswords(profileID)
			})))
		}
		.cancellable(id: Cancellation.load, cancelInFlight: true)
	}

	private static func result<Value>(
		_ body: () async throws(BrowserSavedPasswordFailure) -> Value
	) async -> Result<Value, BrowserSavedPasswordFailure> {
		do {
			return .success(try await body())
		} catch {
			return .failure(error)
		}
	}

	private enum Cancellation: Hashable {
		case load
		case save
		case remove
		case reveal
		case `import`
	}
}

extension Result {
	fileprivate var failure: Failure? {
		guard case let .failure(failure) = self
		else { return nil }

		return failure
	}
}
