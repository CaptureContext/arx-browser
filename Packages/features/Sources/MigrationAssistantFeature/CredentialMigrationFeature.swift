import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MigrationAssistant
import _ComposableArchitecture

/// "Passwords and sign-ins", a kind of data in Customize that follows its profile mapping
/// (DEV-650, DEV-842).
///
/// The assistant creates it when the user turns the kind on. While the user reviews, it
/// says how passwords will move (straight from the browser, or from a CSV export per source
/// profile) and holds the attached files. After the ordinary import, `start` looks up the
/// Arx profile each source profile went to, and the step takes over the modal: it explains
/// macOS's Keychain prompt first, runs only in the foreground after the device owner
/// confirms, lets the user choose passwords and sign-ins per site and per profile, reports
/// each site after checking it, and undoes a write as one batch. MCP and agents have no
/// path here.
@Reducer
public struct CredentialMigrationFeature {
	@ObservableState
	public struct State: Equatable {
		public var sourceID: MigrationSource.ID
		public var sourceName: String

		/// Source profiles the user mapped in Customize, in source order. Empty when the
		/// source isn't mapped: then everything goes into the destination's profile.
		public var mappedProfiles: [MigrationSourceProfile]
		public var phase: Phase

		/// The browser's profiles as the direct path reads them, or nil when it can't.
		public var source: CredentialSource?

		/// The engine takes decrypted records (ABI46).
		public var canWrite: Bool

		/// How passwords move. Set once loaded.
		public var mode: Mode?

		/// A CSV export per source profile, by `MigrationSourceProfile.ID`.
		public var csvFiles: [String: URL]

		/// Each source profile and the Arx profile that received it, after `start`.
		public var targets: IdentifiedArrayOf<Target>

		/// What the direct read found, per source profile, with the user's choices.
		public var inventories: IdentifiedArrayOf<ProfileInventory>
		public var reports: IdentifiedArrayOf<ProfileReport>
		public var csvResults: IdentifiedArrayOf<ProfileCSVResult>
		public var problem: Problem?

		public init(
			sourceID: MigrationSource.ID,
			sourceName: String,
			mappedProfiles: [MigrationSourceProfile] = [],
			phase: Phase = .loading,
			source: CredentialSource? = nil,
			canWrite: Bool = false,
			mode: Mode? = nil,
			csvFiles: [String: URL] = [:],
			targets: IdentifiedArrayOf<Target> = [],
			inventories: IdentifiedArrayOf<ProfileInventory> = [],
			reports: IdentifiedArrayOf<ProfileReport> = [],
			csvResults: IdentifiedArrayOf<ProfileCSVResult> = [],
			problem: Problem? = nil
		) {
			self.sourceID = sourceID
			self.sourceName = sourceName
			self.mappedProfiles = mappedProfiles
			self.phase = phase
			self.source = source
			self.canWrite = canWrite
			self.mode = mode
			self.csvFiles = csvFiles
			self.targets = targets
			self.inventories = inventories
			self.reports = reports
			self.csvResults = csvResults
			self.problem = problem
		}

		/// The source profiles passwords come from: the mapped ones, otherwise the browser's
		/// own, otherwise the whole source as one.
		public var sourceProfiles: [MigrationSourceProfile] {
			if !mappedProfiles.isEmpty { return mappedProfiles }
			if let profiles = source?.profiles, !profiles.isEmpty { return profiles }
			return [.init(id: Self.wholeSource, name: sourceName)]
		}

		/// The step has taken over the modal, after the ordinary import.
		public var isRunning: Bool {
			switch phase {
			case .loading, .configuring: false
			default: true
			}
		}

		/// Customize can import: the kind is loaded, and a CSV is attached in CSV mode.
		public var isReady: Bool {
			guard phase == .configuring, let mode else { return false }

			switch mode {
			case .direct: return true
			case .csv: return !csvFiles.isEmpty
			}
		}

		/// Files can be attached while the user reviews, or after the direct path fell back.
		public var canAttachCSV: Bool {
			switch phase {
			case .configuring: mode?.isCSV == true
			case .csv: true
			default: false
			}
		}

		public var canContinue: Bool {
			phase == .intro && !readableTargets.isEmpty
		}

		/// Targets the direct path can read: received by an Arx profile and listed by the
		/// browser.
		public var readableTargets: [Target] {
			let listed = Set(source?.profiles.map(\.id) ?? [])
			return targets.filter { $0.profileID != nil && listed.contains($0.id) }
		}

