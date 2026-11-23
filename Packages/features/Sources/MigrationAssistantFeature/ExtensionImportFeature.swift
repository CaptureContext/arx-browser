import BrowserCore
import BrowserExtensionsClient
import Foundation
import MigrationAssistant
import _ComposableArchitecture

/// Installs the extensions an import brought from another browser (DEV-845).
///
/// After the ordinary import, `start` takes the report's extensions. Each Chrome Web Store
/// extension with a source profile is installed into the Arx profile that profile went to
/// (`MigrationAssistantClient.receivingProfile`), one at a time: the store's package is
/// downloaded and verified by ID (`BrowserExtensionsClient.prepareWebstoreImport`, ABI47)
/// and the user reviews its permissions in the same sheet as any install. Nothing installs
/// without a click: Install for one, or Install All (DEV-1300), which installs this one and
/// every one after it with the permissions each asks for, without showing their reviews.
/// The others are listed to reinstall by hand. Every extension ends with an outcome:
/// installed, already there, declined, skipped, failed, or not from the store. A failure
/// never waits for a press: the series moves on and the result counts it once at the end.
@Reducer
public struct ExtensionImportFeature {
	@ObservableState
	public struct State: Equatable {
		public var destination: MigrationDestination

		/// Every extension the import listed, in the source's order.
		public var items: IdentifiedArrayOf<Item>
		public var phase: Phase

		/// The review the user is answering now.
		public var prompt: BrowserExtensionInstallPrompt?

		/// An answered review is being carried out; it can't be skipped any more.
		public var isResolving: Bool

		/// Install All was chosen: every review from here on is accepted without showing it.
		public var acceptsAll: Bool

		/// The browser the extensions come from, for the review's "2 of 3 from Chrome".
		public var sourceName: String?

		/// The extensions a report lists, deduplicated by source profile and ID.
		public init(
			destination: MigrationDestination,
			report: MigrationReport,
			sourceName: String? = nil
		) {
			let listed: [MigrationIssue.Extension] = report.categories
				.filter { $0.category == .extensions }
				.flatMap(\.issues)
				.compactMap { issue in
					guard case let .reinstallManually(value) = issue.reason else { return nil }
					return value
				}
			var items: IdentifiedArrayOf<Item> = []
			for value in listed {
				items.append(.init(extension: value))
			}
			self.init(destination: destination, items: items, sourceName: sourceName)
		}

		public init(
			destination: MigrationDestination,
			items: IdentifiedArrayOf<Item> = [],
			phase: Phase = .idle,
			prompt: BrowserExtensionInstallPrompt? = nil,
			isResolving: Bool = false,
			acceptsAll: Bool = false,
			sourceName: String? = nil
		) {
			self.destination = destination
			self.items = items
			self.phase = phase
			self.prompt = prompt
			self.isResolving = isResolving
			self.acceptsAll = acceptsAll
			self.sourceName = sourceName
		}

		/// Store extensions are waiting to be installed or reviewed.
		public var isRunning: Bool {
			phase == .installing
		}

		/// The extension being installed now.
		public var current: Item? {
			items.first { $0.outcome == nil }
		}

		/// Where the current review is in the series, counting only store extensions.
		public var position: (index: Int, count: Int)? {
			let installable = items.filter(\.extension.installsFromStore)
			guard
				let current,
				let index = installable.firstIndex(where: { $0.id == current.id })
			else { return nil }

			return (index + 1, installable.count)
		}

		/// The store extensions still waiting for an outcome, the one under review included: what
		/// Install All would install.
		public var remainingCount: Int {
			items.count { $0.outcome == nil && $0.extension.installsFromStore }
		}

		/// Install All is offered from the first review, while at least two extensions are left;
		/// with one left it would be Install.
		public var offersAcceptAll: Bool {
			phase == .installing && !acceptsAll && remainingCount > 1
		}

