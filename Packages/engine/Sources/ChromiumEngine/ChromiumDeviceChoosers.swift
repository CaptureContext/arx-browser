import Foundation

// DEV-905 device choosers, exported outside the ABI table (`device_chooser_bridge.h`).

internal typealias ChromiumDeviceChooserHandler = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, Bool) -> Void
internal typealias ChromiumSetDeviceChooserHandlerFunction = @convention(c) (
	ChromiumDeviceChooserHandler?,
	UnsafeMutableRawPointer?
) -> Void
internal typealias ChromiumCopyDeviceChooserFunction = @convention(c) (UInt64, UnsafeMutablePointer<CChar>?, Int) -> Int
internal typealias ChromiumAnswerDeviceChooserFunction = @convention(c) (UInt64, UInt64, UInt64, UnsafePointer<UInt32>?, Int) -> Bool
internal typealias ChromiumRescanDeviceChooserFunction = @convention(c) (UInt64, UInt64) -> Bool
internal typealias ChromiumCopyDeviceGrantsFunction = @convention(c) (UnsafePointer<CChar>?, UnsafeMutablePointer<CChar>?, Int) -> Int
internal typealias ChromiumRevokeDeviceGrantFunction = @convention(c) (
	UnsafePointer<CChar>?,
	UnsafePointer<CChar>?,
	UnsafePointer<CChar>?,
	UnsafePointer<CChar>?
) -> Bool

/// The device choosers' exports, all present or none.
internal struct ChromiumDeviceChooserFunctions {
	internal var setHandler: ChromiumSetDeviceChooserHandlerFunction
	internal var copy: ChromiumCopyDeviceChooserFunction
	internal var answer: ChromiumAnswerDeviceChooserFunction
	internal var rescan: ChromiumRescanDeviceChooserFunction
	internal var copyGrants: ChromiumCopyDeviceGrantsFunction
	internal var revokeGrant: ChromiumRevokeDeviceGrantFunction

	internal init(
		setHandler: ChromiumSetDeviceChooserHandlerFunction,
		copy: ChromiumCopyDeviceChooserFunction,
		answer: ChromiumAnswerDeviceChooserFunction,
		rescan: ChromiumRescanDeviceChooserFunction,
		copyGrants: ChromiumCopyDeviceGrantsFunction,
		revokeGrant: ChromiumRevokeDeviceGrantFunction
	) {
		self.setHandler = setHandler
		self.copy = copy
		self.answer = answer
		self.rescan = rescan
		self.copyGrants = copyGrants
		self.revokeGrant = revokeGrant
	}

	internal static func load(_ handle: UnsafeMutableRawPointer) -> Self? {
		guard
			let setHandler = dlsym(handle, "ArxEngineSetDeviceChooserHandler"),
			let copy = dlsym(handle, "ArxEngineCopyDeviceChooser"),
			let answer = dlsym(handle, "ArxEngineAnswerDeviceChooser"),
			let rescan = dlsym(handle, "ArxEngineRescanDeviceChooser"),
			let copyGrants = dlsym(handle, "ArxEngineCopyDeviceGrants"),
			let revokeGrant = dlsym(handle, "ArxEngineRevokeDeviceGrant")
		else { return nil }

		return .init(
			setHandler: unsafeBitCast(setHandler, to: ChromiumSetDeviceChooserHandlerFunction.self),
			copy: unsafeBitCast(copy, to: ChromiumCopyDeviceChooserFunction.self),
			answer: unsafeBitCast(answer, to: ChromiumAnswerDeviceChooserFunction.self),
			rescan: unsafeBitCast(rescan, to: ChromiumRescanDeviceChooserFunction.self),
			copyGrants: unsafeBitCast(copyGrants, to: ChromiumCopyDeviceGrantsFunction.self),
			revokeGrant: unsafeBitCast(revokeGrant, to: ChromiumRevokeDeviceGrantFunction.self)
		)
	}
}

/// A page's open device chooser, as the engine lists it.
public struct ChromiumDeviceChooser: Decodable, Equatable, Sendable {
	public struct Option: Decodable, Equatable, Sendable {
		public var name: String
		public var connected: Bool
		public var paired: Bool

		/// -1 unknown, otherwise 0-4 bars (Bluetooth).
		public var signal: Int

		public init(
			name: String,
			connected: Bool = false,
			paired: Bool = false,
			signal: Int = -1
		) {
			self.name = name
			self.connected = connected
			self.paired = paired
			self.signal = signal
		}
	}

	public var token: UInt64

	/// The list's changes; an answer must name the list it chose from.
	public var revision: UInt64
	public var title: String
	public var multiple: Bool

	/// Bluetooth can scan again.
	public var rescan: Bool
	public var scanning: Bool
	public var adapterOff: Bool
	public var options: [Option]

	public init(
		token: UInt64,
		revision: UInt64 = 0,
		title: String,
		multiple: Bool = false,
		rescan: Bool = false,
		scanning: Bool = false,
		adapterOff: Bool = false,
		options: [Option] = []
	) {
		self.token = token
		self.revision = revision
		self.title = title
		self.multiple = multiple
		self.rescan = rescan
		self.scanning = scanning
		self.adapterOff = adapterOff
		self.options = options
	}

