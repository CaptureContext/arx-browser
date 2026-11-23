import Darwin
import Foundation

// DEV-927 casting, exported outside the ABI table (`Native/cast_bridge.h`).

internal typealias ChromiumCastPickerHandler = @convention(c) (UnsafeMutableRawPointer?, UInt64, UnsafePointer<CChar>?) -> Void
internal typealias ChromiumSetCastPickerHandlerFunction = @convention(c) (
	ChromiumCastPickerHandler?,
	UnsafeMutableRawPointer?,
	UnsafePointer<CChar>?
) -> Void
internal typealias ChromiumShowCastPickerFunction = @convention(c) (UInt64) -> Bool
internal typealias ChromiumChooseCastDeviceFunction = @convention(c) (UInt64, UnsafePointer<CChar>?, Int32) -> Bool
internal typealias ChromiumStopCastingFunction = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Bool
internal typealias ChromiumCloseCastPickerFunction = @convention(c) (UInt64) -> Void

/// The Cast picker's exports, all present or none.
internal struct ChromiumCastFunctions {
	internal var setHandler: ChromiumSetCastPickerHandlerFunction
	internal var show: ChromiumShowCastPickerFunction
	internal var choose: ChromiumChooseCastDeviceFunction
	internal var stop: ChromiumStopCastingFunction
	internal var close: ChromiumCloseCastPickerFunction

	internal init(
		setHandler: ChromiumSetCastPickerHandlerFunction,
		show: ChromiumShowCastPickerFunction,
		choose: ChromiumChooseCastDeviceFunction,
		stop: ChromiumStopCastingFunction,
		close: ChromiumCloseCastPickerFunction
	) {
		self.setHandler = setHandler
		self.show = show
		self.choose = choose
		self.stop = stop
		self.close = close
	}

	internal static func load(_ handle: UnsafeMutableRawPointer) -> Self? {
		guard
			let setHandler = dlsym(handle, "ArxEngineSetCastPickerHandler"),
			let show = dlsym(handle, "ArxEngineShowCastPicker"),
			let choose = dlsym(handle, "ArxEngineChooseCastDevice"),
			let stop = dlsym(handle, "ArxEngineStopCasting"),
			let close = dlsym(handle, "ArxEngineCloseCastPicker")
		else { return nil }

		return .init(
			setHandler: unsafeBitCast(setHandler, to: ChromiumSetCastPickerHandlerFunction.self),
			show: unsafeBitCast(show, to: ChromiumShowCastPickerFunction.self),
			choose: unsafeBitCast(choose, to: ChromiumChooseCastDeviceFunction.self),
			stop: unsafeBitCast(stop, to: ChromiumStopCastingFunction.self),
			close: unsafeBitCast(close, to: ChromiumCloseCastPickerFunction.self)
		)
	}
}

/// A page's open Cast picker: the devices Chrome's Media Router found, as the engine lists them.
public struct ChromiumCastPicker: Decodable, Equatable, Sendable {
	public struct Device: Decodable, Equatable, Sendable {
		public var id: String
		public var name: String

		/// `available`, `connecting`, `connected`, `disconnecting` or `unavailable`.
		public var state: String

		/// `cast`, `audio`, `audioGroup`, `display` or `generic`.
		public var icon: String

		/// 1 the site's presentation, 2 the tab.
		public var modes: [Int]

		/// What the device is casting, as the route describes it.
		public var status: String?

		/// A problem with the device; choosing it clears the problem.
		public var issue: String?

		/// The route casting to it, to stop.
		public var route: String?

		public init(
			id: String,
			name: String,
			state: String = "available",
			icon: String = "cast",
			modes: [Int] = [],
			status: String? = nil,
			issue: String? = nil,
			route: String? = nil
		) {
			self.id = id
			self.name = name
			self.state = state
			self.icon = icon
			self.modes = modes
			self.status = status
			self.issue = issue
			self.route = route
		}
	}

	/// Chrome's heading: the site that asks, or the tab.
	public var source: String

	/// A site's Cast button opened it.
	public var presentation: Bool

	/// macOS refused Local Network access, so nothing can be found.
	public var permissionRejected: Bool
	public var devices: [Device]

	public init(
		source: String = "",
		presentation: Bool = false,
		permissionRejected: Bool = false,
		devices: [Device] = []
	) {
		self.source = source
		self.presentation = presentation
		self.permissionRejected = permissionRejected
		self.devices = devices
	}
}

@MainActor
private var castPickerHandlers: [ObjectIdentifier: (ChromiumPage, ChromiumCastPicker?) -> Void] = [:]

extension ChromiumRuntime {
	public var supportsCasting: Bool { optionalExports.cast != nil }

	/// Hears each page's Cast picker open and change, and close (nil). `menuTitle` is the page
	/// menu's Cast… item. Nil stops: the engine closes every picker and opens none, and a site's
	/// Cast button fails at once, as before anything observes.
	public func observeCastPickers(
		menuTitle: String,
		_ handler: ((ChromiumPage, ChromiumCastPicker?) -> Void)?
	) {
		guard let functions = optionalExports.cast else { return }
		let key = ObjectIdentifier(self)
		castPickerHandlers[key] = handler
		guard handler != nil else {
			functions.setHandler(nil, nil, nil)
			return
		}

		menuTitle.withCString { title in
			functions.setHandler(
				{ context, page, json in

					// Copied before the main actor hop; the engine owns the bytes only for the call.
					let data = json.map { Data(bytes: $0, count: strlen($0)) }
					MainActor.assumeIsolated {
						guard let context else { return }
						let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
						runtime.castPickerChanged(page, json: data)
					}
				},
				Unmanaged.passUnretained(self).toOpaque(),
				title
			)
		}
	}

	internal func castPickerChanged(
		_ id: UInt64,
		json: Data?
	) {
		guard
			let page = pages[id],
			let handler = castPickerHandlers[ObjectIdentifier(self)]
		else { return }

		guard let json else {
			handler(page, nil)
			return
		}
		guard let picker = ChromiumReply.decode(ChromiumCastPicker.self, from: json) else {
			// Nobody can answer a picker the app can't read.
			optionalExports.cast?.close(id)
			return
		}
		handler(page, picker)
	}

	/// Opens the page's picker, or reports it again. False when the page can't cast now.
	@discardableResult
	public func showCastPicker(on page: ChromiumPage) -> Bool {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.cast
		else { return false }

		return functions.show(page.identifier)
	}

	/// Chooses a device in the page's open picker: mode 1 the site's presentation, 2 the tab,
	/// nil as Chrome picks.
	@discardableResult
	public func chooseCastDevice(
		_ device: String,
		mode: Int?,
		on page: ChromiumPage
	) -> Bool {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.cast
		else { return false }

		return device.withCString { functions.choose(page.identifier, $0, Int32(mode ?? 0)) }
	}

	@discardableResult
	public func stopCasting(
		route: String,
		on page: ChromiumPage
	) -> Bool {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.cast
		else { return false }

		return route.withCString { functions.stop(page.identifier, $0) }
	}

	public func closeCastPicker(on page: ChromiumPage) {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.cast
		else { return }

		functions.close(page.identifier)
	}
}
