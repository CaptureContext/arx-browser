import Foundation

/// The engine that shows a tab's page (DEV-877). Chromium shows every page except the sites
/// ``WebKitPagePreferences`` lists, which play protected video with macOS's FairPlay in WebKit.
public enum PageEngine: String, Codable, Hashable, Sendable {
	case chromium
	case webKit
}

/// How protected media plays on the listed sites Arx's FairPlay helper supports (DEV-1144). Both
/// are FairPlay; Arx has no Widevine.
public enum ProtectedMediaPlayback: String, Codable, CaseIterable, Hashable, Sendable {
	/// The Chromium tab keeps the page and Arx's FairPlay helper plays it, at the service's best
	/// quality for FairPlay. Other listed sites open in WebKit pages.
	case fairPlayInTab

	/// Every listed site opens in a WebKit page (DEV-877, DEV-1000).
	case webKitPage
}

/// Settings › Advanced › WebKit (DEV-877): the sites that open in WebKit pages, where protected
/// video and music play at Safari's quality, and the sites whose fallback prompt was declined.
///
/// A site is a domain such as `netflix.com`. It matches https pages on that host and its
/// subdomains, never http ones, except on this Mac's own loopback addresses.
public struct WebKitPagePreferences: Codable, Equatable, Sendable {
	/// Off, every page opens in Chromium and nothing offers WebKit.
	public var isEnabled: Bool

	/// The listed sites, in the order Settings shows them.
	public var sites: [String]

	/// Sites whose "Open in WebKit" prompt was answered "Don't ask again".
	public var declinedSites: [String]

	/// How protected media plays on the listed sites that Arx's FairPlay helper supports
	/// (DEV-1144): in the Chromium tab, the default, or in a WebKit page.
	public var protectedMedia: ProtectedMediaPlayback

	/// The Widevine answer (DEV-1144): Chromium says Widevine is there, as Chrome does, for sites
	/// that refuse a browser without it. Arx loads no Widevine: creating its keys fails, and the
	/// page plays FairPlay. The engine reads it at launch.
	public var answersWidevine: Bool

	/// Exact https origins that stay in Chromium though a listed site covers them, such as the
	/// sites Arx's FairPlay helper plays (DEV-1144). Set for the run, never saved.
	public var chromiumOrigins: Set<String> = []

	private enum CodingKeys: String, CodingKey {
		case isEnabled
		case sites
		case declinedSites
		case protectedMedia
		case answersWidevine

		/// The built-in sites the build that saved `sites` knew (DEV-1188).
		case builtInSites
	}

	public init(
		isEnabled: Bool = true,
		sites: [String] = Self.defaultSites,
		declinedSites: [String] = [],
		protectedMedia: ProtectedMediaPlayback = .fairPlayInTab,
		answersWidevine: Bool = true
	) {
		self.isEnabled = isEnabled
		self.sites = sites
		self.declinedSites = declinedSites
		self.protectedMedia = protectedMedia
		self.answersWidevine = answersWidevine
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

		// Entries this build can't read are dropped rather than failing every preference.
		let saved = try? values.decodeIfPresent([String].self, forKey: .sites)
		let known = saved == nil ? Self.defaultSites : (try? values.decodeIfPresent([String].self, forKey: .builtInSites)) ?? []
		self.sites = Self.addingNewBuiltInSites(to: Self.normalized(saved ?? Self.defaultSites), known: known)
		let declined = (try? values.decodeIfPresent([String].self, forKey: .declinedSites)) ?? []
		self.declinedSites = Self.normalized(declined)
		self.protectedMedia = (try? values.decodeIfPresent(ProtectedMediaPlayback.self, forKey: .protectedMedia)) ?? .fairPlayInTab
		self.answersWidevine = (try? values.decodeIfPresent(Bool.self, forKey: .answersWidevine)) ?? true
	}

