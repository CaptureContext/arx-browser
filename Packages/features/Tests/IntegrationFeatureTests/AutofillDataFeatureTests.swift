import BrowserCore
import BrowserEngineClient
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@MainActor
@Suite(.dependencies, .serialized)
internal struct AutofillDataFeatureTests {
	private static let profileID = Profile.ID(rawValue: UUID())

	@Test
	internal func onlyListedProfilesOpenTheirAddressesAndCards() async throws {
		let profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.showAutofill(.init(rawValue: UUID()))))
		#expect(store.state.autofillData == nil)

		await store.send(.ui(.showAutofill(profile.id)))
		#expect(store.state.autofillData == .init(profileID: profile.id, profileName: "Work"))

		await store.send(.autofillData(.delegate(.dismiss)))
		#expect(store.state.autofillData == nil)

		await store.send(.ui(.showAutofill(profile.id)))
		await store.send(.configureExtensions([]))
		#expect(store.state.autofillData == nil)
	}

	@Test
	internal func appearingListsTheProfilesData() async throws {
		let engine = AutofillEngineDouble()
		let store = makeStore(engine)

		await store.send(.ui(.appeared))
		await store.receive(\.event.listed) {
			$0.isLoading = false
			$0.listing = AutofillEngineDouble.listing
		}
		#expect(engine.listed == [Self.profileID])
	}

	@Test
	internal func aNewCardSendsItsLentFieldNotItsNumber() async throws {
		let engine = AutofillEngineDouble()
		let store = makeStore(engine, loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.addCard))
		let editor = try #require(store.state.cardEditor)
		#expect(editor.id == nil)
		#expect(editor.month == 4)
		#expect(editor.year == 2027)

		var named = editor
		named.name = "  Arx Fixture  "
		await store.send(.ui(.cardChanged(named)))
		await store.send(.ui(.saveCard))
		await store.receive(\.event.changed)
		#expect(engine.cards == [.init(
			profileID: Self.profileID,
			id: nil,
			name: "Arx Fixture",
			nickname: "",
			month: 4,
			year: 2027,
			numberField: editor.numberField
		)])
		#expect(store.state.cardEditor == nil)
		#expect(store.state.listing == AutofillEngineDouble.changed)
	}

	@Test
	internal func anEditFromAnotherFormIsIgnored() async throws {
		let store = makeStore(AutofillEngineDouble(), loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.editCard("c1")))
		var other = try #require(store.state.cardEditor)
		other.numberField = .init(rawValue: UUID())
		other.name = "Someone else"
		await store.send(.ui(.cardChanged(other)))
		#expect(store.state.cardEditor?.name == "Arx Fixture")
		#expect(store.state.cardEditor?.lastFour == "1111")
	}

	@Test
	internal func addressesSaveAndFailuresStayInTheForm() async throws {
		let engine = AutofillEngineDouble()
		engine.failure = .invalid
		let store = makeStore(engine, loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.editAddress("a1")))
		#expect(store.state.addressEditor?.city == "Cupertino")
		await store.send(.ui(.saveAddress))
		await store.receive(\.event.changed)
		#expect(store.state.failure == .invalid)
		#expect(store.state.addressEditor?.id == "a1")
		#expect(engine.addresses.map(\.id) == ["a1"])
	}

	@Test
	internal func removingAsksFirst() async throws {
		let engine = AutofillEngineDouble()
		let store = makeStore(engine, loaded: true)
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.remove("c1")))
		#expect(store.state.removal == .init(id: "c1", title: "Visa •••• 1111"))
		#expect(engine.removed.isEmpty)
		await store.send(.ui(.confirmRemoval))

		// A form opened while the removal runs stays open.
		await store.send(.ui(.editAddress("a1")))
		await store.finish()
		#expect(engine.removed == ["c1"])
		#expect(store.state.addressEditor?.id == "a1")
		#expect(store.state.listing == AutofillEngineDouble.withoutCard)
	}

	private func makeStore(
		_ engine: AutofillEngineDouble,
		loaded: Bool = false
	) -> TestStoreOf<AutofillDataFeature> {
		TestStore(
			initialState: .init(
				profileID: Self.profileID,
				profileName: "Work",
				listing: loaded ? AutofillEngineDouble.listing : .init(),
				isLoading: !loaded
			)
		) {
			AutofillDataFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_775_000_000) // April 2026
		}
	}
}

@MainActor
private final class AutofillEngineDouble {
	static let listing = BrowserAutofillListing(
		addresses: [.init(id: "a1", name: "Arx Fixture", street: "1 Loop Rd", city: "Cupertino", country: "US")],
		cards: [.init(id: "c1", name: "Arx Fixture", network: "visa", lastFour: "1111", month: 4, year: 2031)]
	)

	static let changed = BrowserAutofillListing(addresses: [], cards: [])

	static let withoutCard = BrowserAutofillListing(addresses: listing.addresses, cards: [])

	var failure: BrowserAutofillDataFailure?
	var listed: [Profile.ID] = []
	var addresses: [BrowserAutofillAddress] = []
	var cards: [BrowserAutofillCardEdit] = []
	var removed: [String] = []

	var client: BrowserEngineClient {
		var client = BrowserEngineClient(status: { .ready })
		client.autofillListing = { [self] id throws(BrowserAutofillDataFailure) in
			listed.append(id)
			return Self.listing
		}
		client.saveAutofillAddress = { [self] _, address throws(BrowserAutofillDataFailure) in
			addresses.append(address)
			if let failure { throw failure }
			return Self.changed
		}
		client.saveAutofillCard = { [self] edit throws(BrowserAutofillDataFailure) in
			cards.append(edit)
			if let failure { throw failure }
			return Self.changed
		}
		client.removeAutofillData = { [self] _, id throws(BrowserAutofillDataFailure) in
			removed.append(id)
			if let failure { throw failure }
			return Self.withoutCard
		}
		return client
	}
}
