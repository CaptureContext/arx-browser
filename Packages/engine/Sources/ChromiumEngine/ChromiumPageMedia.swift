import Foundation

/// `void ArxEngineSetPageMediaBridge(origins, count, script, handler, context)` (DEV-1144): main
/// thread. The page media bridge: `script` runs in the main world of the listed origins'
/// top-level documents at document start, before the page's own code, and its messages reach
/// `handler` with the page and the engine's number for that document. Outside the ABI table,
/// like the other optional exports, so engines built before it load without the bridge.
internal typealias ChromiumPageMediaHandler = @convention(c) (
	UnsafeMutableRawPointer?,
	UInt64,
	UInt64,
	UnsafePointer<CChar>?,
	Int
) -> Void

internal typealias ChromiumSetPageMediaBridgeFunction = @convention(c) (
	UnsafePointer<UnsafePointer<CChar>?>?,
	Int,
	UnsafePointer<CChar>?,
	ChromiumPageMediaHandler?,
	UnsafeMutableRawPointer?
) -> Void

internal let ChromiumSetPageMediaBridgeSymbol: String = "ArxEngineSetPageMediaBridge"

/// `bool ArxEngineSendPageMedia(page, document, message, length)` (DEV-1144): main thread. Sends
/// a message to a bridged document; false when that document is gone or doesn't run the script.
internal typealias ChromiumSendPageMediaFunction = @convention(c) (
	UInt64,
	UInt64,
	UnsafePointer<CChar>?,
	Int
) -> Bool

internal let ChromiumSendPageMediaSymbol: String = "ArxEngineSendPageMedia"

/// `bool ArxEngineSetPageMediaKeepsRunning(page, document, keeps)` (DEV-1151): main thread.
/// While true, the page is kept out of Chromium's freezing, as a page playing sound is; it ends
/// with false, when the document is no longer the page's, or with the page. False for a document
/// that isn't the page's current bridged one.
internal typealias ChromiumSetPageMediaKeepsRunningFunction = @convention(c) (
	UInt64,
	UInt64,
	Bool
) -> Bool

internal let ChromiumSetPageMediaKeepsRunningSymbol: String = "ArxEngineSetPageMediaKeepsRunning"

/// The page media bridge's exports: the two of DEV-1144, both or neither, and the freeze lease
/// of DEV-1151, which engines built between them lack.
internal struct ChromiumPageMediaFunctions {
	internal var setBridge: ChromiumSetPageMediaBridgeFunction
	internal var send: ChromiumSendPageMediaFunction
	internal var keepRunning: ChromiumSetPageMediaKeepsRunningFunction?

	internal static func load(_ handle: UnsafeMutableRawPointer) -> Self? {
		guard
			let setBridge = dlsym(handle, ChromiumSetPageMediaBridgeSymbol),
			let send = dlsym(handle, ChromiumSendPageMediaSymbol)
		else { return nil }

		return .init(
			setBridge: unsafeBitCast(setBridge, to: ChromiumSetPageMediaBridgeFunction.self),
			send: unsafeBitCast(send, to: ChromiumSendPageMediaFunction.self),
			keepRunning: dlsym(handle, ChromiumSetPageMediaKeepsRunningSymbol).map {
				unsafeBitCast($0, to: ChromiumSetPageMediaKeepsRunningFunction.self)
			}
		)
	}
}

/// A message a bridged document sent (DEV-1144).
public struct ChromiumPageMediaMessage: Sendable {
	/// The engine's number for the document, never reused while the engine runs. Replies go to
	/// this document only.
	public var document: UInt64
	public var text: String

	public init(
		document: UInt64,
		text: String
	) {
		self.document = document
		self.text = text
	}
}

/// Each runtime's page media handler. One runtime per process; keyed anyway, so a test runtime
/// never hears another's pages.
@MainActor
private var pageMediaHandlers: [ObjectIdentifier: (ChromiumPage, ChromiumPageMediaMessage) -> Void] = [:]

extension ChromiumRuntime {
	/// The most origins and the longest script the engine takes, as `page_media_bridge.mm` bounds them.
	public static let maximumPageMediaOrigins: Int = 64
	public static let maximumPageMediaScriptBytes: Int = 1024 * 1024

	/// The longest message either side passes on.
	public static let maximumPageMediaMessageBytes: Int = 4 * 1024 * 1024

	/// Whether this engine has the page media bridge (DEV-1144).
	public var supportsPageMedia: Bool {
		optionalExports.pageMedia != nil
	}

	/// Runs `script` in the main world of `origins`' top-level documents from their next
	/// navigation, and hands their messages to `handler`. Nil, or no origins, turns the bridge
	/// off for the next documents. False when this engine lacks the bridge or the input is
	/// larger than it takes.
	@discardableResult
	public func setPageMediaBridge(
		origins: [String],
		script: String,
		handler: ((ChromiumPage, ChromiumPageMediaMessage) -> Void)?
	) -> Bool {
		guard let functions = optionalExports.pageMedia
		else { return false }

		let key = ObjectIdentifier(self)
		guard
			let handler,
			!origins.isEmpty,
			origins.count <= Self.maximumPageMediaOrigins,
			script.utf8.count <= Self.maximumPageMediaScriptBytes
		else {
			pageMediaHandlers[key] = nil
			functions.setBridge(nil, 0, nil, nil, nil)
			return handler == nil || origins.isEmpty
		}

		pageMediaHandlers[key] = handler
		let strings = origins.map { strdup($0) }
		defer { strings.forEach { free($0) } }
		let pointers = strings.map { UnsafePointer<CChar>($0) }
		pointers.withUnsafeBufferPointer { origins in
			script.withCString { script in
				functions.setBridge(
					origins.baseAddress,
					origins.count,
					script,
					{ context, page, document, message, length in
						MainActor.assumeIsolated {
							guard
								let context,
								let message,
								document != 0
							else { return }

							let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
							guard
								let owner = runtime.pages[page],
								let handler = pageMediaHandlers[ObjectIdentifier(runtime)]
							else { return }

							let bytes = UnsafeRawBufferPointer(start: message, count: length)
							handler(owner, .init(document: document, text: String(decoding: bytes, as: UTF8.self)))
						}
					},
					Unmanaged.passUnretained(self).toOpaque()
				)
			}
		}
		return true
	}

	/// Sends `text` to `document` of `page`. False when that document is gone, the page isn't
	/// this runtime's, the engine lacks the bridge or the text is too long.
	public func sendPageMedia(
		_ text: String,
		to document: UInt64,
		on page: ChromiumPage
	) -> Bool {
		guard
			let send = optionalExports.pageMedia?.send,
			pages[page.identifier] === page,
			text.utf8.count <= Self.maximumPageMediaMessageBytes
		else { return false }

		var text = text
		return text.withUTF8 { bytes in
			bytes.withMemoryRebound(to: CChar.self) { characters in
				send(page.identifier, document, characters.baseAddress, characters.count)
			}
		}
	}

	/// Keeps `page` out of Chromium's freezing while `document`'s media plays outside Chromium,
	/// or ends that (DEV-1151). False when the engine lacks the lease, the page isn't this
	/// runtime's, or `document` isn't the page's current bridged document.
	@discardableResult
	public func setPageMediaKeepsRunning(
		_ keeps: Bool,
		document: UInt64,
		on page: ChromiumPage
	) -> Bool {
		guard
			let keepRunning = optionalExports.pageMedia?.keepRunning,
			pages[page.identifier] === page
		else { return false }

		return keepRunning(page.identifier, document, keeps)
	}
}
