import BrowserCore
import CryptoKit
import Foundation
import WebKit

/// Arx's content blocking for WebKit pages (DEV-877): the filter lists Chromium pages' uBlock
/// Origin uses, fetched from the same publishers, converted to WebKit content rules and compiled
/// once per list version. Pages follow Settings' Content blocking switches and each site's own
/// exception.
@MainActor
public final class WebKitContentRules {
	/// A filter list and where it's published.
	public struct Source: Equatable, Sendable {
		public var name: String
		public var url: URL

		public init(
			name: String,
			url: URL
		) {
			self.name = name
			self.url = url
		}
	}

	/// uBlock Origin's default lists, as its registry publishes them.
	public static let defaultSources: [Source] = [
		.init(name: "easylist", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easylist.txt")!),
		.init(name: "easyprivacy", url: URL(string: "https://ublockorigin.github.io/uAssets/thirdparties/easyprivacy.txt")!),
		.init(name: "ublock-filters", url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/filters/filters.min.txt")!),
		.init(name: "ublock-privacy", url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/filters/privacy.min.txt")!),
		.init(name: "ublock-badware", url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/filters/badware.min.txt")!),
	]

	/// The cookie notice lists Block cookie banners adds.
	public static let cookieBannerSources: [Source] = [
		.init(name: "easylist-cookies", url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/thirdparties/easylist-cookies.txt")!),
		.init(name: "ublock-cookies", url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/filters/annoyances-cookies.txt")!),
	]

	/// uBlock's unbreak list: exceptions added to every other list, since WebKit applies an
	/// exception only within its own list.
	public static let unbreakSource: Source = .init(
		name: "ublock-unbreak",
		url: URL(string: "https://ublockorigin.github.io/uAssetsCDN/filters/unbreak.min.txt")!
	)

	/// Lists are fetched again after this long, as uBlock's own update period.
	public static let refreshInterval: TimeInterval = 4 * 24 * 60 * 60

	public struct Settings: Equatable, Sendable {
		public var isEnabled: Bool
		public var blocksCookieBanners: Bool

		public init(
			isEnabled: Bool,
			blocksCookieBanners: Bool
		) {
			self.isEnabled = isEnabled
			self.blocksCookieBanners = blocksCookieBanners
		}
	}

	private let directory: URL
	private let fetch: @Sendable (URL) async throws -> Data
	private var compiled: [String: WKContentRuleList] = [:]
	private var refresh: Task<Void, Never>?
	private var lastLoad: Date?
	private let controllers: NSMapTable<WKUserContentController, PageAddress> = .weakToStrongObjects()

	/// Settings › General › Content blocking, read as each page loads.
	public var settings: @MainActor () -> Settings = { .init(isEnabled: true, blocksCookieBanners: false) }

	/// Whether a site's own exception leaves content blocking on, by the page's profile and URL.
	/// The app answers from the profile's site settings.
	public var blocksContent: @MainActor (Profile.ID, URL) -> Bool = { _, _ in true }

	/// `directory` keeps the downloaded lists and WebKit's compiled rules.
	public init(
		directory: URL,
		fetch: @escaping @Sendable (URL) async throws -> Data = { url in
			let (data, response) = try await URLSession.shared.data(from: url)
			guard (response as? HTTPURLResponse)?.statusCode == 200
			else { throw URLError(.badServerResponse) }
			return data
		}
	) {
		self.directory = directory
		self.fetch = fetch
	}

	/// Puts the lists on a page's controller before it loads `url`, or takes them off for a
	/// site with content blocking off.
	public func apply(
		to controller: WKUserContentController,
		profile: Profile.ID,
		for url: URL
	) {
		controllers.setObject(PageAddress(profile: profile, url: url), forKey: controller)
		controller.removeAllContentRuleLists()
		let settings = settings()
		guard
			settings.isEnabled,
			url.hasWebScheme,
			blocksContent(profile, url)
		else { return }

		startIfStale()
		for name in wantedNames(settings) {
			if let list = compiled[name] { controller.add(list) }
		}
	}

	/// Applies the current settings and site exceptions again to every open page, after a list
	/// compiled or a setting changed.
	public func reapply() {
		for controller in controllers.keyEnumerator().allObjects.compactMap({ $0 as? WKUserContentController }) {
			guard let address = controllers.object(forKey: controller) else { continue }
			apply(to: controller, profile: address.profile, for: address.url)
		}
	}

	private func wantedNames(_ settings: Settings) -> [String] {
		(Self.defaultSources + (settings.blocksCookieBanners ? Self.cookieBannerSources : [])).map(\.name)
	}

	/// Loads the lists the first time they're wanted, and again once they're older than the
	/// refresh interval.
	private func startIfStale() {
		guard refresh == nil else { return }
		if let lastLoad, Date().timeIntervalSince(lastLoad) < Self.refreshInterval { return }
		lastLoad = Date()
		refresh = Task { [weak self] in
			await self?.load()
			self?.refresh = nil
		}
	}

	private func load() async {
		let sources = Self.defaultSources + Self.cookieBannerSources
		let unbreak = await text(of: Self.unbreakSource)
		let exceptions = unbreak.map { ContentRuleConverter().convert($0).exceptions } ?? []
		for source in sources {
			guard let text = await text(of: source) else { continue }
			await compile(source, text: text, extraExceptions: exceptions)
			reapply()
		}
	}

	/// A list's text: the saved copy while it's fresh, otherwise fetched again, falling back to
	/// the saved one when the fetch fails.
	private func text(of source: Source) async -> String? {
		let file = directory.appending(path: "Lists/\(source.name).txt")
		let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
		let modified = attributes?[.modificationDate] as? Date
		if let modified, Date().timeIntervalSince(modified) < Self.refreshInterval,
			let saved = try? String(contentsOf: file, encoding: .utf8) {
			return saved
		}
		do {
			let data = try await fetch(source.url)
			try FileManager.default.createDirectory(
				at: file.deletingLastPathComponent(),
				withIntermediateDirectories: true
			)
			try data.write(to: file, options: .atomic)
			return String(decoding: data, as: UTF8.self)
		} catch {
			return try? String(contentsOf: file, encoding: .utf8)
		}
	}

	private func compile(
		_ source: Source,
		text: String,
		extraExceptions: [ContentRuleConverter.Rule]
	) async {
		let storeURL = directory.appending(path: "Store")
		try? FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
		guard let store = WKContentRuleListStore(url: storeURL) else { return }

		let identifier = Self.identifier(of: source, text: text, extraExceptions: extraExceptions)
		if let list = try? await store.contentRuleList(forIdentifier: identifier) {
			compiled[source.name] = list
			return
		}
		let json: String? = await Task.detached(priority: .utility) {
			var conversion = ContentRuleConverter().convert(text)
			conversion.exceptions += extraExceptions
			return try? ContentRuleConverter.json(conversion.rules())
		}.value
		guard let json else { return }

		do {
			guard let list = try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
			else { return }

			compiled[source.name] = list

			// Older compiled versions of this list go.
			let identifiers = await store.availableIdentifiers() ?? []
			for old in identifiers where old.hasPrefix(source.name + "-") && old != identifier {
				try? await store.removeContentRuleList(forIdentifier: old)
			}
		} catch {
			// A list WebKit refuses (a rule it can't compile) stays off; the others still apply.
		}
	}

	/// The compiled list's name in WebKit's store. The list's text, the added exceptions and the
	/// conversion are part of it, so a change to any of them compiles the list again: a fixed
	/// conversion reaches lists compiled before it (DEV-1202).
	internal static func identifier(
		of source: Source,
		text: String,
		extraExceptions: [ContentRuleConverter.Rule],
		revision: Int = ContentRuleConverter.revision
	) -> String {
		let exceptionsJSON = (try? ContentRuleConverter.json(extraExceptions)) ?? ""
		let digest = SHA256.hash(data: Data((text + "\n" + exceptionsJSON + "\nconverter \(revision)").utf8))
		return source.name + "-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
	}
}

/// The page a controller last loaded, for applying the rules again.
private final class PageAddress {
	internal let profile: Profile.ID
	internal let url: URL

	internal init(
		profile: Profile.ID,
		url: URL
	) {
		self.profile = profile
		self.url = url
	}
}
