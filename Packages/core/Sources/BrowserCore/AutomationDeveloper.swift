import Foundation

/// The developer tier's limits and the shape every developer request and result shares (DEV-668).
public enum AutomationDeveloper {
	public static let maximumScriptBytes: Int = 65_536
	public static let maximumResultBytes: Int = 262_144
	public static let defaultResultBytes: Int = 65_536
	public static let minimumResultBytes: Int = 1_024
	public static let maximumTimeoutMilliseconds: Int = 30_000
	public static let defaultTimeoutMilliseconds: Int = 10_000
	public static let maximumLogEntries: Int = 200
	public static let defaultLogEntries: Int = 50
	public static let maximumMessageBytes: Int = 2_048
	public static let maximumURLBytes: Int = 2_048

	/// Each body in a `requests` or `har` read is cut here; 0 leaves bodies out (DEV-924).
	public static let maximumDetailBodyBytes: Int = 32_768
	public static let defaultDetailBodyBytes: Int = 4_096

	/// The engine keeps each body up to this size; Arx redacts the whole of it before cutting.
	public static let maximumKeptBodyBytes: Int = 1_048_576

	internal static func isRevision(_ value: String) -> Bool {
		value.utf8.count == 64 && value.allSatisfy(\.isHexDigit)
	}
}

/// Runs an agent's script in a tab's developer world: an isolated world of the
/// main frame that shares the DOM but not the page's JavaScript, where cookies,
/// password, card and one-time-code values and stored credentials read as
/// nothing. The script is the body of an async function; its return value is
/// awaited and serialized with JSON.stringify.
public struct AutomationScriptRequest: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var targetID: UUID
	public var expectedRevision: String
	public var script: String
	public var maximumResultBytes: Int
	public var timeoutMilliseconds: Int

	public init(
		operationID: UUID,
		targetID: UUID,
		expectedRevision: String,
		script: String,
		maximumResultBytes: Int = AutomationDeveloper.defaultResultBytes,
		timeoutMilliseconds: Int = AutomationDeveloper.defaultTimeoutMilliseconds
	) {
		self.operationID = operationID
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.script = script
		self.maximumResultBytes = maximumResultBytes
		self.timeoutMilliseconds = timeoutMilliseconds
	}

	public func validate() throws {
		guard
			AutomationDeveloper.isRevision(expectedRevision),
			!script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			script.utf8.count <= AutomationDeveloper.maximumScriptBytes,
			!script.contains("\0"),
			(AutomationDeveloper.minimumResultBytes...AutomationDeveloper.maximumResultBytes)
				.contains(maximumResultBytes),
			(100...AutomationDeveloper.maximumTimeoutMilliseconds).contains(timeoutMilliseconds)
		else { throw AutomationFailure.invalidRequest }
	}
}

/// What a script produced. Everything in it is untrusted page data.
public struct AutomationScriptResult: Codable, Equatable, Sendable {
	public enum Outcome: String, Codable, Sendable {
		/// `value` is the JSON text of the returned value.
		case value

		/// The script returned nothing.
		case undefined

		/// JSON.stringify couldn't serialize the value; `detail` says why.
		case unserializable

		/// The script threw or its promise rejected.
		case exception

		/// The script didn't compile.
		case syntaxError
	}

	public struct ScriptError: Codable, Equatable, Sendable {
		public var name: String
		public var message: String

		/// The script's own line, from 1, for a syntax error.
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

	public var operationID: UUID
	public var targetID: UUID
	public var outcome: Outcome
	public var value: String?
	public var detail: String?
	public var error: ScriptError?

	public init(
		operationID: UUID,
		targetID: UUID,
		outcome: Outcome,
		value: String? = nil,
		detail: String? = nil,
		error: ScriptError? = nil
	) {
		self.operationID = operationID
		self.targetID = targetID
		self.outcome = outcome
		self.value = value
		self.detail = detail
		self.error = error
	}

	public func validate() throws {
		let hasError = outcome == .exception || outcome == .syntaxError
		guard
			(outcome == .value) == (value != nil),
			(value?.utf8.count ?? 0) <= AutomationDeveloper.maximumResultBytes,
			outcome == .unserializable || detail == nil,
			(detail?.utf8.count ?? 0) <= 512,
			hasError == (error != nil),
			(error?.name.utf8.count ?? 0) <= 128,
			(error?.message.utf8.count ?? 0) <= AutomationDeveloper.maximumMessageBytes
		else { throw AutomationFailure.limitExceeded }
	}
}

/// Starts, stops or reads a tab's console or network log. Arx keeps at most
/// 500 entries of each per tab, outside the app's state; a read returns the
/// entries after a sequence number.
public struct AutomationLogRequest: Codable, Equatable, Sendable {
	public enum Action: String, Codable, CaseIterable, Sendable {
		case start
		case stop
		case console
		case network

		/// Requests with their headers and bodies (DEV-924). Needs `start` with `details`.
		case requests

		/// The same as a HAR 1.2 log.
		case har
	}

	public var action: Action
	public var targetID: UUID
	public var expectedRevision: String?

	/// For reads: entries after this sequence number; 0 reads from the oldest kept.
	public var after: UInt64
	public var limit: Int

	/// For `start`: also keep request and response headers and bodies (DEV-924).
	public var details: Bool?

	/// For `requests` and `har`: each body is cut at this many bytes; 0 leaves bodies out.
	public var bodyBytes: Int?