		public var canImport: Bool {
			phase == .choosing && inventories.contains { !$0.selection.isEmpty }
		}

		public var canImportCSV: Bool {
			guard case .csv = phase else { return false }

			return targets.contains { $0.profileID != nil && csvFiles[$0.id] != nil }
		}

		/// Closing is refused while Arx reads or writes.
		public var canClose: Bool {
			switch phase {
			case .reading, .importing, .undoing, .importingCSV, .resolving: false
			default: true
			}
		}

		/// The ID standing for a whole source without profiles of its own. It goes into the
		/// destination's profile, like the import's items without a profile (DEV-844).
		public static let wholeSource: String = MigrationSourceProfile.wholeSource

		/// Whether this source profile's file already went in, so it takes no other.
		public func hasImportedCSV(_ id: String) -> Bool {
			if case .success = csvResults[id: id]?.result { return true }
			return false
		}
	}

	public enum Mode: Equatable, Sendable {
		/// Straight from the browser, after one Keychain read.
		case direct
		case csv(CSVReason)

		public var isCSV: Bool {
			if case .csv = self { return true }
			return false
		}
	}

	/// A source profile and where its passwords go.
	public struct Target: Equatable, Identifiable, Sendable {
		/// The source profile's ID.
		public var id: String
		public var sourceName: String

		/// The Arx profile that received the source profile. Nil when nothing else came
		/// from it, so no Arx profile exists for it yet.
		public var profileID: Profile.ID?
		public var profileName: String

		public init(
			id: String,
			sourceName: String,
			profileID: Profile.ID?,
			profileName: String
		) {
			self.id = id
			self.sourceName = sourceName
			self.profileID = profileID
			self.profileName = profileName
		}
	}

	public struct ProfileInventory: Equatable, Identifiable, Sendable {
		public var inventory: CredentialInventory
		public var selection: CredentialSelection

		public var id: String { inventory.sourceProfileID }

		public init(
			inventory: CredentialInventory,
			selection: CredentialSelection
		) {
			self.inventory = inventory
			self.selection = selection
		}

		/// Sites whose sign-ins can move: persistent cookies Arx could decrypt.
		public var movableHosts: Set<String> {
			Set(inventory.sites.filter { $0.cookieCount > 0 }.map(\.host))
		}
	}

	public struct ProfileReport: Equatable, Identifiable, Sendable {
		/// The source profile's ID.
		public var id: String

		/// Nil when this profile's write failed.
		public var report: CredentialReport?

		public init(
			id: String,
			report: CredentialReport?
		) {
			self.id = id
			self.report = report
		}
	}

	public struct ProfileCSVResult: Equatable, Identifiable, Sendable {
		/// The source profile's ID.
		public var id: String
		public var result: Result<CSVResult, CSVFailure>

		public init(
			id: String,
			result: Result<CSVResult, CSVFailure>
		) {
			self.id = id
			self.result = result
		}
	}

	public enum Phase: Equatable, Sendable {
		case loading

		/// Shown inside Customize while the user reviews the import.
		case configuring

		/// After the ordinary import: looking up the Arx profile of each source profile.
		case resolving

		/// Explains what moves and macOS's prompt, with the mapping.
		case intro

		/// Confirming the device owner, then the one Keychain read and decryption.
		case reading

		/// Passwords and the sign-ins list per profile, each selectable.
		case choosing
		case importing
		case finished
		case undoing
		case undone

		/// The CSV path after the import: files per source profile, and why Arx is on it.
		case csv(CSVReason)
		case importingCSV
		case csvFinished
	}

	public enum CSVReason: Equatable, Sendable {
		/// The user chose it over the Keychain read.
		case chosen

		/// Deny in macOS's prompt. Arx doesn't ask again in this run.
		case denied

		/// The browser has no key Arx can read.
		case missing

		/// This engine can't take decrypted records yet; the Keychain wasn't read.
		case engineNotReady

		/// Arx doesn't know this browser's Keychain item.
		case unsupported

		/// Safari's passwords are in the Passwords app, which other apps can't read, so
		/// they come from its export (DEV-840).
		case passwordsApp

		/// Firefox or Zen has a primary password, which Arx doesn't ask for (DEV-896).
		case primaryPassword
	}

	public enum Problem: Equatable, Sendable {
		/// Arx wasn't the active app.
		case notForeground

		/// The device owner didn't confirm.
		case presenceDenied
		case unreadable
		case writeFailed
		case undoFailed
	}

