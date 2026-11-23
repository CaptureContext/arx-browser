import Foundation

/// `void ArxEngineSetProtectedMediaHandler(handler, context)` (DEV-877): main thread. The handler
/// hears of each page whose frame first asked for Encrypted Media Extensions key systems, with
/// the page's main-frame URL. Arx has no Widevine module, so a protected key system then fails
/// and the app may offer WebKit. Outside the ABI table, like the other optional exports.
internal typealias ChromiumProtectedMediaHandler = @convention(c) (
	UnsafeMutableRawPointer?,
	UInt64,
	UnsafePointer<CChar>?
) -> Void

internal typealias ChromiumSetProtectedMediaHandlerFunction = @convention(c) (
	ChromiumProtectedMediaHandler?,
	UnsafeMutableRawPointer?
) -> Void

internal let ChromiumSetProtectedMediaHandlerSymbol: String = "ArxEngineSetProtectedMediaHandler"

/// `void ArxEngineSetProtectedMediaReasonHandler(handler, context)` (DEV-1211): main thread. The
/// same reports, with why each page is reported. Engines before it have only the handler above.
internal typealias ChromiumProtectedMediaReasonHandler = @convention(c) (
	UnsafeMutableRawPointer?,
	UInt64,
	UnsafePointer<CChar>?,
	Int32
) -> Void

internal typealias ChromiumSetProtectedMediaReasonHandlerFunction = @convention(c) (
	ChromiumProtectedMediaReasonHandler?,
	UnsafeMutableRawPointer?
) -> Void

internal let ChromiumSetProtectedMediaReasonHandlerSymbol: String = "ArxEngineSetProtectedMediaReasonHandler"

/// Why the engine reports a page's protected media (DEV-1211).
public enum ChromiumProtectedMediaReason: Equatable, Sendable {
	/// The page can't play its protected media: a media element wants keys Arx can't give it,
	/// or every protected key system the page asked for was refused. An engine that reports no
	/// reason reports this.
	case playbackFailed

	/// Keys couldn't be created, or access was refused, before any media element wanted keys. A
	/// bot check does this; so does a streaming player that stops before it loads media.
	case keysWithoutMedia

	/// The engine's `ARX_PROTECTED_MEDIA_*` code; an unknown one reads as a failure.
	internal init(code: Int32) {
		self = code == 1 ? .keysWithoutMedia : .playbackFailed
	}
}

/// `bool ArxEngineCopySiteCookies(profile_key, page, url, done, context)` (DEV-877): main thread.
/// Reads the unpartitioned cookies a URL would receive from a page's or an ordinary profile's
/// store, as JSON, so a sign-in comes along when the page moves to WebKit.
internal typealias ChromiumSiteCookiesCallback = @convention(c) (
	UnsafeMutableRawPointer?,
	UnsafePointer<CChar>?,
	Int
) -> Void

internal typealias ChromiumCopySiteCookiesFunction = @convention(c) (
	UnsafePointer<CChar>?,
	UInt64,
	UnsafePointer<CChar>?,
	ChromiumSiteCookiesCallback?,
	UnsafeMutableRawPointer?
) -> Bool

internal let ChromiumCopySiteCookiesSymbol: String = "ArxEngineCopySiteCookies"

/// One cookie a site would receive, read from Chromium's store (DEV-877).
public struct ChromiumSiteCookie: Codable, Equatable, Sendable {
	public var name: String
	public var value: String

	/// A leading dot marks a domain cookie; otherwise it's host-only.
	public var domain: String
	public var path: String

	/// Seconds since 1970; nil for a session cookie.
	public var expires: Double?
	public var secure: Bool
	public var httpOnly: Bool

	/// `none`, `lax`, `strict` or `unspecified`.
	public var sameSite: String

	public init(
		name: String,
		value: String,
		domain: String,
		path: String,
		expires: Double?,
		secure: Bool,
		httpOnly: Bool,
		sameSite: String
	) {
		self.name = name
		self.value = value
		self.domain = domain
		self.path = path
		self.expires = expires
		self.secure = secure
		self.httpOnly = httpOnly
		self.sameSite = sameSite
	}

	/// The engine's JSON array; entries that don't decode are dropped.
	internal static func decode(_ data: Data) -> [Self] {
		struct Lossy: Decodable {
			var cookie: ChromiumSiteCookie?

			init(from decoder: any Decoder) throws {
				// One cookie the app can't read is skipped, not the whole list.
				self.cookie = try? ChromiumSiteCookie(from: decoder)
			}
		}

		let entries = ChromiumReply.decode([Lossy].self, from: data) ?? []
		return entries.compactMap(\.cookie)
	}
}

