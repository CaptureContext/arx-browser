import Darwin
import Foundation

/// An app chosen to open a handler's links (DEV-862), anywhere on disk: an installed app, a
/// custom build or a workspace copy.
public struct AppLinkApplication: Codable, Hashable, Sendable {
	/// The `.app` bundle's file path when it was chosen.
	public var path: String

	/// Shown with the app, and checked when the bookmark finds it somewhere else.
	public var bundleID: String?

	/// The app's display name, such as "Claude".
	public var name: String

	/// Bookmark data that follows the app when it moves or is renamed. Nil when macOS made none.
	public var bookmark: Data?

	public init(
		path: String,
		bundleID: String? = nil,
		name: String,
		bookmark: Data? = nil
	) {
		self.path = path
		self.bundleID = bundleID
		self.name = name
		self.bookmark = bookmark
	}

	/// The same bundle on disk, whatever bookmark each copy carries.
	public func isSameApp(as other: Self?) -> Bool {
		other.map { $0.path == path } ?? false
	}
}

/// How Arx handles a page's link for another app (DEV-857).
public enum AppLinkHandling: Hashable, Sendable {
	/// Opens the link in the chosen app, or in the app macOS assigns to its scheme when nil
	/// (System default, as Chrome does).
	case openApp(AppLinkApplication?)

	/// Runs the person's script with `/bin/zsh -c`. The link is `$1`, never part of the text.
	case runScript(String)

	/// Opens Arx's own place for the link (DEV-1193), by DEV-1189's `SettingsAddress`: only
	/// for Arx's built-in handler of another browser's pages, such as `chrome://settings`.
	case openInArx

	/// Open app with whatever macOS assigns to the scheme.
	public static let systemDefault: Self = .openApp(nil)

	public var script: String? {
		guard case let .runScript(script) = self else { return nil }
		return script
	}

	/// The chosen app, when this handling opens one.
	public var application: AppLinkApplication? {
		guard case let .openApp(application) = self else { return nil }
		return application
	}

	public var opensApp: Bool {
		if case .openApp = self { return true }
		return false
	}
}

extension AppLinkHandling: Codable {
	private enum CodingKeys: String, CodingKey {
		case kind
		case script
		case application
	}

	private enum Kind: String, Codable {
		case openApp
		case runScript
		case openInArx
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)

		// A kind a later Arx adds reads as Open app, which runs nothing.
		let kind = (try? values.decodeIfPresent(Kind.self, forKey: .kind)) ?? .openApp
		switch kind {
		case .openApp:
			// Rules saved before DEV-862 have no application: System default.
			self = .openApp(try? values.decodeIfPresent(AppLinkApplication.self, forKey: .application))

		case .runScript:
			self = .runScript(try values.decodeIfPresent(String.self, forKey: .script) ?? "")

		case .openInArx:
			self = .openInArx
		}
	}

	public func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		switch self {
		case let .openApp(application):
			try values.encode(Kind.openApp, forKey: .kind)
			try values.encodeIfPresent(application, forKey: .application)

		case let .runScript(script):
			try values.encode(Kind.runScript, forKey: .kind)
			try values.encode(script, forKey: .script)

		case .openInArx:
			try values.encode(Kind.openInArx, forKey: .kind)
		}
	}
}

/// A profile's own handling for a handler's links.
public struct AppLinkOverride: Codable, Equatable, Sendable {
	public var profileID: Profile.ID
	public var handling: AppLinkHandling

	public init(
		profileID: Profile.ID,
		handling: AppLinkHandling
	) {
		self.profileID = profileID
		self.handling = handling
	}
}