		public var hasInstallableExtensions: Bool {
			items.contains { $0.extension.installsFromStore }
		}

		public func count(_ outcome: Outcome) -> Int {
			items.count { $0.outcome == outcome }
		}
	}

	public struct Item: Equatable, Identifiable, Sendable {
		public var `extension`: MigrationIssue.Extension

		/// The Arx profile it went to, once known.
		public var profileName: String?
		public var outcome: Outcome?

		public init(
			extension value: MigrationIssue.Extension,
			profileName: String? = nil,
			outcome: Outcome? = nil
		) {
			self.extension = value
			self.profileName = profileName
			self.outcome = outcome
		}

		public var id: String {
			(self.extension.profile?.id ?? "") + "/" + self.extension.id
		}
	}

	public enum Outcome: Equatable, Hashable, Sendable {
		case installed

		/// The Arx profile already has it.
		case alreadyInstalled

		/// The user cancelled its review.
		case declined

		/// The user skipped it with the ones after it.
		case skipped

		/// Not from the Chrome Web Store, or with no profile to go to: reinstall by hand.
		case reinstallManually
		case failed(Failure)
	}

	public enum Failure: Equatable, Hashable, Sendable {
		/// Its source profile has no Arx profile.
		case missingProfile

		/// This engine can't install from the store by ID.
		case unavailable
		case blockedByPolicy

		/// The download, the package's checks or the install failed.
		case failed
	}

	public enum Phase: Equatable, Sendable {
		case idle
		case installing
		case finished
	}

	@CasePathable
	public enum Action: Sendable {
		/// Begins installing, one extension at a time.
		case start
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			/// The user's answer to the review of `prompt`.
			case respond(BrowserExtensionInstallPrompt, Bool)

			/// Declines the current review and every one after it.
			case skipAll

			/// Installs the current one and every one after it, with the permissions each asks for,
			/// without showing their reviews (DEV-1300).
			case acceptAll
		}

		@CasePathable
		public enum Event: Sendable {
			case prepared(Item.ID, Prepared)
			case resolved(Item.ID, Outcome)
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// Every extension has its outcome.
			case finished
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public enum Prepared: Equatable, Sendable {
		case review(BrowserExtensionInstallPrompt, profileName: String)
		case done(Outcome, profileName: String?)
	}

	@Dependency(\.browserExtensions)
	private var extensions

	@Dependency(\.migrationAssistant)
	private var migration

	fileprivate enum Cancellation: Hashable {
		case step
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.start) { state in
				guard state.phase == .idle else { return .none }

				state.phase = .installing
				for id in state.items.ids where state.items[id: id]?.extension.installsFromStore == false {
					state.items[id: id]?.outcome = .reinstallManually
				}
				return next(&state)
			}

			Pullback(\.event.prepared) { state, value in
				let (id, prepared) = value
				guard state.phase == .installing, state.current?.id == id else {
					if case let .review(prompt, _) = prepared { return cancel(prompt) }
					return .none
				}

				switch prepared {
				case let .review(prompt, profileName):
					state.items[id: id]?.profileName = profileName

					// After Install All, the review is accepted as if it had been shown.
					guard !state.acceptsAll else { return resolve(&state, prompt, accept: true, id: id) }

					state.prompt = prompt
					return .none

				case let .done(outcome, profileName):
					state.items[id: id]?.profileName = profileName
					state.items[id: id]?.outcome = outcome
					return next(&state)
				}
			}

			Pullback(\.ui.respond) { state, value in
				let (prompt, accept) = value
				guard state.prompt == prompt, let id = state.current?.id else { return .none }

				return resolve(&state, prompt, accept: accept, id: id)
			}

			Pullback(\.ui.acceptAll) { state in
				guard state.phase == .installing, !state.isResolving, !state.acceptsAll else { return .none }

				state.acceptsAll = true

				// The one under review is accepted now; one still being prepared is accepted
				// when its review arrives.
				guard let prompt = state.prompt, let id = state.current?.id else { return .none }

				return resolve(&state, prompt, accept: true, id: id)
			}

