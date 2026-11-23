import BrowserCore
import Dependencies
import Foundation
import Sharing

/// One preference domain inside the workspace file, such as routing or the chrome appearance.
///
/// Keys never write the file themselves: they edit ``WorkspaceDocument``, and AppFeature saves the
/// document on its own schedule. Keys for different domains notify each other only when their own
/// slice changed, so editing routing doesn't invalidate views that read the appearance.
///
/// Validated domains (routing, shortcuts, proxy links, appearance ranges) are written only from
/// reducers after validation, never through a view binding: an invalid value makes every later save fail.
public struct WorkspacePreferenceKey<Value: Equatable & Sendable>: SharedKey {
	public struct ID: Hashable, Sendable {
		fileprivate let document: ObjectIdentifier
		fileprivate let keyPath: AnyKeyPath & Sendable
	}

	private let document: WorkspaceDocument
	private let keyPath: WritableKeyPath<BrowserPreferences, Value> & Sendable

	public init(_ keyPath: WritableKeyPath<BrowserPreferences, Value> & Sendable) {
		@Dependency(\.workspaceDocument)
		var document

		self.document = document
		self.keyPath = keyPath
	}

	public var id: ID {
		.init(document: ObjectIdentifier(document), keyPath: keyPath)
	}

	public func load(
		context: LoadContext<Value>,
		continuation: LoadContinuation<Value>
	) {
		continuation.resume(returning: document.preferences[keyPath: keyPath])
	}

	public func subscribe(
		context: LoadContext<Value>,
		subscriber: SharedSubscriber<Value>
	) -> SharedSubscription {
		let keyPath = keyPath
		let cancel = document.observe(origin: id) { old, new in
			let value = new.preferences[keyPath: keyPath]

			// Sharing sets the value unconditionally, so a no-op yield would still invalidate views.
			guard old.preferences[keyPath: keyPath] != value else { return }

			subscriber.yield(value)
		}
		return .init(cancel)
	}

	public func save(
		_ value: Value,
		context: SaveContext,
		continuation: SaveContinuation
	) {
		let keyPath = keyPath
		document.updatePreferences(origin: id) { $0[keyPath: keyPath] = value }

		switch context {
		case .didSet:
			continuation.resume()

		case .userInitiated:
			Task { [document] in
				do {
					try await document.flush()
					continuation.resume()
				} catch {
					continuation.resume(throwing: error)
				}
			}
		}
	}
}

extension WorkspacePreferenceKey: CustomStringConvertible {
	public var description: String {
		".workspacePreference(\(keyPath))"
	}
}

// MARK: - Keys

