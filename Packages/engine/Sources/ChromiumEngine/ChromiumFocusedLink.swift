import ChromiumBridge
import Foundation

/// ABI37. The http(s) link that has keyboard focus in a page's current document, in
/// any of its frames.
public struct ChromiumFocusedLink: Equatable, Sendable {
	/// The page's document revision when native read the link.
	public var documentRevision: UInt64
	public var url: URL

	public init(
		documentRevision: UInt64,
		url: URL
	) {
		self.documentRevision = documentRevision
		self.url = url
	}
}

/// One focused-link read per request. Native always replies once, within two seconds.
@MainActor
internal final class ChromiumFocusedLinks {
	private struct Request {
		internal var page: UInt64
		internal var continuation: CheckedContinuation<ChromiumFocusedLink?, Never>

		internal init(
			page: UInt64,
			continuation: CheckedContinuation<ChromiumFocusedLink?, Never>
		) {
			self.page = page
			self.continuation = continuation
		}
	}

	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: Request] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.focused_link != nil
	}

	internal func read(page: UInt64) async -> ChromiumFocusedLink? {
		guard let focusedLink = api.focused_link else { return nil }

		let id = nextRequest
		nextRequest += 1
		return await withCheckedContinuation { continuation in
			requests[id] = .init(page: page, continuation: continuation)
			focusedLink(page, id)
		}
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64,
		documentRevision: UInt64,
		url: UnsafePointer<CChar>?,
		count: Int
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		request.continuation.resume(returning: Self.link(
			page: page,
			expectedPage: request.page,
			documentRevision: documentRevision,
			url: url,
			count: count
		))
	}

	internal func stop() {
		let pending = requests.values
		requests.removeAll()
		for request in pending {
			request.continuation.resume(returning: nil)
		}
	}

	private static func link(
		page: UInt64,
		expectedPage: UInt64,
		documentRevision: UInt64,
		url: UnsafePointer<CChar>?,
		count: Int
	) -> ChromiumFocusedLink? {
		guard
			page == expectedPage,
			documentRevision != 0,
			let url,
			(1...8_192).contains(count)
		else { return nil }

		let bytes = UnsafeRawBufferPointer(start: url, count: count)
		guard
			let text = String(bytes: bytes, encoding: .utf8),
			let link = URL(string: text),
			["http", "https"].contains(link.scheme?.lowercased()),
			link.user == nil,
			link.password == nil
		else { return nil }

		return .init(documentRevision: documentRevision, url: link)
	}
}
