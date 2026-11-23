import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// One ordinary profile's addresses and payment cards (DEV-893): list, add, edit and
/// remove. State holds what a card's face shows in a list; a card number goes from an
/// AppKit field the view lends straight to the engine.
@Reducer
public struct AutofillDataFeature {
	@ObservableState
	public struct State: Equatable {
		public var profileID: Profile.ID
		public var profileName: String
		public var listing: BrowserAutofillListing
		public var isLoading: Bool
		public var addressEditor: BrowserAutofillAddress?
		public var cardEditor: CardEditor?
		public var removal: Removal?
		public var isSaving: Bool
		public var failure: BrowserAutofillDataFailure?

		public init(
			profileID: Profile.ID,
			profileName: String,
			listing: BrowserAutofillListing = .init(),
			isLoading: Bool = true
		) {
			self.profileID = profileID
			self.profileName = profileName
			self.listing = listing
			self.isLoading = isLoading
			self.addressEditor = nil
			self.cardEditor = nil
			self.removal = nil
			self.isSaving = false
			self.failure = nil
		}
	}

	/// The add or edit form for a card. The number is in the lent field, never here.
	public struct CardEditor: Equatable, Sendable {
		/// Nil for a new card.
		public var id: String?
		public var name: String
		public var nickname: String
		public var month: Int
		public var year: Int

		/// Shown on an edit, so the user knows which card it is.
		public var lastFour: String
		public var numberField: BrowserPasswordFieldID

		public init(
			id: String?,
			name: String,
			nickname: String,
			month: Int,
			year: Int,
			lastFour: String,
			numberField: BrowserPasswordFieldID
		) {
			self.id = id
			self.name = name
			self.nickname = nickname
			self.month = month
			self.year = year
			self.lastFour = lastFour
			self.numberField = numberField
		}
	}

	public struct Removal: Equatable, Sendable {
		public var id: String
		public var title: String

		public init(
			id: String,
			title: String
		) {
			self.id = id
			self.title = title
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
			case addAddress
			case editAddress(String)
			case addressChanged(BrowserAutofillAddress)
			case saveAddress
			case addCard
			case editCard(String)
			case cardChanged(CardEditor)
			case saveCard
			case cancelEditor
			case remove(String)
			case confirmRemoval
			case cancelRemoval
			case dismissFailure
			case done
		}

		@CasePathable
		public enum Event: Sendable {
			case listed(Result<BrowserAutofillListing, BrowserAutofillDataFailure>)
			case changed(Result<BrowserAutofillListing, BrowserAutofillDataFailure>)
			case removed(Result<BrowserAutofillListing, BrowserAutofillDataFailure>)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case dismiss
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	private enum Cancellation: Hashable {
		case load
		case change
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.date.now)
	private var now

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.appeared) { state in
			state.isLoading = true
			let profile = state.profileID
			return .run { [engine] send in
				await send(.event(.listed(await Self.result { () async throws(BrowserAutofillDataFailure) in
					try await engine.autofillListing(profile)
				})))
			}
			.cancellable(id: Cancellation.load, cancelInFlight: true)
		}

		Pullback(\.event.listed) { state, result in
			state.isLoading = false
			switch result {
			case let .success(listing): state.listing = listing
			case let .failure(failure): state.failure = failure
			}
			return .none
		}

		addresses
		cards

		Pullback(\.ui.cancelEditor) { state in
			state.addressEditor = nil
			state.cardEditor = nil
			state.isSaving = false
			return .cancel(id: Cancellation.change)
		}

		Pullback(\.ui.remove) { state, id in
			if let address = state.listing.addresses.first(where: { $0.id == id }) {
				state.removal = .init(id: id, title: Self.title(address))
			} else if let card = state.listing.cards.first(where: { $0.id == id }) {
				state.removal = .init(id: id, title: Self.title(card))
			}
			return .none
		}

		Pullback(\.ui.cancelRemoval) { state in
			state.removal = nil
			return .none
		}

		Pullback(\.ui.confirmRemoval) { state in
			guard let removal = state.removal, !state.isSaving else { return .none }

			state.removal = nil
			state.isSaving = true
			let profile = state.profileID
			return .run { [engine] send in
				await send(.event(.removed(await Self.result { () async throws(BrowserAutofillDataFailure) in
					try await engine.removeAutofillData(profile, removal.id)
				})))
			}
			.cancellable(id: Cancellation.change, cancelInFlight: true)
		}

		// A removal leaves any form the user opened meanwhile as it is.
		Pullback(\.event.removed) { state, result in
			state.isSaving = false
			switch result {
			case let .success(listing): state.listing = listing
			case let .failure(failure): state.failure = failure
			}
			return .none
		}