	public enum CSVFailure: Error, Equatable, Sendable {
		case unreadableFile
		case badFormat
		case tooLarge
		case unavailable
		case failed
	}

	public struct CSVResult: Equatable, Sendable {
		public var imported: Int
		public var conflicts: Int
		public var skipped: Int

		public init(
			imported: Int,
			conflicts: Int,
			skipped: Int
		) {
			self.imported = imported
			self.conflicts = conflicts
			self.skipped = skipped
		}
	}

	@CasePathable
	public enum Action: Sendable {
		/// Reads what the source offers, when the kind is turned on.
		case load

		/// The ordinary import ran into `destination`; find each source profile's Arx profile.
		case start(MigrationDestination)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// Confirm the device owner, then read the Keychain.
			case `continue`

			/// CSV exports instead of the Keychain read.
			case useCSV

			/// Back to the Keychain read from CSV, while reviewing.
			case useDirect
			case togglePasswords(String)
			case toggleSite(String, host: String)
			case setAllSites(String, Bool)
			case startImport
			case undo

			/// A CSV export for a source profile.
			case csvChosen(String, URL)
			case removeCSV(String)
			case importCSV
			case close
		}

		@CasePathable
		public enum Event: Sendable {
			case loaded(CredentialSource?, canWrite: Bool)
			case resolved([Target])
			case read(Result<[CredentialInventory], CredentialMigrationFailure>)
			case migrated([ProfileReport])

			/// The source profiles whose batches were undone, and whether every batch was.
			case undone(Set<String>, isComplete: Bool)
			case csvImported([ProfileCSVResult])
		}

		@CasePathable
		public enum Delegate: Sendable {
			case closed
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.credentialMigration)
	private var credentials

	@Dependency(\.migrationAssistant)
	private var migration

	fileprivate enum Cancellation: Hashable {
		case load
		case resolve
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		configuring
		reading
		writing
		csv
	}

	// MARK: - Configuring