/// Links for one app: a scheme with an optional host and path, handled by default one way and
/// in chosen profiles another.
public struct AppLinkHandler: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID

	/// The app's name as the prompt shows it, such as "Claude".
	public var name: String

	/// Lowercased, without `://`, such as `claude`.
	public var scheme: String
	public var host: String?
	public var pathPrefix: String?

	/// The app picked for this handler (DEV-862): its icon and name in Settings, and the app
	/// a private window or a script's fallback opens. Nil for System default.
	public var application: AppLinkApplication?
	public var defaultHandling: AppLinkHandling
	public var overrides: [AppLinkOverride]

	/// Origins whose links skip the prompt (Always allow ‹site› to open this).
	public var alwaysAllowedOrigins: [String]
	public var isEnabled: Bool

	public init(
		id: UUID,
		name: String,
		scheme: String,
		host: String? = nil,
		pathPrefix: String? = nil,
		application: AppLinkApplication? = nil,
		defaultHandling: AppLinkHandling = .systemDefault,
		overrides: [AppLinkOverride] = [],
		alwaysAllowedOrigins: [String] = [],
		isEnabled: Bool = true
	) {
		self.id = id
		self.name = name
		self.scheme = scheme
		self.host = host
		self.pathPrefix = pathPrefix
		self.application = application
		self.defaultHandling = defaultHandling
		self.overrides = overrides
		self.alwaysAllowedOrigins = alwaysAllowedOrigins
		self.isEnabled = isEnabled
	}

	private enum CodingKeys: String, CodingKey {
		case id, name, scheme, host, pathPrefix, application, defaultHandling, overrides, alwaysAllowedOrigins, isEnabled
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.id = try values.decode(UUID.self, forKey: .id)
		self.name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
		self.scheme = try values.decode(String.self, forKey: .scheme)
		self.host = try values.decodeIfPresent(String.self, forKey: .host)
		self.pathPrefix = try values.decodeIfPresent(String.self, forKey: .pathPrefix)
		self.application = try? values.decodeIfPresent(AppLinkApplication.self, forKey: .application)
		self.defaultHandling = (try? values.decodeIfPresent(AppLinkHandling.self, forKey: .defaultHandling)) ?? .systemDefault
		self.overrides = (try? values.decodeIfPresent([AppLinkOverride].self, forKey: .overrides)) ?? []
		self.alwaysAllowedOrigins = (try? values.decodeIfPresent([String].self, forKey: .alwaysAllowedOrigins)) ?? []
		self.isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
	}

	/// Web schemes and ones Chrome never hands to an app aren't app links.
	public static let reservedSchemes: Set<String> = [
		"http", "https", "file", "about", "blob", "data", "javascript", "chrome", "chrome-extension",
		"devtools", "view-source", "filesystem", "ws", "wss",
	]

	public func validate() throws(AppLinkError) {
		// Arx's built-in handler takes `chrome://`, a scheme a person's own handler can't, and
		// never another: it's only for Chrome's pages.
		if isBuiltIn {
			guard scheme == Self.chromePagesScheme else { throw .invalidDefinition }
		} else if let problem = Self.schemeProblem(scheme) {
			throw problem
		}

		// Only Arx's built-in handler opens Arx's own places.
		let handlings = [defaultHandling] + overrides.map(\.handling)
		guard isBuiltIn || !handlings.contains(.openInArx) else { throw .invalidDefinition }
		if let host {
			guard !host.isEmpty, host == host.lowercased(), !host.contains(where: { $0.isWhitespace || $0 == "/" })
			else { throw .invalidHost }
		}
		if let pathPrefix {
			guard !pathPrefix.isEmpty, !pathPrefix.contains(where: \.isWhitespace)
			else { throw .invalidPath }
		}
		var profiles: Set<Profile.ID> = []
		for override in overrides {
			guard profiles.insert(override.profileID).inserted
			else { throw .invalidDefinition }
		}
	}

	/// Which scheme rule `scheme` breaks, if any: RFC 3986's shape, or a web scheme.
	public static func schemeProblem(_ scheme: String) -> AppLinkError? {
		guard isValidScheme(scheme) else { return .invalidScheme }
		guard !reservedSchemes.contains(scheme) else { return .reservedScheme }
		return nil
	}

	/// What a person types for a scheme, as it's saved: trimmed, lowercased, without `://`.
	public static func normalizedScheme(_ text: String) -> String {
		text
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.replacingOccurrences(of: "://", with: "")
			.replacingOccurrences(of: ":", with: "")
			.lowercased()
	}

	/// The start of the links a handler catches, such as `claude://login/callback`: Settings
	/// shows it as "Catches claude://login/callback…". `*` stands for any host when only a path
	/// is given; a path without `/` matches only links with no host, such as `claude:callback`,
	/// as ``matches(_:)`` compares it verbatim. Nil without a valid scheme.
	public static func example(
		scheme: String,
		host: String?,
		pathPrefix: String?
	) -> String? {
		let scheme = normalizedScheme(scheme)
		guard schemeProblem(scheme) == nil else { return nil }
		let host = host?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
		let path = pathPrefix?.trimmingCharacters(in: .whitespaces) ?? ""
		if host.isEmpty, !path.isEmpty {
			return path.hasPrefix("/") ? scheme + "://*" + path : scheme + ":" + path
		}
		return scheme + "://" + host + path
	}

	/// The apps this handler's rows can pick from without Choose…: its own, then any a
	/// handling already opens, once each.
	public var applications: [AppLinkApplication] {
		let all = [application, defaultHandling.application] + overrides.map(\.handling.application)
		var seen: Set<String> = []
		return all.compactMap { $0 }.filter { seen.insert($0.path).inserted }
	}

	/// RFC 3986: a letter, then letters, digits, `+`, `-` or `.`. Stored lowercased.
	public static func isValidScheme(_ scheme: String) -> Bool {
		guard let first = scheme.unicodeScalars.first, scheme == scheme.lowercased()
		else { return false }
		let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(.init(charactersIn: "+-."))
		return CharacterSet.lowercaseLetters.contains(first)
			&& scheme.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
	}

	public func matches(_ url: URL) -> Bool {
		guard isEnabled, url.scheme?.lowercased() == scheme else { return false }
		if let host, url.host(percentEncoded: false)?.lowercased() != host { return false }
		if let pathPrefix {
			// Opaque links such as `mailto:x` have no host; their path follows the scheme.
			let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
			guard path.hasPrefix(pathPrefix) else { return false }
		}
		return true
	}

	/// The handling for a page in `profileID`. Private pages never run scripts: they get Open
	/// app whatever the handler says, with the default's app or else the handler's.
	public func handling(
		profileID: Profile.ID?,
		isPrivate: Bool
	) -> AppLinkHandling {
		guard !isPrivate else { return fallback }
		if let profileID, let override = overrides.first(where: { $0.profileID == profileID }) {
			return override.handling
		}
		return defaultHandling
	}

	/// The handler with every use of `old` (the same bundle path) opening `new` instead.
	public func replacingApplication(
		_ old: AppLinkApplication,
		with new: AppLinkApplication
	) -> Self {
		var next = self
		if application?.isSameApp(as: old) == true { next.application = new }
		if defaultHandling.application?.isSameApp(as: old) == true { next.defaultHandling = .openApp(new) }
		for index in next.overrides.indices where next.overrides[index].handling.application?.isSameApp(as: old) == true {
			next.overrides[index].handling = .openApp(new)
		}
		return next
	}

	/// Open app as the fallback for a script: the default's app when the default opens one,
	/// otherwise the handler's app, otherwise System default.
	public var fallback: AppLinkHandling {
		if defaultHandling.opensApp { return defaultHandling }
		return .openApp(application)
	}

	/// Whether `origin` skips the prompt. Never for an unknown or untrustworthy origin.
	public func alwaysAllows(_ origin: String?) -> Bool {
		guard let origin, Self.mayRemember(origin) else { return false }
		return alwaysAllowedOrigins.contains(origin)
	}

	/// Only a potentially trustworthy origin may be remembered, as Chrome's
	/// `MayRememberAllowDecisionsForThisOrigin`: HTTPS, or HTTP on a loopback host. A plain
	/// HTTP site could be anyone on the network next time.
	public static func mayRemember(_ origin: String?) -> Bool {
		guard
			let origin,
			let components = URLComponents(string: origin),
			let scheme = components.scheme?.lowercased(),
			let host = components.host?.lowercased(),
			!host.isEmpty
		else { return false }
		switch scheme {
		case "https": return true
		case "http": return host == "localhost" || host.hasSuffix(".localhost") || isLoopbackAddress(host)
		default: return false
		}
	}

	/// `127.0.0.0/8` or `::1`, parsed as addresses, never matched as text.
	private static func isLoopbackAddress(_ host: String) -> Bool {
		let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
		var v4 = in_addr()
		if inet_pton(AF_INET, bare, &v4) == 1 {
			return UInt32(bigEndian: v4.s_addr) >> 24 == 127
		}
		var v6 = in6_addr()
		guard inet_pton(AF_INET6, bare, &v6) == 1 else { return false }
		return withUnsafeBytes(of: &v6) { bytes in bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1 }
	}
}

