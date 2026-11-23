import BrowserCore
import CoreGraphics
import Foundation

/// One autofill suggestion for a tab's focused field (DEV-875, DEV-893). It names a
/// saved account, an address or a masked card; the engine keeps every value.
public struct BrowserAutofillItem: Equatable, Identifiable, Sendable {
	public enum Kind: Equatable, Sendable {
		case password
		case address
		case card

		/// Something typed into this field before, or the page's own list.
		case text
		case undo
		case manage(BrowserAutofillList)
	}

	/// The engine's index for this suggestion.
	public var id: UInt32
	public var kind: Kind
	public var title: String
	public var subtitle: String?

	public init(
		id: UInt32,
		kind: Kind,
		title: String,
		subtitle: String? = nil
	) {
		self.id = id
		self.kind = kind
		self.title = title
		self.subtitle = subtitle
	}
}

/// A Settings list a Manage suggestion opens.
public enum BrowserAutofillList: Equatable, Sendable {
	case passwords, addresses, cards
}

/// The suggestions shown for a tab's focused field.
public struct BrowserAutofillSuggestions: Equatable, Sendable {
	public var tabID: Tab.ID
	public var session: UInt64

	/// The field, in the tab's page view, in points from its top left.
	public var field: CGRect
	public var isRightToLeft: Bool

	/// The suggestion the arrow keys chose.
	public var selected: BrowserAutofillItem.ID?
	public var items: [BrowserAutofillItem]

	public init(
		tabID: Tab.ID,
		session: UInt64,
		field: CGRect,
		isRightToLeft: Bool,
		selected: BrowserAutofillItem.ID?,
		items: [BrowserAutofillItem]
	) {
		self.tabID = tabID
		self.session = session
		self.field = field
		self.isRightToLeft = isRightToLeft
		self.selected = selected
		self.items = items
	}
}

public enum BrowserAutofillEvent: Equatable, Sendable {
	case shown(BrowserAutofillSuggestions)

	/// `open` asks for that Settings list: a Manage suggestion was chosen.
	case hidden(Tab.ID, session: UInt64, open: BrowserAutofillList?)
}

/// When a fill asks for Touch ID or the login password first.
public enum BrowserAutofillAuthentication: Equatable, Sendable {
	/// Passwords and cards ask.
	case ask

	/// Passwords fill at once; cards still ask.
	case fillPasswordsWithoutAsking
}

// MARK: - Settings › Autofill (DEV-893)

/// A saved address in one ordinary profile.
public struct BrowserAutofillAddress: Equatable, Identifiable, Sendable {
	/// Empty for a new address.
	public var id: String
	public var name: String
	public var organization: String
	public var street: String
	public var city: String
	public var state: String
	public var zip: String

	/// A two-letter country code, or empty.
	public var country: String
	public var phone: String
	public var email: String

	public init(
		id: String = "",
		name: String = "",
		organization: String = "",
		street: String = "",
		city: String = "",
		state: String = "",
		zip: String = "",
		country: String = "",
		phone: String = "",
		email: String = ""
	) {
		self.id = id
		self.name = name
		self.organization = organization
		self.street = street
		self.city = city
		self.state = state
		self.zip = zip
		self.country = country
		self.phone = phone
		self.email = email
	}
}

/// A saved payment card by what its face shows in a list; the engine keeps its number.
public struct BrowserAutofillCard: Equatable, Identifiable, Sendable {
	public var id: String
	public var name: String
	public var network: String
	public var lastFour: String
	public var month: Int
	public var year: Int
	public var nickname: String

	public init(
		id: String,
		name: String,
		network: String,
		lastFour: String,
		month: Int,
		year: Int,
		nickname: String = ""
	) {
		self.id = id
		self.name = name
		self.network = network
		self.lastFour = lastFour
		self.month = month
		self.year = year
		self.nickname = nickname
	}
}

/// A new or edited card. Its number is in the lent field, never here.
public struct BrowserAutofillCardEdit: Equatable, Sendable {
	public var profileID: Profile.ID

	/// Nil for a new card.
	public var id: String?
	public var name: String
	public var nickname: String
	public var month: Int
	public var year: Int

	/// The field holding the number; nil or empty keeps an edited card's number.
	public var numberField: BrowserPasswordFieldID?

	public init(
		profileID: Profile.ID,
		id: String?,
		name: String,
		nickname: String,
		month: Int,
		year: Int,
		numberField: BrowserPasswordFieldID?
	) {
		self.profileID = profileID
		self.id = id
		self.name = name
		self.nickname = nickname
		self.month = month
		self.year = year
		self.numberField = numberField
	}
}

public struct BrowserAutofillListing: Equatable, Sendable {
	public var addresses: [BrowserAutofillAddress]
	public var cards: [BrowserAutofillCard]

	public init(
		addresses: [BrowserAutofillAddress] = [],
		cards: [BrowserAutofillCard] = []
	) {
		self.addresses = addresses
		self.cards = cards
	}
}

public enum BrowserAutofillDataFailure: Error, Equatable, Sendable {
	case unavailable

	/// Empty or malformed fields, or a card number that isn't valid.
	case invalid
	case notFound
	case busy

	/// Fill addresses or Fill payment cards is off, so that kind can't be added or edited.
	case disabled
}

extension BrowserEngineClient {
	public typealias AutofillListingRequest = @MainActor @Sendable (
		Profile.ID
	) async throws(BrowserAutofillDataFailure) -> BrowserAutofillListing

	public typealias SaveAutofillAddress = @MainActor @Sendable (
		Profile.ID,
		BrowserAutofillAddress
	) async throws(BrowserAutofillDataFailure) -> BrowserAutofillListing

	public typealias SaveAutofillCard = @MainActor @Sendable (
		BrowserAutofillCardEdit
	) async throws(BrowserAutofillDataFailure) -> BrowserAutofillListing

	public typealias RemoveAutofillData = @MainActor @Sendable (
		Profile.ID,
		_ id: String
	) async throws(BrowserAutofillDataFailure) -> BrowserAutofillListing
}