	private var configuring: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.load) { state in
				guard state.phase == .loading else { return .none }

				let sourceID = state.sourceID
				return .run { [credentials] send in
					let source = await credentials.source(sourceID)
					let canWrite = await credentials.canWrite()
					await send(.event(.loaded(source, canWrite: canWrite)))
				}
				.cancellable(id: Cancellation.load, cancelInFlight: true)
			}

			Pullback(\.event.loaded) { state, value in
				guard state.phase == .loading else { return .none }

				let (source, canWrite) = value
				state.source = source
				state.canWrite = canWrite
				state.phase = .configuring

				// Safari's sign-ins are read directly (DEV-896); its passwords always come from
				// the Passwords app's export.
				state.mode = if source == nil {
					state.sourceID == .safari ? .csv(.passwordsApp) : .csv(.unsupported)
				} else if !canWrite {
					.csv(.engineNotReady)
				} else {
					.direct
				}
				return .none
			}

			Pullback(\.ui.useCSV) { state in
				switch state.phase {
				case .configuring where state.mode == .direct:
					state.mode = .csv(.chosen)

				case .intro:
					state.mode = .csv(.chosen)
					state.phase = .csv(.chosen)
					state.problem = nil

				default:
					break
				}
				return .none
			}

			Pullback(\.ui.useDirect) { state in
				guard
					state.phase == .configuring,
					state.mode == .csv(.chosen),
					state.source != nil,
					state.canWrite
				else { return .none }

				state.mode = .direct
				state.csvFiles = [:]
				return .none
			}

			Pullback(\.start) { state, destination in
				guard state.phase == .configuring else { return .none }

				let profiles = state.sourceProfiles
				state.phase = .resolving
				state.problem = nil
				return .run { [migration] send in
					var targets: [Target] = []
					for profile in profiles {
						let received = await migration.receivingProfile(profile.id, destination)
						targets.append(
							.init(
								id: profile.id,
								sourceName: profile.name,
								profileID: received?.id,
								profileName: received?.name ?? ""
							)
						)
					}
					await send(.event(.resolved(targets)))
				}
				.cancellable(id: Cancellation.resolve, cancelInFlight: true)
			}

			Pullback(\.event.resolved) { state, targets in
				guard state.phase == .resolving else { return .none }

				state.targets = .init(uniqueElements: targets)
				switch state.mode {
				case .direct, nil:
					state.phase = .intro
					return .none

				case let .csv(reason):
					state.phase = .csv(reason)

					// The files attached while reviewing go in now; the user already chose Import.
					return state.canImportCSV ? state.importCSV(engine) : .none
				}
			}
		}
	}

	// MARK: - Reading

	private var reading: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.continue) { state in
				guard state.canContinue else { return .none }

				let sourceID = state.sourceID
				let profiles = state.readableTargets.map(\.id)
				let reason = String.localized(.appUI.migration.credentials.presenceReason(state.sourceName))
				state.phase = .reading
				state.problem = nil
				return .run { [credentials] send in
					guard await credentials.isForeground() else {
						return await send(.event(.read(.failure(.notForeground))))
					}
					guard await credentials.confirmPresence(reason) else {
						return await send(.event(.read(.failure(.presenceDenied))))
					}

					// Touch ID or the password can take a while; Arx may have lost focus.
					guard await credentials.isForeground() else {
						return await send(.event(.read(.failure(.notForeground))))
					}

					do {
						await send(.event(.read(.success(try await credentials.readProfiles(sourceID, profiles)))))
					} catch {
						await send(.event(.read(.failure(error as? CredentialMigrationFailure ?? .unreadable))))
					}
				}
			}

			Pullback(\.event.read) { state, result in
				guard state.phase == .reading else {
					// Nothing may hold decrypted records the step no longer shows.
					guard case let .success(inventories) = result else { return .none }

					return .run { [credentials] _ in
						for inventory in inventories {
							await credentials.discard(inventory.sessionID)
						}
					}
				}

				switch result {
				case let .success(inventories):
					state.phase = .choosing
					state.inventories = .init(
						uniqueElements: inventories.map { .init(inventory: $0, selection: .all(in: $0)) }
					)

				case .failure(.keyDenied):
					state.fallBackToCSV(.denied)

				case .failure(.keyMissing):
					state.fallBackToCSV(.missing)

				case .failure(.primaryPassword):
					state.fallBackToCSV(.primaryPassword)

				case .failure(.writerUnavailable):
					state.fallBackToCSV(.engineNotReady)

				case .failure(.notForeground):
					state.phase = .intro
					state.problem = .notForeground

				case .failure(.presenceDenied):
					state.phase = .intro
					state.problem = .presenceDenied

				case .failure:
					state.phase = .intro
					state.problem = .unreadable
				}
				return .none
			}

			Pullback(\.ui.togglePasswords) { state, id in
				guard
					state.phase == .choosing,
					let profile = state.inventories[id: id],
					profile.inventory.passwordCount > 0
				else { return .none }

				state.inventories[id: id]?.selection.passwords.toggle()
				return .none
			}

			Pullback(\.ui.toggleSite) { state, value in
				let (id, host) = value
				guard
					state.phase == .choosing,
					let profile = state.inventories[id: id],
					profile.movableHosts.contains(host)
				else { return .none }

				if profile.selection.signInHosts.contains(host) {
					state.inventories[id: id]?.selection.signInHosts.remove(host)
				} else {
					state.inventories[id: id]?.selection.signInHosts.insert(host)
				}
				return .none
			}

			Pullback(\.ui.setAllSites) { state, value in
				let (id, isOn) = value
				guard
					state.phase == .choosing,
					let profile = state.inventories[id: id]
				else { return .none }

				state.inventories[id: id]?.selection.signInHosts = isOn ? profile.movableHosts : []
				return .none
			}
		}
	}

	// MARK: - Writing

	private var writing: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.startImport) { state in
				guard state.canImport else { return .none }

				let writes: [(id: String, session: UUID, selection: CredentialSelection, profile: Profile.ID?)] = state
					.inventories
					.map { ($0.id, $0.inventory.sessionID, $0.selection, state.targets[id: $0.id]?.profileID) }
				state.phase = .importing
				state.problem = nil
				return .run { [credentials] send in
					var reports: [ProfileReport] = []
					for write in writes {
						guard let profile = write.profile, !write.selection.isEmpty else {
							// Unselected records go now; they were never going to be written.
							await credentials.discard(write.session)
							continue
						}

						let report = try? await credentials.migrate(write.session, write.selection, profile)
						reports.append(.init(id: write.id, report: report))
					}
					await send(.event(.migrated(reports)))
				}
			}

			Pullback(\.event.migrated) { state, reports in
				guard state.phase == .importing else { return .none }

				// The decrypted records were used up either way; reading again starts over.
				state.inventories = []
				guard reports.contains(where: { $0.report != nil }) else {
					state.phase = .intro
					state.problem = .writeFailed
					return .none
				}

				state.phase = .finished
				state.reports = .init(uniqueElements: reports)

				// A profile whose write failed is named in the report.
				state.problem = nil
				return .none
			}

			Pullback(\.ui.undo) { state in
				guard state.phase == .finished else { return .none }

				let batches: [(id: String, batch: UUID)] = state.reports.compactMap { profile in
					profile.report.map { (profile.id, $0.batchID) }
				}
				state.phase = .undoing
				state.problem = nil
				return .run { [credentials] send in
					var undone: Set<String> = []
					for value in batches {
						do {
							try await credentials.undo(value.batch)
							undone.insert(value.id)
						} catch {
							continue
						}
					}
					await send(.event(.undone(undone, isComplete: undone.count == batches.count)))
				}
			}

			Pullback(\.event.undone) { state, value in
				guard state.phase == .undoing else { return .none }

				let (undone, isComplete) = value

				// An undone batch is gone, so trying again covers only the ones still there.
				state.reports.removeAll { undone.contains($0.id) }
				if isComplete {
					state.phase = .undone
				} else {
					state.phase = .finished
					state.problem = .undoFailed
				}
				return .none
			}

			Pullback(\.ui.close) { state in
				guard state.canClose, state.isRunning else { return .none }

				// Unwritten records are dropped as soon as the step closes.
				let unwritten = state.phase == .choosing ? state.inventories.map(\.inventory.sessionID) : []
				state.inventories = []
				return .merge(
					.cancel(id: Cancellation.load),
					.cancel(id: Cancellation.resolve),
					.run { [credentials] send in
						for session in unwritten {
							await credentials.discard(session)
						}
						await send(.delegate(.closed))
					}
				)
			}
		}
	}

	// MARK: - CSV

	private var csv: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.ui.csvChosen) { state, value in
				let (id, url) = value
				guard
					state.canAttachCSV,
					state.sourceProfiles.contains(where: { $0.id == id }),
					!state.hasImportedCSV(id)
				else { return .none }

				state.csvFiles[id] = url
				return .none
			}

			Pullback(\.ui.removeCSV) { state, id in
				guard state.canAttachCSV else { return .none }

				state.csvFiles[id] = nil
				return .none
			}

			Pullback(\.ui.importCSV) { state in
				guard state.canImportCSV else { return .none }

				return state.importCSV(engine)
			}

			Pullback(\.event.csvImported) { state, results in
				guard state.phase == .importingCSV else { return .none }

				for result in results {
					state.csvResults[id: result.id] = result

					// A file that went in is done; a failed one stays to try again or replace.
					if case .success = result.result {
						state.csvFiles[result.id] = nil
					}
				}
				guard
					results.contains(where: { if case .failure = $0.result { true } else { false } }),
					case let .csv(reason) = state.mode
				else {
					state.phase = .csvFinished
					return .none
				}

				state.phase = .csv(reason)
				return .none
			}
		}
	}
}

