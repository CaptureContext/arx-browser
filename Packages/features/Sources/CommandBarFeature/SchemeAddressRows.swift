import AppKit
import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

/// Which app on this Mac opens a scheme's links, for typed addresses (DEV-1189).
public struct CommandBarSchemeApps: Sendable {
	/// The app's display name, or nil when no app opens `scheme`.
	public var appName: @Sendable (_ scheme: String) -> String?

	public init(appName: @escaping @Sendable (_ scheme: String) -> String?) {
		self.appName = appName
	}
}

extension CommandBarSchemeApps: DependencyKey {
	public static var liveValue: Self {
		.init { scheme in
			guard
				let url = URL(string: scheme + ":"),
				let app = NSWorkspace.shared.urlForApplication(toOpen: url)
			else { return nil }

			return FileManager.default.displayName(atPath: app.path(percentEncoded: false))
				.replacing(/\.app$/, with: "")
		}
	}

	/// No app opens anything, so `scheme:rest` text searches unless a test says otherwise.
	public static var testValue: Self {
		.init { _ in nil }
	}
}

extension DependencyValues {
	public var commandBarSchemeApps: CommandBarSchemeApps {
		get { self[CommandBarSchemeApps.self] }
		set { self[CommandBarSchemeApps.self] = newValue }
	}
}

extension CommandBarFeature.State {
	/// The address the typed text names with a scheme other than http(s), and what it is
	/// (DEV-1189), while the `ARX_SCHEME_ADDRESSES` feature flag is on. Another app's link counts
	/// only while macOS names an app that opens it: one nothing opens is searched for instead,
	/// rather than lost once the bar closes.
	public var schemeAddress: (url: URL, kind: TypedSchemeAddress.Kind)? {
		guard
			opensSchemeAddresses,
			mode != .history,
			siteSearchKeyword == nil
		else { return nil }

		let hasApp: (String) -> Bool = { scheme in (schemeApps[scheme] ?? nil) != nil }
		guard let address = TypedSchemeAddress.address(query, hasApp: hasApp) else { return nil }
		if case let .app(scheme) = address.kind, !hasApp(scheme) { return nil }
		return address
	}

	/// The command a typed `chrome://downloads`, `history` or `extensions` stands for: the bar
	/// lists that command, as it does for `arx://extensions`.
	internal var schemeAddressCommand: BrowserCommand? {
		guard case let .settings(.command(command)) = schemeAddress?.kind else { return nil }
		return command
	}

	/// Asks once per scheme which app opens it, before the typed text is read.
	internal mutating func learnSchemeApp(
		for text: String,
		appName: (String) -> String?
	) {
		guard
			opensSchemeAddresses,
			let scheme = TypedSchemeAddress.appScheme(text),
			!schemeApps.keys.contains(scheme)
		else { return }

		schemeApps[scheme] = .some(appName(scheme))
	}

	/// The row that opens a typed scheme address: Settings, another app or a page.
	internal func schemeAddressEntry(
		_ text: String,
		url: URL,
		kind: TypedSchemeAddress.Kind
	) -> CommandBarFeature.Entry {
		let subtitle: String
		let symbol: String
		switch kind {
		case .settings:
			subtitle = String.localized(.appUI.command.settingsAddress)
			symbol = "gearshape"

		case let .app(scheme):
			subtitle = (schemeApps[scheme] ?? nil).map { String.localized(.appUI.command.opensInApp($0)) }
				?? url.absoluteString
			symbol = "arrow.up.forward.app"

		case .page:
			subtitle = url.absoluteString
			symbol = "globe"
		}
		return .init(
			presentation: .init(
				id: CommandBarFeature.State.typedAddressID,
				title: text,
				subtitle: subtitle,
				actionTitle: String.localized(.appUI.command.open),
				symbol: symbol
			),
			intent: .open(url)
		)
	}

	/// The typed text's own link row, a web address or one with another scheme.
	internal static let typedAddressID: String = "destination"

	// MARK: - ⌘↩ opens what's typed

	/// What ⌘↩ opens (DEV-1189): exactly what's typed, read as an address, never a search or the
	/// highlighted result. Text without a scheme gets `https://`, so `intranet` or
	/// `example.com:8080` open as typed. Nil for text with spaces, a `!bang`, a keyword search,
	/// Show History, and `scheme:rest` text that's no address, such as `note:milk`.
	public var typedURL: URL? {
		let text: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			opensSchemeAddresses,
			mode != .history,
			siteSearchKeyword == nil,
			!text.isEmpty,
			!text.hasPrefix("!"),
			!text.contains(where: \.isWhitespace)
		else { return nil }

		if let address = schemeAddress { return address.url }
		if
			let url = URL(string: text, encodingInvalidCharacters: false),
			["http", "https"].contains(url.scheme?.lowercased() ?? ""),
			url.host() != nil
		{
			return url
		}

		// `localhost:3000` speaks plain HTTP, as Return opens it.
		if
			let url = Self.destination(text, searchEngine: searchEngine),
			url != searchEngine.url(for: text)
		{
			// Never with a user and password, which a page could use to pass for another site.
			return url.user() == nil && url.password() == nil ? url : nil
		}

		// Anything else with a colon before its path is a host and its port, or no address at all.
		// A colon in the path, as in `intranet/wiki/Help:Contents`, is the path's own.
		let authority: Substring = text.prefix { !"/?#".contains($0) }
		if
			let colon = authority.firstIndex(of: ":"),
			authority[authority.index(after: colon)...].first?.isNumber != true
		{
			return nil
		}
		guard
			!authority.contains(":/"),
			let url = URL(string: "https://" + text, encodingInvalidCharacters: false),
			url.host() != nil,
			url.user() == nil,
			url.password() == nil
		else { return nil }

		return url
	}

	/// The result ⌘↩ runs: the typed address in the current tab from the address field (and in
	/// Little Arx, which has no other), in a new tab from ⌘T or ⌘K.
	public var openURLEntry: CommandBarFeature.Entry? {
		guard let url = typedURL else { return nil }
		let intent: CommandBarFeature.Intent = mode == .commands && actionAvailability.opensNewTabs
		? .openInNewTab(url)
		: .open(url)
		return .init(
			presentation: .init(
				id: Self.openURLID,
				title: query.trimmingCharacters(in: .whitespacesAndNewlines),
				subtitle: url.absoluteString,
				actionTitle: String.localized(.appUI.command.openURL),
				symbol: "globe"
			),
			intent: intent
		)
	}

	/// ⌘↩ belongs to Open URL while the bar has one and the person hasn't bound ⌘↩ to a command
	/// or to Copy URL, whose binding wins. A result's Open in New Tab then shows no key, and
	/// stays in its actions. In the actions panel too, where Open as is lists it with ⌘↩
	/// (DEV-1319), so no two actions there claim the key.
	internal var openURLTakesCommandReturn: Bool {
		!reservedShortcuts.contains(Self.Shortcut.newTab)
			&& copyURLShortcut != Self.Shortcut.newTab
			&& openURLEntry != nil
	}

	/// The action ID ⌘↩ sends.
	public static let openURLID: String = "open-url"
}
