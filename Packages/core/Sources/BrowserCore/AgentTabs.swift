import Foundation

/// The tabs an agent opens (DEV-1022): each says which client opened it, the client's next run
/// takes over one it left on the same page instead of opening another, and they're tidied into
/// the archive once nothing has used them for a while. A tab the person picks, or keeps, is
/// theirs from then on. Behind the `ARX_AGENT_TABS` feature flag, on by default (DEV-1143).
public enum AgentTabs {
	public static let featureFlag: String = FeatureFlag.agentTabs.name

	/// Read once, at launch: turning the flag on or off takes a relaunch.
	public static let isOn: Bool = isEnabled()

	/// The environment first, then user defaults, through the `FeatureFlag` registry.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.agentTabs.isOn(environment: environment, defaults: defaults)
	}

	/// Query keys that only say where a link came from, left out when telling pages apart.
	private static let trackingKeys: Set<String> = [
		"dclid", "fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "msclkid", "ref_src",
	]

	/// The page an address shows, for "the same page": its site without `www.`, its path without
	/// a trailing slash and its query without tracking keys or their order; never its fragment.
	/// Nil for an address that isn't on the web.
	public static func page(_ url: URL?) -> String? {
		guard
			let url,
			["http", "https"].contains(url.scheme?.lowercased()),
			var host = url.host(percentEncoded: false)?.lowercased(),
			!host.isEmpty,
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else { return nil }

		if host.hasPrefix("www.") { host.removeFirst(4) }
		let site = host + (url.port.map { ":\($0)" } ?? "")
		var path = components.percentEncodedPath
		while path.hasSuffix("/") { path.removeLast() }

		// Still percent-encoded, so an escaped `&` or `=` in a value can't read as another key.
		let query = (components.percentEncodedQueryItems ?? [])
			.filter { item in
				let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
				return !name.hasPrefix("utm_") && !trackingKeys.contains(name)
			}
			.map { "\($0.name)=\($0.value ?? "")" }
			.sorted()
			.joined(separator: "&")
		return site + path + (query.isEmpty ? "" : "?" + query)
	}
}

/// How long an agent's tab may sit unused before it's tidied into the archive (DEV-1022).
/// Time the Mac spends asleep doesn't count.
public enum AgentTabCleanup: String, Codable, CaseIterable, Sendable {
	case never
	case fifteenMinutes
	case oneHour

	public static let `default`: Self = .fifteenMinutes

	/// Nil never tidies.
	public var delay: Duration? {
		switch self {
		case .never: nil
		case .fifteenMinutes: .seconds(15 * 60)
		case .oneHour: .seconds(60 * 60)
		}
	}
}
