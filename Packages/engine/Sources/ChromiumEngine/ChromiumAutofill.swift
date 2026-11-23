import ChromiumBridge
import CoreGraphics
import Foundation

/// ABI52 (DEV-875, DEV-893). One suggestion for a page's focused field. It names an
/// account, an address or a masked card; never a password, card number or code.
public struct ChromiumAutofillItem: Decodable, Equatable, Sendable {
	public enum Kind: String, Decodable, Equatable, Sendable {
		case password
		case address
		case card

		/// Something typed into this field before, or the page's own list.
		case text

		/// Undoes the last fill.
		case undo
		case managePasswords
		case manageAddresses
		case manageCards
	}

	/// The suggestion's index in native's list; accept it with this.
	public var index: UInt32
	public var kind: Kind
	public var title: String
	public var subtitle: String?

	public init(
		index: UInt32,
		kind: Kind,
		title: String,
		subtitle: String? = nil
	) {
		self.index = index
		self.kind = kind
		self.title = title
		self.subtitle = subtitle
	}
}

/// The suggestions shown for a page's focused field.
public struct ChromiumAutofillSuggestions: Equatable, Sendable {
	public enum Product: String, Decodable, Equatable, Sendable {
		case password, address, card, other
	}

	public var page: UInt64
	public var session: UInt64
	public var product: Product

	/// The field, in the page view's points from its top left.
	public var field: CGRect
	public var isRightToLeft: Bool

	/// The item index the arrow keys chose, if any.
	public var selected: UInt32?
	public var items: [ChromiumAutofillItem]

	public init(
		page: UInt64,
		session: UInt64,
		product: Product,
		field: CGRect,
		isRightToLeft: Bool,
		selected: UInt32?,
		items: [ChromiumAutofillItem]
	) {
		self.page = page
		self.session = session
		self.product = product
		self.field = field
		self.isRightToLeft = isRightToLeft
		self.selected = selected
		self.items = items
	}
}

public enum ChromiumAutofillEvent: Equatable, Sendable {
	public enum SettingsList: String, Decodable, Equatable, Sendable {
		case passwords, addresses, cards
	}

	case shown(ChromiumAutofillSuggestions)

	/// `open` asks for that Settings list: a Manage item was chosen.
	case hidden(page: UInt64, session: UInt64, open: SettingsList?)

	public var page: UInt64 {
		switch self {
		case let .shown(suggestions): suggestions.page
		case let .hidden(page, _, _): page
		}
	}
}

/// When a fill asks the device owner (Touch ID or the login password) first.
public enum ChromiumAutofillAuthentication: Equatable, Sendable {
	/// Passwords and cards ask.
	case askDeviceOwner

	/// Passwords fill at once; cards still ask.
	case fillPasswordsWithoutAsking

	/// Every fill that would ask is refused.
	case refuse

	internal var native: ArxAutofillAuthentication {
		switch self {
		case .askDeviceOwner: ARX_AUTOFILL_ASK_DEVICE_OWNER
		case .fillPasswordsWithoutAsking: ARX_AUTOFILL_FILL_PASSWORDS_WITHOUT_ASKING
		case .refuse: ARX_AUTOFILL_REFUSE_AUTHENTICATED_FILLS
		}
	}
}

/// Autofill observers. Native owns the suggestions and their sessions.
@MainActor
internal final class ChromiumAutofill {
	internal static let maximumSize: Int = 64 * 1_024

	private let api: ArxEngineAPI
	private var observers: [UUID: AsyncStream<ChromiumAutofillEvent>.Continuation] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.accept_autofill_suggestion != nil
		&& api.select_autofill_suggestion != nil
		&& api.dismiss_autofill_suggestions != nil
		&& api.set_autofill_authentication != nil
	}

	internal func events() -> AsyncStream<ChromiumAutofillEvent> {
		let token = UUID()
		let (stream, continuation) = AsyncStream<ChromiumAutofillEvent>.makeStream()
		observers[token] = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.observers[token] = nil }
		}
		return stream
	}

	internal func changed(
		page: UInt64,
		session: UInt64,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let json, (1...Self.maximumSize).contains(count)
		else { return }

		guard let event = Self.event(page: page, session: session, body: Data(bytes: json, count: count))
		else { return }

		for continuation in observers.values { continuation.yield(event) }
	}

	internal func accept(
		page: UInt64,
		session: UInt64,
		index: UInt32
	) -> Bool {
		api.accept_autofill_suggestion?(page, session, index) ?? false
	}

	internal func select(
		page: UInt64,
		session: UInt64,
		index: UInt32?
	) {
		api.select_autofill_suggestion?(page, session, index.map { Int32(clamping: $0) } ?? -1)
	}

	internal func dismiss(
		page: UInt64,
		session: UInt64
	) {
		api.dismiss_autofill_suggestions?(page, session)
	}

	internal func configure(
		_ mode: ChromiumAutofillAuthentication,
		passwordReason: String,
		cardReason: String
	) {
		guard let set = api.set_autofill_authentication else { return }

		passwordReason.withCString { password in
			cardReason.withCString { card in set(mode.native, password, card) }
		}
	}

	internal func stop() {
		for continuation in observers.values { continuation.finish() }
		observers.removeAll()
	}

	internal static func event(
		page: UInt64,
		session: UInt64,
		body: Data
	) -> ChromiumAutofillEvent? {
		struct Native: Decodable {
			var state: String
			var open: ChromiumAutofillEvent.SettingsList?
			var product: ChromiumAutofillSuggestions.Product?
			var x: Double?
			var y: Double?
			var width: Double?
			var height: Double?
			var rtl: Bool?
			var selected: Int?
			var items: [ChromiumAutofillItem]?
		}

		guard let native = ChromiumReply.decode(Native.self, from: body)
		else { return nil }

		switch native.state {
		case "hidden":
			return .hidden(page: page, session: session, open: native.open)

		case "shown":
			guard
				let x = native.x, let y = native.y,
				let width = native.width, let height = native.height,
				[x, y, width, height].allSatisfy(\.isFinite),
				width >= 0, height >= 0,
				let items = native.items, !items.isEmpty
			else { return nil }

			let selected = native.selected.flatMap { index in
				items.contains(where: { $0.index == index }) ? UInt32(index) : nil
			}
			return .shown(.init(
				page: page,
				session: session,
				product: native.product ?? .other,
				field: CGRect(x: x, y: y, width: width, height: height),
				isRightToLeft: native.rtl ?? false,
				selected: selected,
				items: items
			))

		default:
			return nil
		}
	}
}