/// Each runtime's protected media handler. One runtime per process; keyed anyway, so a test
/// runtime never hears another's pages.
@MainActor
private var protectedMediaHandlers: [ObjectIdentifier: (ChromiumPage, URL, ChromiumProtectedMediaReason) -> Void] = [:]

/// A cookie read in flight: resumed once by the engine's callback.
private final class SiteCookiesReply: @unchecked Sendable {
	internal let continuation: CheckedContinuation<[ChromiumSiteCookie], Never>

	internal init(_ continuation: CheckedContinuation<[ChromiumSiteCookie], Never>) {
		self.continuation = continuation
	}
}

extension ChromiumRuntime {
	/// Whether this engine reports protected media requests (DEV-877).
	public var supportsProtectedMediaRequests: Bool {
		optionalExports.setProtectedMediaReasonHandler != nil || optionalExports.setProtectedMediaHandler != nil
	}

	/// Whether this engine can read a site's cookies for a WebKit page (DEV-877).
	public var supportsSiteCookies: Bool {
		optionalExports.copySiteCookies != nil
	}

	/// Hears each page whose protected media the engine reports, with its main-frame URL and
	/// why. Nil stops. The page is one this runtime owns. An engine without the reason handler
	/// (DEV-1211) reports every page as `.playbackFailed`.
	public func observeProtectedMedia(_ handler: ((ChromiumPage, URL, ChromiumProtectedMediaReason) -> Void)?) {
		let key = ObjectIdentifier(self)
		let context = Unmanaged.passUnretained(self).toOpaque()
		if let setHandler = optionalExports.setProtectedMediaReasonHandler {
			protectedMediaHandlers[key] = handler
			guard handler != nil else {
				setHandler(nil, nil)
				return
			}

			setHandler(
				{ context, page, url, reason in
					MainActor.assumeIsolated {
						ChromiumRuntime.protectedMediaReported(context, page, url, .init(code: reason))
					}
				},
				context
			)
			return
		}

		guard let setHandler = optionalExports.setProtectedMediaHandler
		else { return }

		protectedMediaHandlers[key] = handler
		guard handler != nil else {
			setHandler(nil, nil)
			return
		}

		setHandler(
			{ context, page, url in
				MainActor.assumeIsolated {
					ChromiumRuntime.protectedMediaReported(context, page, url, .playbackFailed)
				}
			},
			context
		)
	}

	/// An engine report: the runtime in `context`, if it owns the page, tells its handler.
	private static func protectedMediaReported(
		_ context: UnsafeMutableRawPointer?,
		_ page: UInt64,
		_ url: UnsafePointer<CChar>?,
		_ reason: ChromiumProtectedMediaReason
	) {
		guard
			let context,
			let url,
			let address = URL(string: String(cString: url))
		else { return }

		let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
		guard
			let owner = runtime.pages[page],
			let handler = protectedMediaHandlers[ObjectIdentifier(runtime)]
		else { return }

		handler(owner, address, reason)
	}

	/// The unpartitioned cookies `url` would receive in `page`'s profile, or in the loaded
	/// ordinary profile `profile` (nil for the legacy profile) when there's no page. Nil when
	/// the engine can't read them now.
	public func siteCookies(
		for url: URL,
		page: ChromiumPage?,
		profile: UUID?
	) async -> [ChromiumSiteCookie]? {
		guard
			state == .running,
			let copy = optionalExports.copySiteCookies
		else { return nil }

		let pageID = page.map { pages[$0.identifier] === $0 ? $0.identifier : 0 } ?? 0
		var started = false
		let cookies = await withCheckedContinuation { (continuation: CheckedContinuation<[ChromiumSiteCookie], Never>) in
			let reply = Unmanaged.passRetained(SiteCookiesReply(continuation))
			started = (profile?.uuidString.lowercased() ?? "").withCString { key in
				url.absoluteString.withCString { address in
					copy(
						key,
						pageID,
						address,
						{ context, json, length in
							guard let context else { return }
							let reply = Unmanaged<SiteCookiesReply>.fromOpaque(context).takeRetainedValue()
							let data = json.map { Data(bytes: $0, count: length) } ?? Data()
							reply.continuation.resume(returning: ChromiumSiteCookie.decode(data))
						},
						reply.toOpaque()
					)
				}
			}
			if !started {
				reply.release()
				continuation.resume(returning: [])
			}
		}
		return started ? cookies : nil
	}
}
