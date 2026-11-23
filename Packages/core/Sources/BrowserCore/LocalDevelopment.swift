import Foundation

/// Local development pages, which show the developer header in developer mode (DEV-733).
public enum LocalDevelopment {
	/// An http(s) address on this computer (`localhost`, `*.localhost`, `127.0.0.0/8`,
	/// `[::1]`), on a `*.test` host, or on a private-network IPv4 address with a port.
	public static func isLocal(_ url: URL?) -> Bool {
		guard
			let url,
			url.hasWebScheme,
			var host = url.host(percentEncoded: false)?.lowercased()
		else { return false }

		if host.hasSuffix(".") { host.removeLast() }
		if BrowserNavigation.Failure.isLoopback(host: host) { return true }
		if host.hasSuffix(".test"), host.count > ".test".count { return true }
		return url.port != nil && isPrivateIPv4(host)
	}

	/// A page on this computer or the local network, whose sidebar row gets the construction-tape
	/// border (DEV-786): everything `isLocal` takes, plus `*.local` (Bonjour) hosts and private
	/// IPv4 addresses without a port, such as a router's page.
	public static func isLocalNetwork(_ url: URL?) -> Bool {
		guard
			let url,
			url.hasWebScheme,
			var host = url.host(percentEncoded: false)?.lowercased()
		else { return false }

		if host.hasSuffix(".") { host.removeLast() }
		if isLocal(url) { return true }
		if host.hasSuffix(".local"), host.count > ".local".count { return true }
		return isPrivateIPv4(host)
	}

	/// The host and any explicit port, as the sidebar shows them under a local tab's title:
	/// `localhost:3000`, `[::1]:4000`, `router.local`. Nil for a page that isn't on the local network.
	public static func hostLabel(_ url: URL?) -> String? {
		guard isLocalNetwork(url), let url, var host = url.host(percentEncoded: false)?.lowercased()
		else { return nil }

		if host.hasSuffix(".") { host.removeLast() }
		if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
		guard let port = url.port else { return host }

		return "\(host):\(port)"
	}

	/// 10.0.0.0/8, 172.16.0.0/12 and 192.168.0.0/16.
	private static func isPrivateIPv4(_ host: String) -> Bool {
		let octets = host.split(separator: ".", omittingEmptySubsequences: false)
		guard
			octets.count == 4,
			octets.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy({ $0.isASCII && $0.isNumber }) })
		else { return false }

		let values = octets.compactMap { Int($0) }
		guard values.count == 4, values.allSatisfy({ $0 <= 255 }) else { return false }
		switch (values[0], values[1]) {
		case (10, _): return true
		case (172, 16 ... 31): return true
		case (192, 168): return true
		default: return false
		}
	}
}