		Pullback(\.event.changed) { state, result in
			state.isSaving = false
			switch result {
			case let .success(listing):
				state.listing = listing
				state.addressEditor = nil
				state.cardEditor = nil
			case let .failure(failure):
				state.failure = failure
			}
			return .none
		}

		Pullback(\.ui.dismissFailure) { state in
			state.failure = nil
			return .none
		}

		Pullback(\.ui.done) { _ in
			.merge(
				.cancel(id: Cancellation.load),
				.cancel(id: Cancellation.change),
				.send(.delegate(.dismiss))
			)
		}
	}

	@ReducerBuilder<State, Action>
	private var addresses: some ReducerOf<Self> {
		Pullback(\.ui.addAddress) { state in
			state.addressEditor = .init(country: Locale.current.region?.identifier ?? "")
			state.failure = nil
			return .none
		}

		Pullback(\.ui.editAddress) { state, id in
			state.addressEditor = state.listing.addresses.first(where: { $0.id == id })
			state.failure = nil
			return .none
		}

		Pullback(\.ui.addressChanged) { state, address in
			guard state.addressEditor != nil else { return .none }

			state.addressEditor = address
			return .none
		}

		Pullback(\.ui.saveAddress) { state in
			guard let address = state.addressEditor, !state.isSaving else { return .none }

			state.isSaving = true
			state.failure = nil
			let profile = state.profileID
			return change { [engine] () async throws(BrowserAutofillDataFailure) in
				try await engine.saveAutofillAddress(profile, address)
			}
		}
	}

	@ReducerBuilder<State, Action>
	private var cards: some ReducerOf<Self> {
		Pullback(\.ui.addCard) { state in
			let today = Calendar(identifier: .gregorian).dateComponents([.month, .year], from: now)
			state.cardEditor = .init(
				id: nil,
				name: "",
				nickname: "",
				month: today.month ?? 1,
				year: (today.year ?? 2026) + 1,
				lastFour: "",
				numberField: .init(rawValue: uuid())
			)
			state.failure = nil
			return .none
		}

		Pullback(\.ui.editCard) { state, id in
			guard let card = state.listing.cards.first(where: { $0.id == id }) else { return .none }

			state.cardEditor = .init(
				id: card.id,
				name: card.name,
				nickname: card.nickname,
				month: card.month,
				year: card.year,
				lastFour: card.lastFour,
				numberField: .init(rawValue: uuid())
			)
			state.failure = nil
			return .none
		}

		Pullback(\.ui.cardChanged) { state, editor in
			guard state.cardEditor?.numberField == editor.numberField else { return .none }

			state.cardEditor = editor
			return .none
		}

		Pullback(\.ui.saveCard) { state in
			guard let editor = state.cardEditor, !state.isSaving else { return .none }

			state.isSaving = true
			state.failure = nil
			let edit = BrowserAutofillCardEdit(
				profileID: state.profileID,
				id: editor.id,
				name: editor.name.trimmingCharacters(in: .whitespacesAndNewlines),
				nickname: editor.nickname.trimmingCharacters(in: .whitespacesAndNewlines),
				month: editor.month,
				year: editor.year,
				numberField: editor.numberField
			)
			return change { [engine] () async throws(BrowserAutofillDataFailure) in
				try await engine.saveAutofillCard(edit)
			}
		}
	}

	private func change(
		_ operation: @escaping @MainActor @Sendable () async throws(BrowserAutofillDataFailure) -> BrowserAutofillListing
	) -> Effect<Action> {
		.run { send in
			await send(.event(.changed(await Self.result(operation))))
		}
		.cancellable(id: Cancellation.change, cancelInFlight: true)
	}

	@MainActor
	private static func result(
		_ operation: @MainActor () async throws(BrowserAutofillDataFailure) -> BrowserAutofillListing
	) async -> Result<BrowserAutofillListing, BrowserAutofillDataFailure> {
		do throws(BrowserAutofillDataFailure) {
			return .success(try await operation())
		} catch {
			return .failure(error)
		}
	}

	internal static func title(_ address: BrowserAutofillAddress) -> String {
		[address.name, address.street, address.city]
			.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
			.first(where: { !$0.isEmpty }) ?? address.email
	}

	internal static func title(_ card: BrowserAutofillCard) -> String {
		let network = card.network.isEmpty ? "" : card.network.prefix(1).uppercased() + card.network.dropFirst() + " "
		return card.nickname.isEmpty ? "\(network)•••• \(card.lastFour)" : "\(card.nickname) •••• \(card.lastFour)"
	}
}