extension AppLinkHandler {
	/// Arx's built-in handler for Chrome's own pages (DEV-1193). A page's `chrome://` link
	/// reaches App Links through it, as any app's link does: "Open Google Chrome?", with Open in
	/// Arx beside it when Arx has a place for the page. It's saved with the person's handlers
	/// the first time such a link comes while Chrome is installed, so Always allow and
	/// Settings › Links › App Links work on it like on any other.
	public static let chromePagesID: UUID = UUID(uuidString: "A2C0DE00-0000-4000-8000-0000C4120E00")!

	public static let chromePagesScheme: String = "chrome"

	/// The built-in handler, opening Chrome at `application` unless the person changes it.
	public static func chromePages(application: AppLinkApplication) -> Self {
		.init(
			id: chromePagesID,
			name: application.name,
			scheme: chromePagesScheme,
			application: application,
			defaultHandling: .openApp(application)
		)
	}

	/// Arx's own handler rather than the person's.
	public var isBuiltIn: Bool {
		id == Self.chromePagesID
	}
}

public struct AppLinkPreferences: Codable, Equatable, Sendable {
	public var handlers: [AppLinkHandler]

	public init(handlers: [AppLinkHandler] = []) {
		self.handlers = handlers
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.handlers = (try? values.decodeIfPresent([AppLinkHandler].self, forKey: .handlers)) ?? []
	}