			Pullback(\.ui.skipAll) { state in
				guard state.phase == .installing, !state.isResolving else { return .none }

				let prompt = state.prompt
				let currentID = state.current?.id
				state.prompt = nil
				for id in state.items.ids where state.items[id: id]?.outcome == nil {
					state.items[id: id]?.outcome = .skipped
				}

				// The one under review was seen and declined; the rest were skipped unseen.
				if prompt != nil, let currentID {
					state.items[id: currentID]?.outcome = .declined
				}
				state.phase = .finished
				return .merge(
					.cancel(id: Cancellation.step),
					prompt.map { prompt in
						.run { [extensions] _ in _ = try? await extensions.resolveInstallation(prompt, false) }
					} ?? .none,
					.send(.delegate(.finished))
				)
			}

			Pullback(\.event.resolved) { state, value in
				let (id, outcome) = value
				guard state.phase == .installing, state.current?.id == id else { return .none }

				state.isResolving = false
				state.items[id: id]?.outcome = outcome
				return next(&state)
			}
		}
	}

	/// Carries out the answer to `prompt`. Not cancellable: an accepted install finishes and is
	/// reported, failed or not, and the series moves on either way.
	private func resolve(
		_ state: inout State,
		_ prompt: BrowserExtensionInstallPrompt,
		accept: Bool,
		id: Item.ID
	) -> Effect<Action> {
		state.prompt = nil
		state.isResolving = true
		return .run { [extensions] send in
			do {
				_ = try await extensions.resolveInstallation(prompt, accept)
				await send(.event(.resolved(id, accept ? .installed : .declined)))
			} catch {
				await send(.event(.resolved(id, accept ? Self.outcome(error) : .declined)))
			}
		}
	}

	/// Prepares the next extension without an outcome, or finishes.
	private func next(_ state: inout State) -> Effect<Action> {
		guard let item = state.current else {
			state.phase = .finished
			return .send(.delegate(.finished))
		}

		let destination = state.destination
		let value = item.extension
		let id = item.id
		return .run { [extensions, migration] send in
			guard let source = value.profile else {
				await send(.event(.prepared(id, .done(.reinstallManually, profileName: nil))))
				return
			}
			guard await extensions.isWebstoreImportAvailable else {
				await send(.event(.prepared(id, .done(.failed(.unavailable), profileName: nil))))
				return
			}
			guard let profile = await migration.receivingProfile(source.id, destination) else {
				await send(.event(.prepared(id, .done(.failed(.missingProfile), profileName: nil))))
				return
			}

			do {
				let inventory = try await extensions.inspect(profile.id)
				guard !inventory.extensions.contains(where: { $0.id == value.id }) else {
					await send(.event(.prepared(id, .done(.alreadyInstalled, profileName: profile.name))))
					return
				}

				let prompt = try await extensions.prepareWebstoreImport(.init(
					inventory: inventory,
					extensionID: value.id
				))
				await send(.event(.prepared(id, .review(prompt, profileName: profile.name))))
			} catch {
				await send(.event(.prepared(id, .done(Self.outcome(error), profileName: profile.name))))
			}
		}
		.cancellable(id: Cancellation.step, cancelInFlight: true)
	}

	private func cancel(_ prompt: BrowserExtensionInstallPrompt) -> Effect<Action> {
		.run { [extensions] _ in await extensions.cancelInstallation(prompt) }
	}

	private static func outcome(_ error: any Error) -> Outcome {
		switch error as? BrowserExtensionsClient.Failure {
		case .cancelled: .declined
		case .unavailable: .failed(.unavailable)
		case .missingProfile: .failed(.missingProfile)
		case .blockedByPolicy: .failed(.blockedByPolicy)
		default: .failed(.failed)
		}
	}
}