	public func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(isEnabled, forKey: .isEnabled)
		try values.encode(sites, forKey: .sites)
		try values.encode(declinedSites, forKey: .declinedSites)
		try values.encode(protectedMedia, forKey: .protectedMedia)
		try values.encode(answersWidevine, forKey: .answersWidevine)
		try values.encode(Self.defaultSites, forKey: .builtInSites)
	}

	/// `sites` with the built-in sites that aren't in `known` (DEV-1188): the ones added since
	/// these preferences were saved, so adding a service to `defaultSites` reaches every person.
	/// A built-in site the person took off the list is known, and stays off. Preferences saved
	/// before built-in sites were recorded know none, so every built-in site comes back once.
	/// A site an entry already covers isn't added again.
	private static func addingNewBuiltInSites(
		to sites: [String],
		known: [String]
	) -> [String] {
		let known = Set(normalized(known))
		return defaultSites.reduce(into: sites) { sites, site in
			guard !known.contains(site), !sites.contains(where: { covers($0, host: site) }) else { return }
			sites.append(site)
		}
	}

	/// The sites that open in WebKit by default: streaming services whose protected video or
	/// music plays only with FairPlay, which Arx's Chromium has only for Spotify's player
	/// (DEV-1144), as Ardia lists them. Prime Video's pages on amazon.com aren't listed: matching
	/// is by host, and amazon.com is a shop too.
	///
	/// Each entry covers its subdomains. `netflix.com` covers every page Netflix shows,
	/// `www.netflix.com` (browse, sign-in, account, the player) and `help.netflix.com`; its other
	/// domains (`netflix.net`, the country ones) redirect to `www.netflix.com`, and its
	/// `nflxso.net`, `nflxext.com` and `nflxvideo.net` hosts serve only images, scripts and video
	/// (DEV-1188).
	///
	/// A service added here opens in WebKit for every person, existing lists included, unless
	/// they take it off: saved preferences record the built-in sites they knew (DEV-1188).
	public static let defaultSites: [String] = [
		"netflix.com",
		"disneyplus.com",
		"max.com",
		"hbomax.com",
		"primevideo.com",
		"hulu.com",
		"tv.apple.com",
		"music.apple.com",
		"open.spotify.com",
		"peacocktv.com",
		"paramountplus.com",
		"crunchyroll.com",
		"hotstar.com",
		"jiohotstar.com",
	]

	/// Whether `url` opens in WebKit: an https page of a listed site, with WebKit pages on.
	public func opensInWebKit(_ url: URL) -> Bool {
		guard isEnabled else { return false }
		if !chromiumOrigins.isEmpty, let origin = Self.origin(of: url), chromiumOrigins.contains(origin) {
			return false
		}
		return Self.site(covering: url, in: sites) != nil
	}

	/// Whether `url`'s protected media plays only in a WebKit page (DEV-1188): a built-in
	/// streaming site that's listed and that these preferences don't keep in Chromium for Arx's
	/// FairPlay helper. Netflix and Disney+ serve FairPlay through MediaSource, which the helper
	/// can't play, and Arx has no Widevine, so their video never plays in a Chromium tab, such as
	/// one kept there after Back. The site menu says so; when the video fails, the app offers
	/// WebKit, as it does for any streaming site (DEV-1188). With WebKit pages off, none does.
	public func playsProtectedMediaOnlyInWebKit(_ url: URL) -> Bool {
		opensInWebKit(url) && Self.site(covering: url, in: Self.defaultSites) != nil
	}

	/// Whether `url` is a streaming site's page (DEV-1211): a built-in streaming service's, listed
	/// or not, or a site the person listed for WebKit. Max's rule: a streaming site whose protected
	/// media fails falls back to WebKit with a prompt; elsewhere keys made without media are a
	/// likely bot check, which stays in Chromium with none.
	public func isStreamingSite(_ url: URL) -> Bool {
		Self.site(covering: url, in: Self.defaultSites) != nil || listedSite(for: url) != nil
	}

	/// `url`'s serialized origin, as `https://host[:port]`, for an https page.
	private static func origin(of url: URL) -> String? {
		guard
			url.scheme?.lowercased() == "https",
			let host = url.host(percentEncoded: false)?.lowercased()
		else { return nil }

		let port = url.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
		return "https://" + host + port
	}

	/// Whether the fallback prompt was declined for `url`'s site.
	public func isDeclined(_ url: URL) -> Bool {
		Self.site(covering: url, in: declinedSites) != nil
	}

	/// The listed entry that covers `url`, if any.
	public func listedSite(for url: URL) -> String? {
		Self.site(covering: url, in: sites)
	}

	public var hasDefaultSites: Bool { sites == Self.defaultSites }

	/// Lists `url`'s site: its host without a leading `www.`. Returns false when it was
	/// already covered or isn't a secure page. A listed site is no longer declined.
	@discardableResult
	public mutating func add(_ url: URL) -> Bool {
		guard
			Self.isSecure(url),
			let host = Self.host(of: url)
		else { return false }

		declinedSites.removeAll { Self.covers($0, host: host) }
		guard Self.site(covering: url, in: sites) == nil else { return false }
		sites.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
		return true
	}

	/// Removes every listed entry that covers `url`'s host, so the page stays in Chromium.
	@discardableResult
	public mutating func remove(_ url: URL) -> Bool {
		guard let host = Self.host(of: url) else { return false }
		let count = sites.count
		sites.removeAll { Self.covers($0, host: host) }
		return sites.count != count
	}

	/// Remembers "Don't ask again" for `url`'s site: its host without a leading `www.`.
	public mutating func decline(_ url: URL) {
		guard
			let host = Self.host(of: url),
			Self.site(covering: url, in: declinedSites) == nil
		else { return }

		declinedSites.append(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
	}

	/// Settings' Restore Defaults: brings back every built-in site and keeps the person's own.
	public mutating func restoreDefaults() {
		let custom = sites.filter { !Self.defaultSites.contains($0) }
		sites = Self.defaultSites + custom
	}

	// MARK: - Sites

	/// A site from what a person typed: `https://www.Netflix.com/browse` reads as
	/// `www.netflix.com`. Nil when it has no plausible host.
	public static func site(from input: String) -> String? {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !trimmed.isEmpty else { return nil }
		let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
		guard
			let components = URLComponents(string: candidate),
			let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
			!host.isEmpty,
			host.contains("."),
			host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
		else { return nil }

		return host
	}

	/// Whether the listed `site` covers `host`: the same host or a subdomain of it.
	public static func covers(
		_ site: String,
		host: String
	) -> Bool {
		host == site || host.hasSuffix("." + site)
	}

	private static func site(
		covering url: URL,
		in sites: [String]
	) -> String? {
		guard
			isSecure(url),
			let host = host(of: url)
		else { return nil }

		return sites.first { covers($0, host: host) }
	}

	/// https, or http on this Mac (localhost, 127.0.0.1 or ::1), which browsers treat as a
	/// secure origin where protected media may be asked for.
	public static func isSecure(_ url: URL) -> Bool {
		switch url.scheme?.lowercased() {
		case "https": return true

		case "http":
			guard let host = url.host()?.lowercased() else { return false }
			return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) || host.hasSuffix(".localhost")

		default: return false
		}
	}

	/// `url`'s host as sites match it: lowercased, without a trailing dot.
	public static func host(of url: URL) -> String? {
		guard let host = url.host()?.lowercased(), !host.isEmpty
		else { return nil }

		return host.hasSuffix(".") ? String(host.dropLast()) : host
	}

	private static func normalized(_ sites: [String]) -> [String] {
		var seen: Set<String> = []
		return sites.compactMap(site(from:)).filter { seen.insert($0).inserted }
	}
}
