import BrowserCore
import Foundation
import _Dependencies

/// A page's request for a USB, HID, serial or Bluetooth device (DEV-905), listing the devices
/// that match it. The app draws its own sheet and answers it once.
public struct BrowserDeviceChooser: Equatable, Sendable {
	public struct Option: Equatable, Sendable {
		public var name: String
		public var isConnected: Bool
		public var isPaired: Bool

		/// Bluetooth signal bars, 0-4; nil when unknown.
		public var signal: Int?

		public init(
			name: String,
			isConnected: Bool = false,
			isPaired: Bool = false,
			signal: Int? = nil
		) {
			self.name = name
			self.isConnected = isConnected
			self.isPaired = isPaired
			self.signal = signal
		}
	}

	/// Names this request; a later one for the same tab has another.
	public var token: UInt64

	/// The list's changes: an answer names the list it chose from.
	public var revision: UInt64

	/// The engine's title, naming the site and what it asks for.
	public var title: String
	public var allowsMultiple: Bool

	/// Bluetooth can scan again.
	public var canScanAgain: Bool
	public var isScanning: Bool
	public var adapterIsOff: Bool
	public var options: [Option]

	public init(
		token: UInt64,
		revision: UInt64 = 0,
		title: String,
		allowsMultiple: Bool = false,
		canScanAgain: Bool = false,
		isScanning: Bool = false,
		adapterIsOff: Bool = false,
		options: [Option] = []
	) {
		self.token = token
		self.revision = revision
		self.title = title
		self.allowsMultiple = allowsMultiple
		self.canScanAgain = canScanAgain
		self.isScanning = isScanning
		self.adapterIsOff = adapterIsOff
		self.options = options
	}
}

/// A tab's chooser opened or changed, or closed (`chooser` nil).
public struct BrowserDeviceChooserEvent: Equatable, Sendable {
	public var tabID: Tab.ID
	public var chooser: BrowserDeviceChooser?

	public init(
		tabID: Tab.ID,
		chooser: BrowserDeviceChooser?
	) {
		self.tabID = tabID
		self.chooser = chooser
	}
}

/// A device a site in a profile may use (DEV-905).
public struct BrowserDeviceGrant: Equatable, Identifiable, Sendable {
	public enum Kind: String, Equatable, Sendable {
		case usb
		case hid
		case serial
		case bluetooth
	}

	public var kind: Kind

	/// `scheme://host[:port]`.
	public var origin: String

	/// The engine's key for the device, for revoking it.
	public var key: String
	public var name: String

	public init(
		kind: Kind,
		origin: String,
		key: String,
		name: String
	) {
		self.kind = kind
		self.origin = origin
		self.key = key
		self.name = name
	}

	public var id: String { "\(kind.rawValue) \(origin) \(key)" }
}

/// Device choosers and the devices sites may use (DEV-905). Unavailable by default: with nobody
/// listening, the engine cancels every request at once, as a headless run needs.
public struct BrowserDeviceChooserClient: Sendable {
	public var events: @MainActor @Sendable () -> AsyncStream<BrowserDeviceChooserEvent>

	/// Chooses the options at these indices of the list at a revision, or cancels with none.
	/// False when the request is gone or its list changed since.
	public var answer: @MainActor @Sendable (Tab.ID, _ token: UInt64, _ revision: UInt64, _ indices: [Int]) -> Bool
	public var scanAgain: @MainActor @Sendable (Tab.ID, _ token: UInt64) -> Bool

	/// An ordinary profile's grants; nil when the engine can't read them.
	public var grants: @MainActor @Sendable (Profile.ID) -> [BrowserDeviceGrant]?
	public var revoke: @MainActor @Sendable (Profile.ID, BrowserDeviceGrant) -> Bool

	public init(
		events: @escaping @MainActor @Sendable () -> AsyncStream<BrowserDeviceChooserEvent> = { .finished },
		answer: @escaping @MainActor @Sendable (Tab.ID, UInt64, UInt64, [Int]) -> Bool = { _, _, _, _ in false },
		scanAgain: @escaping @MainActor @Sendable (Tab.ID, UInt64) -> Bool = { _, _ in false },
		grants: @escaping @MainActor @Sendable (Profile.ID) -> [BrowserDeviceGrant]? = { _ in nil },
		revoke: @escaping @MainActor @Sendable (Profile.ID, BrowserDeviceGrant) -> Bool = { _, _ in false }
	) {
		self.events = events
		self.answer = answer
		self.scanAgain = scanAgain
		self.grants = grants
		self.revoke = revoke
	}
}

extension BrowserDeviceChooserClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var deviceChoosers: BrowserDeviceChooserClient {
		get { self[BrowserDeviceChooserClient.self] }
		set { self[BrowserDeviceChooserClient.self] = newValue }
	}
}