	public init(
		action: Action,
		targetID: UUID,
		expectedRevision: String? = nil,
		after: UInt64 = 0,
		limit: Int = AutomationDeveloper.defaultLogEntries,
		details: Bool? = nil,
		bodyBytes: Int? = nil
	) {
		self.action = action
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.after = after
		self.limit = limit
		self.details = details
		self.bodyBytes = bodyBytes
	}

	public var isRead: Bool { [.console, .network, .requests, .har].contains(action) }

	/// Headers, bodies and HAR need the network details grant on top of devtools.
	public var needsNetworkDetails: Bool {
		details == true || action == .requests || action == .har
	}

	public func validate() throws {
		guard
			expectedRevision.map(AutomationDeveloper.isRevision) ?? true,
			(1...AutomationDeveloper.maximumLogEntries).contains(limit),
			isRead || after == 0,
			after < UInt64(Int32.max),
			details == nil || action == .start,
			bodyBytes == nil || action == .requests || action == .har,
			bodyBytes.map({ (0...AutomationDeveloper.maximumDetailBodyBytes).contains($0) }) ?? true
		else { throw AutomationFailure.invalidRequest }
	}
}

/// One console message. `message` and `source` are untrusted page data.
public struct AutomationConsoleEntry: Codable, Equatable, Sendable {
	public enum Level: String, Codable, Sendable {
		case verbose
		case info
		case warning
		case error
	}

	public var sequence: UInt64
	public var level: Level
	public var message: String

	/// The script's URL, without user info, fragment or sensitive query values.
	public var source: String?
	public var line: Int?
	public var mainFrame: Bool

	/// Milliseconds since 1970.
	public var time: Double

	public init(
		sequence: UInt64,
		level: Level,
		message: String,
		source: String? = nil,
		line: Int? = nil,
		mainFrame: Bool,
		time: Double
	) {
		self.sequence = sequence
		self.level = level
		self.message = message
		self.source = source
		self.line = line
		self.mainFrame = mainFrame
		self.time = time
	}

	public var isValid: Bool {
		sequence > 0
		&& message.utf8.count <= AutomationDeveloper.maximumMessageBytes
		&& (source?.utf8.count ?? 0) <= AutomationDeveloper.maximumURLBytes
		&& time.isFinite
	}
}

/// One finished request: never headers, cookies or bodies.
public struct AutomationNetworkEntry: Codable, Equatable, Sendable {
	public var sequence: UInt64
	public var method: String

	/// Without user info or fragment; values of credential-like query keys read `redacted`.
	public var url: String
	public var status: Int?

	/// The fetch destination (`document`, `script`, `image`, `empty` for fetch and XHR…).
	public var type: String
	public var mimeType: String?
	public var cached: Bool?
	public var bytes: Double?

	/// Chromium's network error, such as `ERR_NAME_NOT_RESOLVED`.
	public var error: String?
	public var mainFrame: Bool
	public var time: Double

	public init(
		sequence: UInt64,
		method: String,
		url: String,
		status: Int? = nil,
		type: String,
		mimeType: String? = nil,
		cached: Bool? = nil,
		bytes: Double? = nil,
		error: String? = nil,
		mainFrame: Bool,
		time: Double
	) {
		self.sequence = sequence
		self.method = method
		self.url = url
		self.status = status
		self.type = type
		self.mimeType = mimeType
		self.cached = cached
		self.bytes = bytes
		self.error = error
		self.mainFrame = mainFrame
		self.time = time
	}

	public var isValid: Bool {
		sequence > 0
		&& method.utf8.count <= 16
		&& url.utf8.count <= AutomationDeveloper.maximumURLBytes
		&& type.utf8.count <= 32
		&& (mimeType?.utf8.count ?? 0) <= 128
		&& (error?.utf8.count ?? 0) <= 64
		&& time.isFinite
		&& (bytes.map { $0.isFinite && $0 >= 0 } ?? true)
	}
}

public struct AutomationLogResult: Codable, Equatable, Sendable {
	public var action: AutomationLogRequest.Action
	public var targetID: UUID

	/// Whether Arx is keeping this tab's logs now.
	public var capturing: Bool
	public var console: [AutomationConsoleEntry]
	public var network: [AutomationNetworkEntry]

	/// For `requests`: the requests with headers and bodies (DEV-924).
	public var requests: [AutomationRequestDetail]

	/// For `har`: a HAR 1.2 log of the same requests, as JSON text.
	public var har: String?

	/// Pass as `after` to read the entries that follow.
	public var next: UInt64

	/// Entries after `after` that were no longer kept.
	public var dropped: UInt64

	public init(
		action: AutomationLogRequest.Action,
		targetID: UUID,
		capturing: Bool,
		console: [AutomationConsoleEntry] = [],
		network: [AutomationNetworkEntry] = [],
		requests: [AutomationRequestDetail] = [],
		har: String? = nil,
		next: UInt64 = 0,
		dropped: UInt64 = 0
	) {
		self.action = action
		self.targetID = targetID
		self.capturing = capturing
		self.console = console
		self.network = network
		self.requests = requests
		self.har = har
		self.next = next
		self.dropped = dropped
	}

	public func validate() throws {
		let count = console.count + network.count + requests.count
		guard
			count <= AutomationDeveloper.maximumLogEntries,
			action == .console || console.isEmpty,
			action == .network || network.isEmpty,
			action == .requests || requests.isEmpty,
			action == .har || har == nil,
			console.allSatisfy(\.isValid),
			network.allSatisfy(\.isValid)
		else { throw AutomationFailure.limitExceeded }
	}
}