extension SharedKey {
	/// A preference domain by key path. Declare named domains below rather than using this at call sites.
	public static func workspacePreference<Value>(
		_ keyPath: WritableKeyPath<BrowserPreferences, Value> & Sendable
	) -> Self where Self == WorkspacePreferenceKey<Value>.Default {
		Self[WorkspacePreferenceKey(keyPath), default: BrowserPreferences()[keyPath: keyPath]]
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<ChromeAppearance>.Default {
	/// The app-wide chrome tint and grain. Profiles and spaces override it in the organization;
	/// read what a space shows through `.chromeAppearance(space:)`.
	public static var chromeAppearance: Self {
		.workspacePreference(\.chromeAppearance)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[SearchShortcut]>.Default {
	/// The user's search shortcuts, consulted before Helium's bundled !bangs.
	/// Validated: write it only from a reducer, after `BrowserPreferences.validate()`.
	public static var searchShortcuts: Self {
		.workspacePreference(\.searchShortcuts)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<RoutingPreferences>.Default {
	/// Air Traffic Control: rules, the fallback and each profile's default space.
	/// Validated, and its destinations name profiles and spaces: write it only from a reducer.
	public static var routing: Self {
		.workspacePreference(\.routing)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[ProxyLinkRule]>.Default {
	/// Proxy Link rules for copied and shared links. Validated: write it only from a reducer.
	public static var proxyLinkRules: Self {
		.workspacePreference(\.proxyLinkRules)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[UUID]>.Default {
	/// The default Proxy Link rules the person deleted, so no Mac offers them again (DEV-1113).
	/// Sorted; write it only from a reducer.
	public static var removedProxyLinkDefaults: Self {
		.workspacePreference(\.removedProxyLinkDefaults)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[ShortcutBinding]>.Default {
	/// The user's keyboard shortcut overrides; commands without one use their defaults.
	/// Validated: write it only from a reducer.
	public static var keyboardShortcuts: Self {
		.workspacePreference(\.keyboardShortcuts)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[CommandAlias]>.Default {
	/// Words that find commands in the command bar. Validated: write it only from a reducer.
	public static var commandAliases: Self {
		.workspacePreference(\.commandAliases)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[ShortcutConflictOverride]>.Default {
	/// Conflict resolution per command (DEV-1332), only where it differs from the default.
	/// Write it only from a reducer.
	public static var shortcutConflictChoices: Self {
		.workspacePreference(\.shortcutConflictChoices)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<LinkClickPreferences>.Default {
	/// Shift-click Peek, the Little Arx link binding and launcher, Force Click and the global shortcut switch.
	public static var linkClicks: Self {
		.workspacePreference(\.linkClicks)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<GeneralPreferences>.Default {
	/// Quit warnings, developer mode and the identity card style.
	public static var general: Self {
		.workspacePreference(\.general)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<AutomaticPiPPreferences>.Default {
	/// Automatic Picture in Picture, its per-site choices and whether it closes on return.
	public static var automaticPictureInPicture: Self {
		.workspacePreference(\.automaticPictureInPicture)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<WindowPreferences>.Default {
	/// Saved window layouts and the sidebar width new windows start with. Stays on this Mac.
	public static var windows: Self {
		.workspacePreference(\.windows)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<[Tab.ID: Date]>.Default {
	/// When unpinned tabs were last on screen, for automatic archiving. Stays on this Mac.
	public static var tabsLastViewed: Self {
		.workspacePreference(\.tabsLastViewed)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<UnreadBadgeOverrides>.Default {
	/// The site and tab levels of unread badges (DEV-1258). Stays on this Mac.
	public static var unreadBadgeOverrides: Self {
		.workspacePreference(\.unreadBadgeOverrides)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<OnboardingPreferences>.Default {
	/// Whether the introduction was dismissed and which setup steps are done. Stays on this Mac.
	public static var onboarding: Self {
		.workspacePreference(\.onboarding)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<Date?>.Default {
	/// When this Arx was first installed on this Mac (DEV-1323), for the identity card's "Member
	/// since". AppFeature records it once at launch; stays on this Mac.
	public static var installDate: Self {
		.workspacePreference(\.installedAt)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<MigrationLedger>.Default {
	/// What this Mac already imported. Commits pair it with the organization: write it only
	/// through a migration commit, which updates both in one document transaction.
	public static var migrationLedger: Self {
		.workspacePreference(\.migrationLedger)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<ExperimentalPreferences>.Default {
	/// Opt-in experiments from Settings' Experimental pane, such as the chat panel's style.
	public static var experiments: Self {
		.workspacePreference(\.experiments)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<NewTabPlacement>.Default {
	/// Where new tabs open among a space's open tabs (DEV-913): only tabs links open while
	/// `ARX_NEW_TABS_AT_TOP` is on (DEV-1174).
	public static var newTabPlacement: Self {
		.workspacePreference(\.newTabPlacement)
	}

	/// Where a tab from the New Tab button, ⌘T or ⌘K opens while `ARX_NEW_TABS_AT_TOP` is on
	/// (DEV-1174).
	public static var openedTabPlacement: Self {
		.workspacePreference(\.openedTabPlacement)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<WebKitPagePreferences>.Default {
	/// Settings › Advanced › WebKit: the sites that open in WebKit pages and the declined
	/// fallback prompts (DEV-877).
	public static var webKitPages: Self {
		.workspacePreference(\.webKitPages)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<BatterySaverMode>.Default {
	/// Settings › General › Battery Saver (DEV-915).
	public static var batterySaver: Self {
		.workspacePreference(\.batterySaver)
	}
}

extension SharedKey where Self == WorkspacePreferenceKey<TranslationPreferences>.Default {
	/// Each profile's Never translate sites and Always translate languages (DEV-904).
	public static var translation: Self {
		.workspacePreference(\.translation)
	}
}