	public func validate() throws(AppLinkError) {
		var ids: Set<UUID> = []
		for handler in handlers {
			try handler.validate()
			guard ids.insert(handler.id).inserted
			else { throw .invalidDefinition }
		}
	}

	/// The first enabled handler matching `url`, in list order.
	public func handler(for url: URL) -> AppLinkHandler? {
		handlers.first { $0.matches(url) }
	}

	/// These handlers with Arx's built-in one for Chrome's pages added, when it isn't saved
	/// yet (DEV-1193). One the person saved or edited stays as it is.
	public func including(_ builtIn: AppLinkHandler) -> Self {
		guard !handlers.contains(where: { $0.id == builtIn.id }) else { return self }
		return .init(handlers: handlers + [builtIn])
	}
}

public enum AppLinkError: Error, Equatable, Sendable {
	/// Two overrides for one profile, or two handlers with one ID.
	case invalidDefinition

	/// The scheme breaks RFC 3986: a letter, then letters, digits, `+`, `-` or `.`.
	case invalidScheme

	/// http, https, file and other schemes Chrome never hands to an app.
	case reservedScheme

	/// The host has capitals, spaces or a `/`.
	case invalidHost

	/// The path has spaces.
	case invalidPath

	/// The link doesn't parse as a URL.
	case malformed

	/// The link's scheme isn't the handler's.
	case schemeMismatch

	/// The link contains a control character, such as a newline.
	case controlCharacters

	/// The link is longer than ``AppLinkValidation/maximumLength`` bytes.
	case tooLong
}

/// Checks a link before a script may see it. Nothing runs for a link that fails.
public enum AppLinkValidation {
	public static let maximumLength: Int = 8 * 1024