	private enum CodingKeys: String, CodingKey {
		case token, revision, title, multiple, rescan, scanning, adapterOff, options
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		guard let token = UInt64(try values.decode(String.self, forKey: .token))
		else { throw DecodingError.dataCorruptedError(forKey: .token, in: values, debugDescription: "token") }
		self.token = token

		// Bridges before revisions omit it; 0 means the chooser has none.
		self.revision = (try? values.decode(String.self, forKey: .revision)).flatMap(UInt64.init) ?? 0
		self.title = try values.decode(String.self, forKey: .title)
		self.multiple = try values.decode(Bool.self, forKey: .multiple)
		self.rescan = try values.decode(Bool.self, forKey: .rescan)
		self.scanning = try values.decode(Bool.self, forKey: .scanning)
		self.adapterOff = try values.decode(Bool.self, forKey: .adapterOff)
		self.options = try values.decode([Option].self, forKey: .options)
	}
}

/// A device a site in a profile may use.
public struct ChromiumDeviceGrant: Codable, Equatable, Sendable {
	/// `usb`, `hid`, `serial` or `bluetooth`.
	public var kind: String
	public var origin: String
	public var key: String
	public var name: String

	public init(
		kind: String,
		origin: String,
		key: String,
		name: String
	) {
		self.kind = kind
		self.origin = origin
		self.key = key
		self.name = name
	}
}

@MainActor
private var deviceChooserHandlers: [ObjectIdentifier: (ChromiumPage, UInt64, Bool) -> Void] = [:]

extension ChromiumRuntime {
	public var supportsDeviceChoosers: Bool { optionalExports.deviceChoosers != nil }

	/// Hears each page's chooser open, change and close (`false`). Nil stops, and the engine
	/// then cancels every chooser at once, as it does before anything observes.
	public func observeDeviceChoosers(_ handler: ((ChromiumPage, UInt64, Bool) -> Void)?) {
		guard let functions = optionalExports.deviceChoosers else { return }
		let key = ObjectIdentifier(self)
		deviceChooserHandlers[key] = handler
		guard handler != nil else {
			functions.setHandler(nil, nil)
			return
		}

		functions.setHandler(
			{ context, page, token, isOpen in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					guard
						let owner = runtime.pages[page],
						let handler = deviceChooserHandlers[ObjectIdentifier(runtime)]
					else { return }

					handler(owner, token, isOpen)
				}
			},
			Unmanaged.passUnretained(self).toOpaque()
		)
	}

	/// The page's open chooser, or nil.
	public func deviceChooser(on page: ChromiumPage) -> ChromiumDeviceChooser? {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.deviceChoosers,
			let json = Self.copyJSON({ functions.copy(page.identifier, $0, $1) })
		else { return nil }

		return ChromiumReply.decode(ChromiumDeviceChooser.self, from: json)
	}

	/// Chooses the options at `indices` of the list at `revision`, or cancels with none. False
	/// for a chooser that's gone, or a list that changed since.
	@discardableResult
	public func answerDeviceChooser(
		on page: ChromiumPage,
		token: UInt64,
		revision: UInt64,
		indices: [Int]
	) -> Bool {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.deviceChoosers,
			indices.allSatisfy({ $0 >= 0 && $0 <= Int(UInt32.max) })
		else { return false }

		let values = indices.map { UInt32($0) }
		return values.withUnsafeBufferPointer { buffer in
			functions.answer(page.identifier, token, revision, buffer.baseAddress, buffer.count)
		}
	}

	@discardableResult
	public func rescanDeviceChooser(
		on page: ChromiumPage,
		token: UInt64
	) -> Bool {
		guard
			state == .running,
			pages[page.identifier] === page,
			let functions = optionalExports.deviceChoosers
		else { return false }

		return functions.rescan(page.identifier, token)
	}

	/// The devices sites in an ordinary profile (nil for the legacy one) may use. Nil when the
	/// profile isn't loaded or the engine can't tell.
	public func deviceGrants(profile: UUID?) -> [ChromiumDeviceGrant]? {
		guard state == .running, let functions = optionalExports.deviceChoosers
		else { return nil }

		let key = profile?.uuidString.lowercased() ?? ""
		let json = key.withCString { key in Self.copyJSON({ functions.copyGrants(key, $0, $1) }) }
		guard let json else { return nil }
		return ChromiumReply.decode([ChromiumDeviceGrant].self, from: json)
	}

	@discardableResult
	public func revokeDeviceGrant(
		_ grant: ChromiumDeviceGrant,
		profile: UUID?
	) -> Bool {
		guard state == .running, let functions = optionalExports.deviceChoosers
		else { return false }

		let key = profile?.uuidString.lowercased() ?? ""
		return key.withCString { key in
			grant.kind.withCString { kind in
				grant.origin.withCString { origin in
					grant.key.withCString { grantKey in
						functions.revokeGrant(key, kind, origin, grantKey)
					}
				}
			}
		}
	}

	/// Reads a buffer-copying export: asks for the length, then copies. Nil for none.
	private static func copyJSON(_ copy: (UnsafeMutablePointer<CChar>?, Int) -> Int) -> Data? {
		let length = copy(nil, 0)
		guard length > 0, length < 16 << 20 else { return nil }
		var buffer = [CChar](repeating: 0, count: length + 1)
		let copied = buffer.withUnsafeMutableBufferPointer { copy($0.baseAddress, $0.count) }
		guard copied == length else { return nil }
		return Data(buffer.prefix(length).map { UInt8(bitPattern: $0) })
	}
}
