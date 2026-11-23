import AppKit
import ChromiumBridge

/// Ephemeral user-menu input. It is never a persisted record or an MCP page read.
public struct ChromiumLinkContext: Equatable, Sendable {
	/// Chromium's `url::kMaxURLChars`. Every link up to it gets the menu, whatever
	/// its scheme, port or credentials (DEV-853).
	public static let maximumURLBytes: Int = 2 * 1024 * 1024

	public let pageID: UInt64
	public let token: UInt64
	public let documentGeneration: UInt64
	public let url: URL
	public let text: String
	public let x: Double
	public let y: Double

	public init(
		pageID: UInt64,
		token: UInt64,
		documentGeneration: UInt64,
		url: URL,
		text: String,
		x: Double,
		y: Double
	) {
		self.pageID = pageID
		self.token = token
		self.documentGeneration = documentGeneration
		self.url = url
		self.text = text
		self.x = x
		self.y = y
	}
}

@MainActor
internal final class ChromiumLinkContexts {
	private let api: ArxEngineAPI
	private var observer: (id: UUID, continuation: AsyncStream<ChromiumLinkContext>.Continuation)?
	private var pending: [UInt64: ChromiumLinkContext] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.link_context_is_current != nil && api.dismiss_link_context != nil
	}

	internal func events() -> AsyncStream<ChromiumLinkContext> {
		stop()
		guard isAvailable else { return .init { $0.finish() } }
		let id = UUID()
		let (stream, continuation) = AsyncStream<ChromiumLinkContext>.makeStream(
			bufferingPolicy: .bufferingNewest(1)
		)
		observer = (id, continuation)
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in
				if self?.observer?.id == id { self?.stop() }
			}
		}
		return stream
	}

	internal func receive(
		page: ChromiumPage,
		native: ArxLinkContext,
		generation: UInt64
	) -> Bool {
		guard
			isAvailable,
			let observer,
			!page.isClosed,
			pending.count < 16,
			native.token > 0,
			native.document_generation > 0,
			native.document_generation == generation,
			native.url_size > 0,
			native.url_size <= ChromiumLinkContext.maximumURLBytes,
			native.text_size <= 4096,
			let urlBytes = native.url,
			let urlString = String(
				bytes: UnsafeBufferPointer(start: urlBytes, count: native.url_size),
				encoding: .utf8
			),
			!urlString.contains("\0"),
			let url = URL(string: urlString, encodingInvalidCharacters: false),
			url.scheme?.isEmpty == false,
			native.x.isFinite,
			native.y.isFinite,
			native.x >= 0,
			native.y >= 0,
			native.x < page.view.bounds.width,
			native.y < page.view.bounds.height,
			api.link_context_is_current?(page.identifier, native.token) == true
		else { return false }
		let text: String
		if native.text_size == 0 {
			text = ""

		} else {
			guard
				let bytes = native.text,
				let value = String(
					bytes: UnsafeBufferPointer(start: bytes, count: native.text_size),
					encoding: .utf8
				),
				!value.contains("\0")
			else { return false }
			text = value
		}
		let context = ChromiumLinkContext(
			pageID: page.identifier,
			token: native.token,
			documentGeneration: generation,
			url: url,
			text: text,
			x: native.x,
			y: native.y
		)
		pending[page.identifier] = context
		switch observer.continuation.yield(context) {
		case .enqueued:
			return true

		case let .dropped(old):
			dismiss(page: old.pageID, token: old.token)
			return true

		case .terminated:
			dismiss(page: page.identifier, token: native.token)
			return false

		@unknown default:
			dismiss(page: page.identifier, token: native.token)
			return false
		}
	}

	internal func isCurrent(_ context: ChromiumLinkContext) -> Bool {
		pending[context.pageID] == context
		&& api.link_context_is_current?(context.pageID, context.token) == true
	}

	internal func dismiss(
		page: UInt64,
		token: UInt64
	) {
		guard pending[page]?.token == token else { return }
		pending[page] = nil
		api.dismiss_link_context?(page, token)
	}

	internal func remove(page: UInt64) {
		if let context = pending[page] { dismiss(page: page, token: context.token) }
	}

	internal func stop() {
		let previous = observer
		observer = nil
		previous?.continuation.finish()
		for (page, context) in pending { api.dismiss_link_context?(page, context.token) }
		pending.removeAll()
	}
}
