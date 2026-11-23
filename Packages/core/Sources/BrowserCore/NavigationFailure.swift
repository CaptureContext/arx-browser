import Foundation

extension BrowserNavigation {
	/// A page failure classified for presentation from the engine's net error code and the failed URL.
	///
	/// Local development explanations apply only to loopback HTTP(S) pages. They never offer to
	/// bypass certificate validation.
	public enum Failure: Equatable, Sendable {
		/// The renderer stopped; reload recovers it.
		case rendererStopped

		/// A loopback server refused the connection, so nothing is listening on `port`.
		case localServerUnreachable(port: Int)

		/// A loopback server presented a certificate that failed validation.
		case localCertificateRejected

		/// A loopback `https` page failed its TLS handshake, usually because the server speaks plain
		/// HTTP. `httpURL` is the same page over `http` on the same port.
		case localServerExpectsHTTP(httpURL: URL)

		/// Any other failure, presented generically with its net error code.
		case other(Int)

		/// The engine's sentinel for a renderer that stopped responding.
		public static let rendererStoppedCode: Int = -10000

		/// Chromium's `ERR_CONNECTION_REFUSED`.
		public static let connectionRefusedCode: Int = -102

		/// Chromium's `ERR_SSL_PROTOCOL_ERROR`, reported when an `https` request reaches a plain-HTTP server.
		public static let sslProtocolErrorCode: Int = -107

		/// Chromium's certificate error range, `ERR_CERT_COMMON_NAME_INVALID` through the last value before `ERR_CERT_END`.
		public static let certificateErrorCodes: ClosedRange<Int> = -219 ... -200

		public init(
			errorCode: Int,
			url: URL?
		) {
			if errorCode == Self.rendererStoppedCode {
				self = .rendererStopped
				return
			}
			guard let url, let port = Self.localDevelopmentPort(of: url) else {
				self = .other(errorCode)
				return
			}
			if errorCode == Self.connectionRefusedCode {
				self = .localServerUnreachable(port: port)
			} else if Self.certificateErrorCodes.contains(errorCode) {
				self = .localCertificateRejected
			} else if errorCode == Self.sslProtocolErrorCode, let httpURL = Self.plainHTTPURL(for: url) {
				self = .localServerExpectsHTTP(httpURL: httpURL)
			} else {
				self = .other(errorCode)
			}
		}

		/// The effective port of a loopback HTTP(S) URL, or `nil` for any other URL.
		///
		/// Loopback hosts are `localhost`, `*.localhost`, `127.0.0.0/8`, and `::1`.
		public static func localDevelopmentPort(of url: URL) -> Int? {
			let scheme = url.scheme?.lowercased()
			let defaultPort: Int
			switch scheme {
			case "http": defaultPort = 80
			case "https": defaultPort = 443
			default: return nil
			}
			guard let host = url.host(percentEncoded: false), isLoopback(host: host)
			else { return nil }

			return url.port ?? defaultPort
		}

		/// The `http` form of a loopback `https` URL, keeping its effective port, path, query, and fragment,
		/// or `nil` for any other URL.
		///
		/// An implicit port becomes an explicit `443`, because that is where the plain-HTTP server answered.
		public static func plainHTTPURL(for url: URL) -> URL? {
			guard
				url.scheme?.lowercased() == "https",
				let port = localDevelopmentPort(of: url),
				var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
			else { return nil }

			components.scheme = "http"
			components.port = port
			return components.url
		}

		/// Whether `host` names this computer: `localhost`, `*.localhost`, `127.0.0.0/8`, or `::1`.
		public static func isLoopback(host: String) -> Bool {
			var name = host.lowercased()
			if name.hasPrefix("["), name.hasSuffix("]") {
				name = String(name.dropFirst().dropLast())
			}

			if name.hasSuffix(".") { name.removeLast() }
			guard !name.isEmpty else { return false }
			if name == "localhost" || name.hasSuffix(".localhost") { return true }
			if name.contains(":") { return isIPv6Loopback(name) }
			let octets = name.split(separator: ".", omittingEmptySubsequences: false)
			let areOctetsValid = octets.allSatisfy { octet in
				!octet.isEmpty
				&& octet.count <= 3
				&& octet.allSatisfy(\.isASCIIDigit)
				&& (Int(octet) ?? 256) <= 255
			}

			guard octets.count == 4, areOctetsValid
			else { return false }

			return octets[0] == "127"
		}

		private static func isIPv6Loopback(_ address: String) -> Bool {
			var storage = in6_addr()
			guard inet_pton(AF_INET6, address, &storage) == 1 else { return false }
			return withUnsafeBytes(of: &storage) { bytes in
				bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
			}
		}
	}

	/// The classified failure of the current navigation, or `nil` when it succeeded.
	public var failure: Failure? {
		errorCode.map { Failure(errorCode: $0, url: url) }
	}

	/// DEV-1226: whether this failed navigation committed the engine's own error page, such as
	/// Chromium's "This site can't be reached" for a DNS failure, a refused connection or no
	/// network, with its own Reload button. A committed error page is a new main-frame document:
	/// `document` moved past `previousDocument`, the document seen before this navigation. A
	/// failure that commits nothing (a blank tab, the page before it still showing) and a stopped
	/// renderer didn't. Seeing the tab for the first time, with no document before it, the page is
	/// the error page when its current history entry is the failed address. False when the engine
	/// doesn't count documents.
	public func committedErrorPage(after previousDocument: UInt64) -> Bool {
		guard
			let errorCode,
			errorCode != Failure.rendererStoppedCode,
			document != 0
		else { return false }

		guard previousDocument == 0 else { return document != previousDocument }
		guard let url, let entry = history.first(where: \.isCurrent) else { return false }
		return entry.url == url
	}
}

extension BrowserNavigation.Failure {
	/// DEV-1226: whether Arx's card says something the engine's committed error page doesn't. A
	/// generic failure only repeats it, with a second Reload button. The local development
	/// explanations name the fix (the port nothing listens on, the rejected loopback
	/// certificate, the server that speaks plain HTTP, with Open over HTTP), and a stopped renderer
	/// has no error page.
	public var addsToEngineErrorPage: Bool {
		switch self {
		case .other: false
		case .rendererStopped, .localServerUnreachable, .localCertificateRejected, .localServerExpectsHTTP: true
		}
	}
}

extension Character {
	fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