	public static func validate(
		_ link: String,
		scheme: String
	) throws(AppLinkError) -> URL {
		guard link.utf8.count <= maximumLength else { throw .tooLong }
		guard !link.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
		else { throw .controlCharacters }
		guard
			let url = URL(string: link, encodingInvalidCharacters: false),
			let parsed = url.scheme?.lowercased()
		else { throw .malformed }
		guard parsed == scheme else { throw .schemeMismatch }
		return url
	}
}

/// What Arx does with a page's link for another app: which handler, which handling, and
/// whether the person is asked first.
public struct AppLinkDecision: Equatable, Sendable {
	public var handler: AppLinkHandler
	public var handling: AppLinkHandling

	/// Why a script can't take this link, when it can't. The prompt then offers Open app only.
	public var failure: AppLinkError?

	/// The source origin is always allowed for this handler.
	public var skipsPrompt: Bool

	/// The handler is one of the person's. False for a link no handler takes (DEV-1259): the
	/// handler exists only for this prompt, and Always allow saves it.
	public var isSaved: Bool

	public init(
		handler: AppLinkHandler,
		handling: AppLinkHandling,
		failure: AppLinkError? = nil,
		skipsPrompt: Bool = false,
		isSaved: Bool = true
	) {
		self.handler = handler
		self.handling = handling
		self.failure = failure
		self.skipsPrompt = skipsPrompt
		self.isSaved = isSaved
	}
}

extension AppLinkPreferences {
	/// Nil leaves the link to Chrome: no handler matches it.
	public func decide(
		link: String,
		profileID: Profile.ID?,
		isPrivate: Bool,
		sourceOrigin: String?
	) -> AppLinkDecision? {
		guard
			let url = URL(string: link, encodingInvalidCharacters: false),
			let handler = handler(for: url)
		else { return nil }

		let handling = handler.handling(profileID: profileID, isPrivate: isPrivate)
		var failure: AppLinkError?
		if handling.script != nil {
			do {
				_ = try AppLinkValidation.validate(link, scheme: handler.scheme)
			} catch {
				failure = error
			}
		}

		// A link a script can't take is always asked about.
		return .init(
			handler: handler,
			handling: handling,
			failure: failure,
			// A private window always asks: sites are remembered only from ordinary ones.
			skipsPrompt: failure == nil && !isPrivate && handler.alwaysAllows(sourceOrigin)
		)
	}
}

extension AppLinkPreferences {
	/// The scheme of a link no handler takes that is still a link for another app (DEV-1259),
	/// such as `linear` for `linear://issue/X`. Nil when a handler takes it, or when it isn't a
	/// URL with a scheme a handler could take: web schemes, `chrome` and malformed links.
	public func unmatchedScheme(link: String) -> String? {
		guard
			let url = URL(string: link, encodingInvalidCharacters: false),
			let scheme = url.scheme?.lowercased(),
			AppLinkHandler.schemeProblem(scheme) == nil,
			handler(for: url) == nil
		else { return nil }
		return scheme
	}

	/// Arx's prompt for a link no handler takes (DEV-1259), in place of Chrome's "Open app?"
	/// dialog: Open app with whatever macOS assigns to the scheme, named `appName`, asking
	/// every time. The handler isn't saved; Always allow saves it, with the site, as the person's
	/// own. Nil when a handler takes the link or it can't be an app link (``unmatchedScheme(link:)``).
	public func decideUnmatched(
		link: String,
		appName: String,
		handlerID: UUID
	) -> AppLinkDecision? {
		guard let scheme = unmatchedScheme(link: link) else { return nil }
		let name = appName.trimmingCharacters(in: .whitespacesAndNewlines)
		let handler = AppLinkHandler(
			id: handlerID,
			name: name.isEmpty ? scheme : name,
			scheme: scheme,
			defaultHandling: .systemDefault
		)
		return .init(handler: handler, handling: .systemDefault, isSaved: false)
	}
}
