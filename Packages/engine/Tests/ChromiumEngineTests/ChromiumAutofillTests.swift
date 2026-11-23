import CoreGraphics
import Foundation
import Testing

@testable import ChromiumEngine

@MainActor
@Suite
internal struct ChromiumAutofillTests {
	@Test
	internal func shownSuggestionsDecodeWithoutValues() throws {
		let body = Data("""
		{"state":"shown","product":"password","x":12,"y":40.5,"width":200,"height":24,"rtl":false,"selected":3,
		 "items":[{"index":0,"kind":"password","title":"arx-fixture-user","subtitle":"127.0.0.1"},
		          {"index":3,"kind":"managePasswords","title":"Manage passwords…"}]}
		""".utf8)

		let event = try #require(ChromiumAutofill.event(page: 7, session: 9, body: body))
		guard case let .shown(suggestions) = event else {
			Issue.record("expected shown")
			return
		}
		#expect(suggestions.page == 7)
		#expect(suggestions.session == 9)
		#expect(suggestions.product == .password)
		#expect(suggestions.field == CGRect(x: 12, y: 40.5, width: 200, height: 24))
		#expect(suggestions.selected == 3)
		#expect(suggestions.items.map(\.kind) == [.password, .managePasswords])
		#expect(suggestions.items[0].subtitle == "127.0.0.1")
		#expect(suggestions.items[1].subtitle == nil)
	}

	@Test
	internal func aSelectionOutsideTheItemsIsNone() throws {
		let body = Data("""
		{"state":"shown","product":"card","x":0,"y":0,"width":1,"height":1,"selected":5,
		 "items":[{"index":0,"kind":"card","title":"Visa ••••1111"}]}
		""".utf8)

		let event = try #require(ChromiumAutofill.event(page: 1, session: 1, body: body))
		guard case let .shown(suggestions) = event else {
			Issue.record("expected shown")
			return
		}
		#expect(suggestions.selected == nil)
	}

	@Test
	internal func hiddenCarriesTheSettingsListToOpen() {
		let hidden = ChromiumAutofill.event(page: 2, session: 4, body: Data(#"{"state":"hidden","open":"addresses"}"#.utf8))
		#expect(hidden == .hidden(page: 2, session: 4, open: .addresses))
		let plain = ChromiumAutofill.event(page: 2, session: 4, body: Data(#"{"state":"hidden"}"#.utf8))
		#expect(plain == .hidden(page: 2, session: 4, open: nil))
	}

	@Test
	internal func malformedOrEmptySuggestionsAreDropped() {
		let empty = Data(#"{"state":"shown","x":0,"y":0,"width":1,"height":1,"items":[]}"#.utf8)
		#expect(ChromiumAutofill.event(page: 1, session: 1, body: empty) == nil)
		let unbounded = Data(#"{"state":"shown","x":0,"y":0,"width":-1,"height":1,"items":[{"index":0,"kind":"text","title":"a"}]}"#.utf8)
		#expect(ChromiumAutofill.event(page: 1, session: 1, body: unbounded) == nil)
		#expect(ChromiumAutofill.event(page: 1, session: 1, body: Data(#"{"state":"later"}"#.utf8)) == nil)
		withKnownIssue("A malformed reply from the bridge is reported") {
			#expect(ChromiumAutofill.event(page: 1, session: 1, body: Data("not json".utf8)) == nil)
		}
	}

	@Test
	internal func olderEnginesHaveNoAutofill() {
		let runtime = ChromiumRuntime(api: .init())
		#expect(!runtime.supportsAutofill)
		#expect(!runtime.autofill.isAvailable)
	}
}

@MainActor
@Suite
internal struct ChromiumAutofillDataTests {
	@Test
	internal func listingDecodesAddressesAndMaskedCards() throws {
		let body = Data("""
		{"addresses":[{"id":"a1","name":"Arx Fixture","organization":"","street":"1 Loop Rd","city":"Cupertino",
		  "state":"CA","zip":"95014","country":"US","phone":"","email":"fixture@arx.test"}],
		 "cards":[{"id":"c1","name":"Arx Fixture","network":"visa","lastFour":"1111","month":4,"year":2031,"nickname":""}]}
		""".utf8)

		let listing = try ChromiumAutofillData.listing(body)
		#expect(listing.addresses.map(\.id) == ["a1"])
		#expect(listing.addresses[0].country == "US")
		#expect(listing.cards == [.init(id: "c1", name: "Arx Fixture", network: "visa", lastFour: "1111", month: 4, year: 2031, nickname: "")])
	}

	@Test
	internal func malformedListingsAreUnavailable() {
		withKnownIssue("A malformed reply from the bridge is reported") {
			#expect(throws: ChromiumAutofillDataFailure.unavailable) {
				try ChromiumAutofillData.listing(Data(#"{"addresses":"no"}"#.utf8))
			}
		}
	}

	@Test
	internal func olderEnginesHaveNoAutofillData() async {
		let runtime = ChromiumRuntime(api: .init())
		#expect(!runtime.supportsAutofillData)
		await #expect(throws: ChromiumAutofillDataFailure.unavailable) {
			_ = try await runtime.autofillListing(profile: nil)
		}
	}
}
