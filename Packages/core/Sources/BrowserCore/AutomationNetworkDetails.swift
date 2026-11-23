import Foundation

/// One request with its headers and bodies, kept for `browser_logs` `requests` and `har`
/// (DEV-924) while an agent with the network details grant asked for them.
///
/// The engine never hands out credential or cookie headers: Cookie, Set-Cookie, Authorization
/// and any header whose name suggests a credential read `[redacted]`. Arx then replaces the
/// values of credential-like fields in form and JSON bodies (`redactingCredentials()`). URLs
/// lose user info and fragments as in the network log. Everything else is untrusted page data.
public struct AutomationRequestDetail: Codable, Equatable, Sendable {
	public var sequence: UInt64
	public var method: String
	public var url: String

	/// Chromium's resource type: Document, Script, XHR, Fetch, Image…
	public var type: String?
	public var status: Int?
	public var statusText: String?
	public var mimeType: String?
	public var `protocol`: String?
	public var requestHeaders: [String: String]
	public var responseHeaders: [String: String]
	public var requestBody: String?
	public var requestBodyTruncated: Bool?

	/// The page sent a body Chromium didn't keep, or that Arx dropped to stay within its memory.
	public var requestBodyOmitted: Bool?
	public var responseBody: String?

	/// The body is base64, as Chromium gives binary responses.
	public var responseBodyBase64: Bool?
	public var responseBodyTruncated: Bool?
	public var responseBodyOmitted: Bool?

	/// Bytes on the wire.
	public var bytes: Double?

	/// Chromium's network error text, such as `net::ERR_NAME_NOT_RESOLVED`.
	public var error: String?
	public var canceled: Bool?

	/// The request was redirected; the next entry continues it.
	public var redirected: Bool?

	/// The headers were left out to keep the entry within one reply.
	public var headersOmitted: Bool?

	/// Milliseconds since 1970.
	public var time: Double?

	/// Milliseconds from start to finish.
	public var duration: Double?

