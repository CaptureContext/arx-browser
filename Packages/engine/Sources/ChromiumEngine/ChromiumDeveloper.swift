import ChromiumBridge
import Foundation

/// ABI34. What an agent's script produced in a page's developer world.
public enum ChromiumScriptValue: Equatable, Sendable {
	/// JSON text of the awaited return value. Untrusted page data.
	case json(String)
	case undefined

	/// JSON.stringify couldn't serialize the value.
	case unserializable(String)
}

/// An exception the script threw, or the reason it didn't compile.
public struct ChromiumScriptError: Equatable, Sendable {
	public var name: String
	public var message: String
	public var line: Int?

	public init(
		name: String,
		message: String,
		line: Int? = nil
	) {
		self.name = name
		self.message = message
		self.line = line
	}
}

public enum ChromiumDeveloperFailure: Error, Equatable, Sendable {
	case unavailable

	/// Not an ordinary HTTP(S) document.
	case unsupportedDocument

	/// The page navigated or closed.
	case staleDocument
	case limitExceeded
	case failed

	/// Another script is running on the page.
	case busy
	case invalidRequest
	case timedOut
	case exception(ChromiumScriptError)
	case syntax(ChromiumScriptError)

	internal init(status: ArxDeveloperStatus) {
		self = switch status {
		case ARX_DEVELOPER_UNAVAILABLE: .unavailable
		case ARX_DEVELOPER_UNSUPPORTED: .unsupportedDocument
		case ARX_DEVELOPER_STALE: .staleDocument
		case ARX_DEVELOPER_LIMIT: .limitExceeded
		case ARX_DEVELOPER_BUSY: .busy
		case ARX_DEVELOPER_INVALID: .invalidRequest
		case ARX_DEVELOPER_TIMEOUT: .timedOut
		default: .failed
		}
	}
}

public enum ChromiumDeveloperLogKind: Sendable {
	case console
	case network

	internal var native: ArxDeveloperLogKind {
		switch self {
		case .console: ARX_DEVELOPER_LOG_CONSOLE
		case .network: ARX_DEVELOPER_LOG_NETWORK
		}
	}
}

/// One read of a page's console or network log, as the native bridge keeps it.
public struct ChromiumDeveloperLog: Decodable, Equatable, Sendable {
	public struct Entry: Decodable, Equatable, Sendable {
		public var sequence: UInt64
		public var time: Double
		public var mainFrame: Bool

		// Console.
		public var level: String?
		public var message: String?
		public var source: String?
		public var line: Int?

		// Network: never headers, cookies or bodies.
		public var method: String?
		public var url: String?
		public var status: Int?
		public var type: String?
		public var mimeType: String?
		public var cached: Bool?
		public var bytes: Double?
		public var error: String?

		public init(
			sequence: UInt64,
			time: Double,
			mainFrame: Bool,
			level: String? = nil,
			message: String? = nil,
			source: String? = nil,
			line: Int? = nil,
			method: String? = nil,
			url: String? = nil,
			status: Int? = nil,
			type: String? = nil,
			mimeType: String? = nil,
			cached: Bool? = nil,
			bytes: Double? = nil,
			error: String? = nil
		) {
			self.sequence = sequence
			self.time = time
			self.mainFrame = mainFrame
			self.level = level
			self.message = message
			self.source = source
			self.line = line
			self.method = method
			self.url = url
			self.status = status
			self.type = type
			self.mimeType = mimeType
			self.cached = cached
			self.bytes = bytes
			self.error = error
		}
	}

	public var capturing: Bool
	public var entries: [Entry]
	public var next: UInt64
	public var dropped: UInt64

	public init(
		capturing: Bool,
		entries: [Entry],
		next: UInt64,
		dropped: UInt64
	) {
		self.capturing = capturing
		self.entries = entries
		self.next = next
		self.dropped = dropped
	}
}

/// Pending developer requests. Each native request replies once.
@MainActor
internal final class ChromiumDevelopers {
	private let api: ArxEngineAPI
	private var nextRequest: UInt64 = 1
	private var requests: [UInt64: Request] = [:]

	internal init(api: ArxEngineAPI) {
		self.api = api
	}

	internal var isAvailable: Bool {
		api.evaluate_script != nil
		&& api.set_developer_log != nil
		&& api.read_developer_log != nil
		&& api.cancel_developer != nil
	}

	/// ABI57 (DEV-996): whether the engine runs the app's translation scripts.
	internal var translationIsAvailable: Bool {
		api.evaluate_translation_script != nil && api.cancel_developer != nil
	}

	/// `translation` runs it in the translation world (ABI57), private pages included.
	internal func evaluate(
		page: UInt64,
		source: String,
		maximumBytes: Int,
		timeoutMilliseconds: Int,
		translation: Bool = false
	) async throws -> ChromiumScriptValue {
		guard
			!source.isEmpty,
			source.utf8.count <= 65_536,
			!source.contains("\0"),
			(1...262_144).contains(maximumBytes),
			(1...30_000).contains(timeoutMilliseconds)
		else { throw ChromiumDeveloperFailure.invalidRequest }

		let body = try await request(page: page) { [api] id in
			guard let evaluate = translation ? api.evaluate_translation_script : api.evaluate_script
			else { return false }

			source.withCString { evaluate(page, id, $0, UInt32(maximumBytes), UInt32(timeoutMilliseconds)) }
			return true
		}
		return try Self.scriptValue(body)
	}

