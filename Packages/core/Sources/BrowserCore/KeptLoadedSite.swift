import Foundation

/// A site whose tabs Arx never unloads (DEV-932), kept per profile in
/// ``Profile/keptLoadedSites``: a lowercased host without `www.`, which covers its subdomains, as
/// Chrome's and Ardia's Memory Saver exceptions do. Tab unloading skips these tabs on its timer
/// and under memory pressure (``TabUnloadEligibility``).
public enum KeptLoadedSite {
	/// The site a person typed or a tab shows: `music.example.com`, `https://www.example.com/a`
	/// and `Example.com` give `music.example.com`, `example.com` and `example.com`, and
	/// `http://[::1]:8080` gives `[::1]`. Nil when there's no host, as for `about:blank` or text
	/// with spaces. A site reads back as itself.
	public static func site(from text: String) -> String? {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

		let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
		guard
			let url = URL(string: candidate),
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme)
		else { return nil }

		return site(of: url)
	}

	/// The site `url` belongs to, or nil for a page without an http(s) host.
	public static func site(of url: URL) -> String? {
		guard
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			var host = url.host(percentEncoded: false)?.lowercased(),
			!host.isEmpty
		else { return nil }

		// An IPv6 address keeps its brackets, so the site reads back as itself.
		if host.contains(":") { return "[" + host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) + "]" }
		if host.hasSuffix(".") { host.removeLast() }
		if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
		return host.isEmpty ? nil : host
	}

	/// Whether `url` is on `site` or one of its subdomains.
	public static func matches(
		_ url: URL,
		site: String
	) -> Bool {
		guard let host = self.site(of: url) else { return false }

		return host == site || host.hasSuffix("." + site)
	}

	/// `sites` with `site` added or removed, sorted and without duplicates; nil when it's empty.
	public static func sites(
		_ sites: [String]?,
		setting site: String,
		kept: Bool
	) -> [String]? {
		var result = Set(sites ?? [])
		if kept {
			result.insert(site)
		} else {
			result.remove(site)
		}
		return result.isEmpty ? nil : result.sorted()
	}
}