extension CredentialMigrationFeature.State {
	fileprivate mutating func fallBackToCSV(_ reason: CredentialMigrationFeature.CSVReason) {
		mode = .csv(reason)
		phase = .csv(reason)
	}

	/// Imports each attached file into the Arx profile its source profile went to.
	fileprivate mutating func importCSV(
		_ engine: BrowserEngineClient
	) -> Effect<CredentialMigrationFeature.Action> {
		let imports: [(id: String, profile: Profile.ID, url: URL)] = targets.compactMap { target in
			guard let profile = target.profileID, let url = csvFiles[target.id] else { return nil }

			return (target.id, profile, url)
		}
		phase = .importingCSV
		problem = nil
		return .run { send in
			var results: [CredentialMigrationFeature.ProfileCSVResult] = []
			for value in imports {
				do {
					let summary = try await engine.importPasswords(value.profile, value.url)
					results.append(
						.init(
							id: value.id,
							result: .success(
								.init(
									imported: summary.imported,
									conflicts: summary.conflictCount,
									skipped: summary.skippedCount
								)
							)
						)
					)
				} catch {
					results.append(.init(id: value.id, result: .failure(.init(error))))
				}
			}
			await send(.event(.csvImported(results)))
		}
	}
}

extension CredentialMigrationFeature.CSVFailure {
	fileprivate init(_ error: any Error) {
		switch error as? BrowserSavedPasswordFailure {
		case .unreadableFile: self = .unreadableFile
		case .badFormat: self = .badFormat
		case .fileTooLarge, .tooManyPasswords: self = .tooLarge
		case .unavailable: self = .unavailable
		default: self = .failed
		}
	}
}