	public init(
		sequence: UInt64,
		method: String,
		url: String,
		type: String? = nil,
		status: Int? = nil,
		statusText: String? = nil,
		mimeType: String? = nil,
		protocol: String? = nil,
		requestHeaders: [String: String] = [:],
		responseHeaders: [String: String] = [:],
		requestBody: String? = nil,
		requestBodyTruncated: Bool? = nil,
		requestBodyOmitted: Bool? = nil,
		responseBody: String? = nil,
		responseBodyBase64: Bool? = nil,
		responseBodyTruncated: Bool? = nil,
		responseBodyOmitted: Bool? = nil,
		bytes: Double? = nil,
		error: String? = nil,
		canceled: Bool? = nil,
		redirected: Bool? = nil,
		headersOmitted: Bool? = nil,
		time: Double? = nil,
		duration: Double? = nil
	) {
		self.sequence = sequence
		self.method = method
		self.url = url
		self.type = type
		self.status = status
		self.statusText = statusText
		self.mimeType = mimeType
		self.protocol = `protocol`
		self.requestHeaders = requestHeaders
		self.responseHeaders = responseHeaders
		self.requestBody = requestBody
		self.requestBodyTruncated = requestBodyTruncated
		self.requestBodyOmitted = requestBodyOmitted
		self.responseBody = responseBody
		self.responseBodyBase64 = responseBodyBase64
		self.responseBodyTruncated = responseBodyTruncated
		self.responseBodyOmitted = responseBodyOmitted
		self.bytes = bytes
		self.error = error
		self.canceled = canceled
		self.redirected = redirected
		self.headersOmitted = headersOmitted
		self.time = time
		self.duration = duration
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			sequence: try values.decode(UInt64.self, forKey: .sequence),
			method: try values.decode(String.self, forKey: .method),
			url: try values.decode(String.self, forKey: .url),
			type: try values.decodeIfPresent(String.self, forKey: .type),
			status: try values.decodeIfPresent(Int.self, forKey: .status),
			statusText: try values.decodeIfPresent(String.self, forKey: .statusText),
			mimeType: try values.decodeIfPresent(String.self, forKey: .mimeType),
			protocol: try values.decodeIfPresent(String.self, forKey: .protocol),
			requestHeaders: try values.decodeIfPresent([String: String].self, forKey: .requestHeaders) ?? [:],
			responseHeaders: try values.decodeIfPresent([String: String].self, forKey: .responseHeaders) ?? [:],
			requestBody: try values.decodeIfPresent(String.self, forKey: .requestBody),
			requestBodyTruncated: try values.decodeIfPresent(Bool.self, forKey: .requestBodyTruncated),
			requestBodyOmitted: try values.decodeIfPresent(Bool.self, forKey: .requestBodyOmitted),
			responseBody: try values.decodeIfPresent(String.self, forKey: .responseBody),
			responseBodyBase64: try values.decodeIfPresent(Bool.self, forKey: .responseBodyBase64),
			responseBodyTruncated: try values.decodeIfPresent(Bool.self, forKey: .responseBodyTruncated),
			responseBodyOmitted: try values.decodeIfPresent(Bool.self, forKey: .responseBodyOmitted),
			bytes: try values.decodeIfPresent(Double.self, forKey: .bytes),
			error: try values.decodeIfPresent(String.self, forKey: .error),
			canceled: try values.decodeIfPresent(Bool.self, forKey: .canceled),
			redirected: try values.decodeIfPresent(Bool.self, forKey: .redirected),
			headersOmitted: try values.decodeIfPresent(Bool.self, forKey: .headersOmitted),
			time: try values.decodeIfPresent(Double.self, forKey: .time),
			duration: try values.decodeIfPresent(Double.self, forKey: .duration)
		)
	}

	private enum CodingKeys: String, CodingKey {
		case sequence, method, url, type, status, statusText, mimeType, `protocol`, requestHeaders, responseHeaders
		case requestBody, requestBodyTruncated, requestBodyOmitted, responseBody, responseBodyBase64
		case responseBodyTruncated, responseBodyOmitted, bytes, error, canceled, redirected, headersOmitted, time, duration
	}

	public static let redacted: String = "[redacted]"

	/// Whether a body field's name suggests a credential: the developer log's URL query rule
	/// (`developer_bridge.mm`, `SensitiveKey`), plus CSRF tokens. It errs towards hiding.
	public static func isSensitiveField(_ name: String) -> Bool {
		let lower = (name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name).lowercased()
		let parts = [
			"token", "auth", "key", "secret", "pass", "pwd", "session", "sid", "sig", "code", "credential", "jwt",
			"bearer", "cookie", "ticket", "otp", "state", "nonce", "assertion", "saml", "csrf", "xsrf",
		]
		return parts.contains { lower.contains($0) }
	}

	/// Whether a header name usually carries a credential. The engine applies the same rule before
	/// anything leaves it (`network_capture_bridge.mm`, `SensitiveHeader`).
	public static func isSensitive(_ name: String) -> Bool {
		let lower = name.lowercased()
		let exact: Set<String> = [
			"cookie", "set-cookie", "set-cookie2", "authorization", "proxy-authorization",
			"www-authenticate", "proxy-authenticate",
		]
		let parts = ["auth", "token", "secret", "session", "cookie", "password", "passwd", "csrf", "xsrf", "key", "otp"]
		return exact.contains(lower) || parts.contains { lower.contains($0) }
	}

	/// A copy whose sensitive headers and credential-like body fields read `[redacted]`: fields of
	/// `application/x-www-form-urlencoded` and JSON bodies, matched by name. A body that looks like
	/// JSON but doesn't parse, for example because it was cut, is left out instead, since its
	/// fields can't be found; then each body is cut at `bodyBytes`, after redaction.
	public func redactingCredentials(bodyBytes: Int = AutomationDeveloper.maximumDetailBodyBytes) -> Self {
		var copy = self
		for (name, _) in requestHeaders where Self.isSensitive(name) { copy.requestHeaders[name] = Self.redacted }
		for (name, _) in responseHeaders where Self.isSensitive(name) { copy.responseHeaders[name] = Self.redacted }
		if let body = requestBody {
			copy.requestBody = Self.redactingFields(
				body,
				isForm: Self.isForm(requestHeaders),
				boundary: Self.multipartBoundary(requestHeaders)
			)
			if copy.requestBody == nil { copy.requestBodyOmitted = true }
		}
		if let body = responseBody, responseBodyBase64 != true {
			copy.responseBody = Self.redactingFields(
				body,
				isForm: Self.isForm(responseHeaders),
				boundary: Self.multipartBoundary(responseHeaders)
			)
			if copy.responseBody == nil { copy.responseBodyOmitted = true }
		}
		if let body = copy.requestBody, body.utf8.count > bodyBytes {
			copy.requestBody = Self.prefix(body, bytes: bodyBytes)
			copy.requestBodyTruncated = true
		}
		if let body = copy.responseBody, body.utf8.count > bodyBytes {
			// Base64 is cut at a 4-character boundary, so what's left still decodes.
			copy.responseBody = copy.responseBodyBase64 == true
			? String(body.prefix(bodyBytes / 4 * 4))
			: Self.prefix(body, bytes: bodyBytes)
			copy.responseBodyTruncated = true
		}
		if bodyBytes == 0 {
			copy.requestBody = nil
			copy.responseBody = nil
		}
		return copy
	}

	/// At most `bytes` bytes of `text`, cut at a character boundary.
	private static func prefix(
		_ text: String,
		bytes: Int
	) -> String {
		var result = ""
		var count = 0
		for character in text {
			count += character.utf8.count
			guard count <= bytes else { break }
			result.append(character)
		}
		return result
	}

	/// The boundary of a `multipart/form-data` body, from its Content-Type.
	private static func multipartBoundary(_ headers: [String: String]) -> String? {
		guard
			let type = headers.first(where: { $0.key.lowercased() == "content-type" })?.value,
			type.lowercased().contains("multipart/")
		else { return nil }

		let parameter = type.split(separator: ";")
			.map { $0.trimmingCharacters(in: .whitespaces) }
			.first { $0.lowercased().hasPrefix("boundary=") }
		return parameter.map { String($0.dropFirst("boundary=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
		?? ""
	}

	/// A multipart body whose credential-like parts read `[redacted]`, or nil when its parts can't
	/// be found, so it's left out rather than passed through.
	private static func redactingMultipart(
		_ body: String,
		boundary: String
	) -> String? {
		guard !boundary.isEmpty else { return nil }

		let delimiter = "--" + boundary
		var parts = body.components(separatedBy: delimiter)
		guard parts.count >= 3 else { return nil }

		for index in parts.indices.dropFirst() where !parts[index].hasPrefix("--") {
			let part = parts[index]
			let separator = part.range(of: "\r\n\r\n") ?? part.range(of: "\n\n")
			guard let separator else { return nil }

			// A part whose field name can't be read is hidden rather than passed through.
			let name = dispositionName(String(part[..<separator.lowerBound]))
			guard let name, !isSensitiveField(name) else {
				let ending = part.hasSuffix("\r\n") ? "\r\n" : part.hasSuffix("\n") ? "\n" : ""
				parts[index] = String(part[..<separator.upperBound]) + redacted + ending
				continue
			}

		}
		return parts.joined(separator: delimiter)
	}

	/// The `name` parameter of a part's Content-Disposition header, quoted or not, or nil.
	private static func dispositionName(_ headers: String) -> String? {
		let line = headers.split(whereSeparator: \.isNewline).first { $0.lowercased().hasPrefix("content-disposition:") }
		guard let line else { return nil }

		// Parameters split on semicolons outside quotes; a quoted value may hold any of them.
		var parameters: [String] = []
		var current = ""
		var isQuoted = false
		var isEscaped = false
		for character in line.dropFirst("content-disposition:".count) {
			if isEscaped {
				current.append(character)
				isEscaped = false
			} else if character == "\\", isQuoted {
				current.append(character)
				isEscaped = true
			} else if character == "\"" {
				current.append(character)
				isQuoted.toggle()
			} else if character == ";", !isQuoted {
				parameters.append(current)
				current = ""
			} else {
				current.append(character)
			}
		}
		guard !isQuoted else { return nil }
		parameters.append(current)

		for parameter in parameters {
			let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
			guard pair.count == 2, pair[0].lowercased() == "name" else { continue }

			var value = pair[1]
			if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
				value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
			}
			return value
		}
		return nil
	}

	private static func isForm(_ headers: [String: String]) -> Bool {
		headers.contains { name, value in
			name.lowercased() == "content-type" && value.lowercased().contains("application/x-www-form-urlencoded")
		}
	}

	/// Replaces the values of credential-like fields in a JSON or form body; other text is unchanged.
	/// Nil for a body that looks like JSON but doesn't parse, whose fields can't be found. `isForm`
	/// (from the body's Content-Type) parses it as a form even when a value holds spaces.
	public static func redactingFields(
		_ body: String,
		isForm: Bool = false,
		boundary: String? = nil
	) -> String? {
		if let boundary { return redactingMultipart(body, boundary: boundary) }
		if
			let data = body.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
			object is [String: Any] || object is [Any]
		{
			let redacted = redactingJSON(object)
			guard
				let output = try? JSONSerialization.data(withJSONObject: redacted, options: [.sortedKeys, .withoutEscapingSlashes])
			else { return nil }
			return String(decoding: output, as: UTF8.self)
		}
		let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return nil }

		// A multipart body without its Content-Type: its first line is the delimiter.
		if trimmed.hasPrefix("--"), let first = trimmed.split(whereSeparator: \.isNewline).first {
			return redactingMultipart(body, boundary: String(first.dropFirst(2)))
		}

		// A form body: fields joined by &, each name=value, a bare name or empty. Anything else
		// stays as it is.
		guard
			body.contains("="),
			isForm || !body.contains(where: { $0 == " " || $0.isNewline })
		else { return body }
		return body.split(separator: "&", omittingEmptySubsequences: false).map { field in
			guard field.contains("=") else { return String(field) }
			let name = field.prefix { $0 != "=" }
			return isSensitiveField(String(name)) ? String(name) + "=" + redacted : String(field)
		}
		.joined(separator: "&")
	}

	private static func redactingJSON(_ value: Any) -> Any {
		if let object = value as? [String: Any] {
			var result: [String: Any] = [:]

			// A sensitive key hides its whole value, whatever it holds.
			for (key, child) in object {
				result[key] = isSensitiveField(key) ? redacted : redactingJSON(child)
			}
			return result
		}
		if let array = value as? [Any] { return array.map(redactingJSON) }
		return value
	}
}

