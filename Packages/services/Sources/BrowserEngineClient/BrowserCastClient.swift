import BrowserCore
import Foundation
import _Dependencies

/// A tab's Cast picker (DEV-927): the Chromecasts and other cast devices Chrome's Media Router
/// found on the local network. The engine keeps the picker open while the app shows it.
public struct BrowserCastPicker: Equatable, Sendable {
	public struct Device: Equatable, Identifiable, Sendable {
		public enum State: String, Equatable, Sendable {
			case available
			case connecting
			case connected
			case disconnecting
			case unavailable
		}

		public enum Kind: String, Equatable, Sendable {
			/// A Chromecast or a TV with one built in.
			case cast

			/// A speaker.
			case audio

			/// A group of speakers.
			case audioGroup
			case display
			case generic
		}

		public enum Mode: Int, Equatable, Sendable {
			/// What the site itself casts, such as a YouTube video.
			case presentation = 1

			/// The tab, as it shows.
			case tab = 2
		}

		public var id: String
		public var name: String
		public var state: State
		public var kind: Kind
		public var modes: [Mode]

		/// What the device casts now.
		public var status: String?

		/// A problem the device had; choosing the device clears it.
		public var issue: String?

		/// The cast session to stop.
		public var route: String?

		public init(
			id: String,
			name: String,
			state: State = .available,
			kind: Kind = .cast,
			modes: [Mode] = [.tab],
			status: String? = nil,
			issue: String? = nil,
			route: String? = nil
		) {
			self.id = id
			self.name = name
			self.state = state
			self.kind = kind
			self.modes = modes
			self.status = status
			self.issue = issue
			self.route = route
		}

		/// Chrome's choice: the site's own cast when the device takes it, else the tab.
		public var preferredMode: Mode? {
			modes.contains(.presentation) ? .presentation : modes.contains(.tab) ? .tab : nil
		}

		/// Choosing it casts, replaces what it casts, or clears its problem.
		public var canChoose: Bool {
			issue != nil || ((state == .available || state == .connected) && preferredMode != nil)
		}
	}

	/// The engine's heading: the site that asks, or the tab.
	public var source: String

	/// The site's own Cast button opened it.
	public var isSiteRequest: Bool

	/// macOS refused Arx Local Network access, so it finds nothing.
	public var isLocalNetworkDenied: Bool
	public var devices: [Device]

	public init(
		source: String = "",
		isSiteRequest: Bool = false,
		isLocalNetworkDenied: Bool = false,
		devices: [Device] = []
	) {
		self.source = source
		self.isSiteRequest = isSiteRequest
		self.isLocalNetworkDenied = isLocalNetworkDenied
		self.devices = devices
	}
}

/// A tab's picker opened or changed, or closed (`picker` nil).
public struct BrowserCastPickerEvent: Equatable, Sendable {
	public var tabID: Tab.ID
	public var picker: BrowserCastPicker?

	public init(
		tabID: Tab.ID,
		picker: BrowserCastPicker?
	) {
		self.tabID = tabID
		self.picker = picker
	}
}

/// Casting a tab or a site's video to a Chromecast (DEV-927). Unavailable by default: with
/// nobody listening to `events` the engine opens no picker, and a site's Cast button fails at
/// once, as a headless run needs.
public struct BrowserCastClient: Sendable {
	public var isAvailable: @MainActor @Sendable () -> Bool

	/// `menuTitle` is the page menu's Cast… item.
	public var events: @MainActor @Sendable (_ menuTitle: String) -> AsyncStream<BrowserCastPickerEvent>

	/// Opens the tab's picker, or reports it again. False when the tab can't cast.
	public var show: @MainActor @Sendable (Tab.ID) -> Bool

	/// Casts to a device, nil mode choosing as Chrome does, or clears its problem.
	public var choose: @MainActor @Sendable (Tab.ID, _ device: String, BrowserCastPicker.Device.Mode?) -> Bool
	public var stop: @MainActor @Sendable (Tab.ID, _ route: String) -> Bool

	/// Closes the tab's picker. A site's request that chose nothing fails.
	public var close: @MainActor @Sendable (Tab.ID) -> Void

	public init(
		isAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		events: @escaping @MainActor @Sendable (String) -> AsyncStream<BrowserCastPickerEvent> = { _ in .finished },
		show: @escaping @MainActor @Sendable (Tab.ID) -> Bool = { _ in false },
		choose: @escaping @MainActor @Sendable (Tab.ID, String, BrowserCastPicker.Device.Mode?) -> Bool = { _, _, _ in false },
		stop: @escaping @MainActor @Sendable (Tab.ID, String) -> Bool = { _, _ in false },
		close: @escaping @MainActor @Sendable (Tab.ID) -> Void = { _ in }
	) {
		self.isAvailable = isAvailable
		self.events = events
		self.show = show
		self.choose = choose
		self.stop = stop
		self.close = close
	}
}

extension BrowserCastClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var cast: BrowserCastClient {
		get { self[BrowserCastClient.self] }
		set { self[BrowserCastClient.self] = newValue }
	}
}