	/// ABI58 (DEV-1009): whether the page's main frame answers within the timeout, apart from
	/// the scripts' queue. Nil when the engine can't ask.
	internal func ping(
		page: UInt64,
		timeoutMilliseconds: Int
	) async -> Bool? {
		guard api.ping_page != nil, (1...30_000).contains(timeoutMilliseconds) else { return nil }
		do {
			_ = try await request(page: page) { [api] id in
				guard let ping = api.ping_page else { return false }
				ping(page, id, UInt32(timeoutMilliseconds))
				return true
			}
			return true
		} catch ChromiumDeveloperFailure.timedOut {
			return false
		} catch {
			return nil
		}
	}

	internal func read(
		page: UInt64,
		kind: ChromiumDeveloperLogKind,
		after: UInt64,
		limit: Int
	) async throws -> ChromiumDeveloperLog {
		guard (1...200).contains(limit)
		else { throw ChromiumDeveloperFailure.invalidRequest }

		let body = try await request(page: page) { [api] id in
			guard let read = api.read_developer_log else { return false }
			read(page, id, kind.native, after, UInt32(limit))
			return true
		}
		guard let log = ChromiumReply.decode(ChromiumDeveloperLog.self, from: body)
		else { throw ChromiumDeveloperFailure.failed }

		return log
	}

	internal func complete(
		_ id: UInt64,
		page: UInt64,
		status: ArxDeveloperStatus,
		json: UnsafePointer<UInt8>?,
		count: Int
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		guard request.page == page
		else { return request.continuation.resume(throwing: ChromiumDeveloperFailure.staleDocument) }

		if status == ARX_DEVELOPER_CANCELLED {
			return request.continuation.resume(throwing: CancellationError())
		}
		let body = json.map { Data(bytes: $0, count: count) } ?? Data()
		switch status {
		case ARX_DEVELOPER_OK:
			request.continuation.resume(returning: body)

		case ARX_DEVELOPER_EXCEPTION, ARX_DEVELOPER_SYNTAX:
			let error = Self.scriptError(body)
			request.continuation.resume(
				throwing: status == ARX_DEVELOPER_SYNTAX
				? ChromiumDeveloperFailure.syntax(error)
				: ChromiumDeveloperFailure.exception(error)
			)

		default:
			request.continuation.resume(throwing: ChromiumDeveloperFailure(status: status))
		}
	}

	internal func remove(page: UInt64) {
		for id in requests.keys.filter({ requests[$0]?.page == page }) {
			cancel(id, failure: ChromiumDeveloperFailure.staleDocument)
		}
	}

	internal func stop() {
		for id in Array(requests.keys) {
			cancel(id, failure: ChromiumDeveloperFailure.unavailable)
		}
	}

	private func request(
		page: UInt64,
		start: @escaping (UInt64) -> Bool
	) async throws -> Data {
		try Task.checkCancellation()
		guard isAvailable, requests.count < 16, nextRequest < UInt64.max
		else { throw ChromiumDeveloperFailure.unavailable }

		let id = nextRequest
		nextRequest += 1
		return try await withTaskCancellationHandler {
			try await withCheckedThrowingContinuation { continuation in
				guard !Task.isCancelled else {
					continuation.resume(throwing: CancellationError())
					return
				}

				requests[id] = .init(page: page, continuation: continuation)
				if !start(id) {
					requests.removeValue(forKey: id)?.continuation.resume(throwing: ChromiumDeveloperFailure.unavailable)
				}
			}
		} onCancel: {
			Task { @MainActor [weak self] in self?.cancel(id) }
		}
	}

	private func cancel(
		_ id: UInt64,
		failure: any Error = CancellationError()
	) {
		guard let request = requests.removeValue(forKey: id)
		else { return }

		api.cancel_developer?(id)
		request.continuation.resume(throwing: failure)
	}

	internal static func scriptValue(_ body: Data) throws -> ChromiumScriptValue {
		struct Native: Decodable {
			var type: String
			var value: String?
			var description: String?
		}
		guard let native = ChromiumReply.decode(Native.self, from: body)
		else { throw ChromiumDeveloperFailure.failed }

		switch native.type {
		case "json":
			guard let value = native.value else { throw ChromiumDeveloperFailure.failed }
			return .json(value)
		case "undefined":
			return .undefined
		case "unserializable":
			return .unserializable(native.description ?? "")
		default:
			throw ChromiumDeveloperFailure.failed
		}
	}

	internal static func scriptError(_ body: Data) -> ChromiumScriptError {
		struct Native: Decodable {
			var name: String?
			var message: String?
			var line: Int?
		}

		// Optional detail: a script error may come without a name, message or line.
		let native = try? JSONDecoder().decode(Native.self, from: body)
		return .init(name: native?.name ?? "Error", message: native?.message ?? "", line: native?.line)
	}

	private struct Request {
		internal let page: UInt64
		internal let continuation: CheckedContinuation<Data, any Error>

		internal init(
			page: UInt64,
			continuation: CheckedContinuation<Data, any Error>
		) {
			self.page = page
			self.continuation = continuation
		}
	}
}