/// A HAR 1.2 log of kept request details (DEV-924), as Chrome's DevTools exports it, with the same
/// redactions. Timings Arx doesn't keep read -1, as HAR allows.
public enum AutomationHAR {
	public static func log(_ requests: [AutomationRequestDetail]) -> [String: Any] {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		let entries: [[String: Any]] = requests.map { request in
			let started = Date(timeIntervalSince1970: (request.time ?? 0) / 1_000)
			let duration = request.duration ?? 0
			var postData: [String: Any]?
			if let body = request.requestBody {
				postData = [
					"mimeType": request.requestHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? "",
					"text": body,
				]
			}
			var content: [String: Any] = [
				"size": Int(request.bytes ?? 0),
				"mimeType": request.mimeType ?? "",
			]
			if let body = request.responseBody {
				content["text"] = body
				if request.responseBodyBase64 == true { content["encoding"] = "base64" }
			}
			var entry: [String: Any] = [
				"startedDateTime": formatter.string(from: started),
				"time": duration,
				"request": [
					"method": request.method,
					"url": request.url,
					"httpVersion": request.protocol ?? "",
					"cookies": [Any](),
					"headers": headers(request.requestHeaders),
					"queryString": queryString(request.url),
					"headersSize": -1,
					"bodySize": request.requestBody.map { $0.utf8.count } ?? 0,
				].merging(postData.map { ["postData": $0] } ?? [:]) { first, _ in first },
				"response": [
					"status": request.status ?? 0,
					"statusText": request.statusText ?? "",
					"httpVersion": request.protocol ?? "",
					"cookies": [Any](),
					"headers": headers(request.responseHeaders),
					"content": content,
					"redirectURL": request.responseHeaders.first { $0.key.lowercased() == "location" }?.value ?? "",
					"headersSize": -1,
					"bodySize": Int(request.bytes ?? -1),
				],
				"cache": [String: Any](),
				"timings": ["send": 0, "wait": duration, "receive": 0],
			]
			if let error = request.error { entry["_error"] = error }
			return entry
		}
		return [
			"log": [
				"version": "1.2",
				"creator": ["name": "Arx", "version": "1"],
				"pages": [Any](),
				"entries": entries,
			],
		]
	}

	/// The log as JSON text, keys sorted.
	public static func text(_ requests: [AutomationRequestDetail]) -> String {
		let data = (try? JSONSerialization.data(withJSONObject: log(requests), options: [.sortedKeys, .withoutEscapingSlashes]))
		?? Data()
		return String(decoding: data, as: UTF8.self)
	}

	private static func headers(_ headers: [String: String]) -> [[String: String]] {
		headers.sorted { $0.key < $1.key }.map { ["name": $0.key, "value": $0.value] }
	}

	private static func queryString(_ url: String) -> [[String: String]] {
		(URLComponents(string: url)?.queryItems ?? []).map { ["name": $0.name, "value": $0.value ?? ""] }
	}
}
