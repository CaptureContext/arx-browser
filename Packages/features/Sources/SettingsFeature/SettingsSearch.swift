import AppUI
import BrowserCore
import Foundation
import SwiftUI

/// A setting the sidebar's search can find: a row in a pane, a page inside a pane, or a sheet.
///
/// Each pane declares its own entries next to it (`SettingsCategory.searchIndex`), so the index
/// moves with the pane instead of drifting in a list kept somewhere else.
public struct SettingsSearchEntry: Identifiable, Equatable, Sendable {
	public let title: String

	/// Other words that find it, such as "MCP" or "alias".
	public let keywords: [String]

	/// The pane it lives in, which starts its path.
	public let category: SettingsCategory

	/// Steps between the pane and the setting, such as a section's title.
	public let trail: [String]
	public let destination: SettingsDestination

	public var id: SettingsDestination { destination }

	public init(
		_ title: String,
		keywords: [String] = [],
		in category: SettingsCategory,
		trail: [String] = [],
		destination: SettingsDestination
	) {
		self.title = title
		self.keywords = keywords
		self.category = category
		self.trail = trail
		self.destination = destination
	}

	/// Where it lives, ending with itself, such as "Advanced › Local assistants (MCP)". A pane's
	/// own entry has none.
	public var path: String? {
		if case .pane = destination { return nil }
		return ([category.title] + trail + [title]).joined(separator: " › ")
	}
}

/// Where choosing a search result goes.
public enum SettingsDestination: Hashable, Sendable {
	/// A pane, from its top.
	case pane(SettingsCategory)

	/// A row or section in a pane: Settings scrolls to it and highlights it briefly.
	case row(SettingsCategory, SettingsAnchor)

	/// A page inside a pane, such as Assistant › AI Commands.
	case page(SettingsPage)

	/// A sheet opened from a pane's row, which is highlighted under it.
	case panel(SettingsPanel, SettingsAnchor)

	/// Local assistants (MCP), which AppFeature presents.
	case automation

	/// The selected profile's Extensions sheet (DEV-801).
	case extensions

	/// The pane Settings shows for it.
	public var category: SettingsCategory {
		switch self {
		case let .pane(category), let .row(category, _): category
		case let .page(page): page.category
		case let .panel(panel, _): panel.category
		case .automation: .advanced
		case .extensions: .profiles
		}
	}

	/// The row Settings scrolls to and highlights, if any.
	public var anchor: SettingsAnchor? {
		switch self {
		case let .row(_, anchor), let .panel(_, anchor): anchor
		case .automation: .automation
		case .pane, .page, .extensions: nil
		}
	}
}

/// A page inside a pane, reached from a row with a chevron (`SettingsDrillDownRow`). A list that
/// grows with use has a page of its own, so its pane stays short (DEV-1114).
public enum SettingsPage: String, CaseIterable, Hashable, Sendable {
	/// Assistant › AI Commands: actions you'd run.
	case aiCommands

	/// Assistant › Assistant Features: how the assistant joins the rest of Arx.
	case assistantFeatures

	/// Profiles › a profile: the one `selectedProfileID` names.
	case profile

	/// General › Search Shortcuts: your shortcuts and the built-in bangs.
	case searchShortcuts

	/// Links › Proxy Links: the rules, in the order they win (DEV-1113).
	case proxyLinks

	/// Links › Air Traffic Control: the routes and their tester.
	case routing

	/// Links › App Links: which apps' links Arx handles (DEV-857).
	case appLinks

	/// Advanced › Sites kept loaded (DEV-932).
	case keptLoadedSites

	/// Advanced › WebKit sites: the sites that open in WebKit pages (DEV-877).
	case webKitSites

	/// Advanced › Feature Flags: every `ARX_*` feature flag with its toggle (DEV-1115).
	case featureFlags

	/// The pages this build shows.
	public static var available: [Self] {
		available(
			showingPendingOptions: showsPendingOptions,
			hasAICommands: hasAICommands
		)
	}

	/// The pages Settings lists, navigates to and searches: each only once it has something to
	/// show. Assistant Features holds only unfinished options, and AI Commands only unfinished
	/// commands until one works, so release builds, which hide unfinished options, leave both out
	/// rather than open an empty page (DEV-871).
	internal static func available(
		showingPendingOptions: Bool,
		hasAICommands: Bool
	) -> [Self] {
		allCases.filter { page in
			switch page {
			case .aiCommands: showingPendingOptions || hasAICommands
			case .assistantFeatures: showingPendingOptions
			case .profile, .searchShortcuts, .proxyLinks, .routing, .appLinks, .keptLoadedSites, .webKitSites, .featureFlags: true
			}
		}
	}

	/// Whether this build shows options that don't work yet, marked "Not yet available", for
	/// reviewing what's left: debug builds with the `ARX_PENDING_SETTINGS` feature flag on
	/// (DEV-871). Nothing in Settings does nothing otherwise.
	internal static var showsPendingOptions: Bool {
		#if DEBUG
		PendingSettingsFeatureFlag.isEnabled()
		#else
		false
		#endif
	}

	/// Whether any AI command works yet. None does: AI Commands lists them only in debug builds,
	/// as "Not yet available". Make this true with the first working command, which lists the
	/// page in release builds too.
	internal static let hasAICommands: Bool = false

	public var category: SettingsCategory {
		switch self {
		case .aiCommands, .assistantFeatures: .assistant
		case .profile: .profiles
		case .searchShortcuts: .general
		case .proxyLinks, .routing, .appLinks: .links
		case .keptLoadedSites, .webKitSites, .featureFlags: .advanced
		}
	}

	/// Whether the search index lists it: a profile's page depends on which profile.
	internal var isSearchable: Bool {
		self != .profile
	}

	public var title: String {
		switch self {
		case .aiCommands: String.localized(.appUI.settings.aiCommands)
		case .assistantFeatures: String.localized(.appUI.settings.assistantFeatures)
		case .profile: SettingsCategory.profiles.title
		case .searchShortcuts: String.localized(.appUI.settings.bangs)
		case .proxyLinks: String.localized(.appUI.links.proxyTitle)
		case .routing: String.localized(.appUI.settings.routing)
		case .appLinks: String.localized(.appUI.appLinks.section)
		case .keptLoadedSites: String.localized(.appUI.settings.keptLoadedSites)
		case .webKitSites: String.localized(.appUI.settings.webKitSites)
		case .featureFlags: String.localized(.appUI.featureFlags.title)
		}
	}

	internal var symbol: String {
		switch self {
		case .aiCommands: "wand.and.stars"
		case .assistantFeatures: "sparkles.rectangle.stack"
		case .profile: "person.crop.circle"
		case .searchShortcuts: "magnifyingglass"
		case .proxyLinks: "arrow.triangle.branch"
		case .routing: "airplane"
		case .appLinks: "app.badge"
		case .keptLoadedSites: "pin"
		case .webKitSites: "safari"
		case .featureFlags: "flag"
		}
	}
}

extension SettingsPanel {
	/// The pane whose row opens it.
	public var category: SettingsCategory {
		switch self {
		case .previews: .general
		}
	}
}

/// A row or section a search result can scroll to. Each is placed with `settingsAnchor(_:)`.
public enum SettingsAnchor: String, CaseIterable, Hashable, Sendable {
	// Arx
	case identityCard
	case defaultBrowser
	case memberNumber

	// Sync
	case iCloudSync

	// General
	case updates
	case warnBeforeQuitting
	case hoverPreviews
	case previews
	case unloadedSiteIcons
	case tabUnloading
	case batterySaver
	case translation
	case autofillAuthentication
	case contentBlocking
	case newTabPlacement

	/// New tabs open while `ARX_NEW_TABS_AT_TOP` is on: the New Tab button, ⌘T and ⌘K (DEV-1174).
	case openedTabPlacement
	case linkTabSwitching

	/// Open to an empty page at launch (DEV-1234).
	case emptyPageAtLaunch
	case unreadBadges
	case pictureInPicture
	case setupGuide

	// Profiles
	case profileList

	// Assistant
	case assistantProviders

	// Links (Proxy Links, Air Traffic Control and App Links are pages, DEV-1114)
	case littleArx
	case globalLittleArx
	case littleArxPosition
	case littleArxArchive
	case modifiedLinks
	case peek
	case forceClick
	case crossSitePeek
	case linkStatus

	/// Links › Air Traffic Control › Runway appearance.
	case runwayAppearance

	// Shortcuts
	case commands

	// Appearance
	case theme
	case darkPages
	case windowBackground
	case matchSite
	case sidebarPosition
	case sound
	case appIcon

	// Privacy
	case crashReports
	case reportProblem

	// Developer
	case developerMode
	case developerHeader
	case localTabHighlight

	// Advanced
	case automation
	case restoreWindows
	case haptics
	case webKitPages
	case protectedMedia
	case widevineAnswer
	case memoryTabUnloading
	case memoryPressureGrace
	case memoryPinnedTabs
	case backForwardCache
	case browserData
}

extension SettingsAnchor {
	/// Rows Settings leaves out while their feature flag is off: Translation (DEV-996) and
	/// archiving Little Arx windows (DEV-1138).
	public static var hiddenByFeatureFlags: Set<Self> {
		var hidden: Set<Self> = []
		if !PageTranslationFeatureFlag.isEnabled() { hidden.insert(.translation) }
		if !LittleArxAutoArchiveFeatureFlag.isEnabled() { hidden.insert(.littleArxArchive) }
		if !SettingsCategory.sync.isListed { hidden.insert(.iCloudSync) }
		return hidden
	}

	/// Where a result's row lands in the pane: centered, or at the top for a tall section whose
	/// start is what was found, such as Providers above every profile's chat settings.
	internal var scrollAlignment: UnitPoint {
		switch self {
		case .assistantProviders, .commands: .top
		default: .center
		}
	}
}

// MARK: - The index

extension SettingsCategory {
	/// What the sidebar's search finds in this pane: the pane itself, then what each pane
	/// declares beside its own view.
	@MainActor
	public var searchIndex: [SettingsSearchEntry] {
		let entries: [SettingsSearchEntry] = switch self {
		case .arx: SettingsView.arxSearchIndex

		case .general: SettingsView.generalSearchIndex

		case .profiles: SettingsProfilesView.searchIndex

		case .sync: SettingsView.syncSearchIndex

		case .assistant: SettingsView.assistantSearchIndex

		case .links: SettingsView.linksSearchIndex

		case .shortcuts: SettingsShortcutsView.searchIndex

		case .appearance: SettingsView.appearanceSearchIndex

		case .privacy: SettingsView.privacySearchIndex

		case .developer: SettingsView.developerSearchIndex

		case .advanced: SettingsView.advancedSearchIndex

		// Unlisted while it has no experiments, so nothing searches it.
		case .experimental: []
		}
		return [.init(title, keywords: [detail], in: self, destination: .pane(self))] + entries
	}

	/// Every pane's entries, in the sidebar's order.
	@MainActor
	public static var searchIndex: [SettingsSearchEntry] {
		available.flatMap { $0.searchIndex }
	}
}

extension SettingsSearchEntry {
	/// Keywords from one localized, comma-separated string.
	internal static func keywords(_ list: String) -> [String] {
		list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
	}
}

// MARK: - Matching

extension SettingsSearchEntry {
	/// How well `query` finds this entry, or nil when it doesn't. Lower is better.
	internal func rank(for query: String) -> Int? {
		let title = Self.fold(title)
		if title.hasPrefix(query) { return 0 }
		if Self.words(of: title).contains(where: { $0.hasPrefix(query) }) { return 1 }
		if title.contains(query) { return 2 }
		let keywords = keywords.map(Self.fold)
		if keywords.contains(where: { $0.hasPrefix(query) }) { return 3 }
		if keywords.contains(where: { Self.words(of: $0).contains { $0.hasPrefix(query) } }) { return 4 }
		if query.count >= 3, keywords.contains(where: { $0.contains(query) }) { return 5 }
		if let path, Self.words(of: Self.fold(path)).contains(where: { $0.hasPrefix(query) }) { return 6 }
		return nil
	}

	internal static func fold(_ text: String) -> String {
		text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
	}

	private static func words(of text: String) -> [Substring] {
		text.split { !$0.isLetter && !$0.isNumber }
	}
}

extension [SettingsSearchEntry] {
	/// The entries `query` finds, the best first; panes before the settings inside them on a tie.
	public func matching(_ query: String) -> [SettingsSearchEntry] {
		let query = SettingsSearchEntry.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
		guard !query.isEmpty else { return [] }
		return enumerated()
			.compactMap { offset, entry in entry.rank(for: query).map { (entry, $0, offset) } }
			.sorted { ($0.1, $0.2) < ($1.1, $1.2) }
			.map(\.0)
	}
}

// MARK: - Anchors in views

extension View {
	/// Marks a row or section a search result can scroll to, and highlights it while Settings
	/// shows that result.
	internal func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
		modifier(SettingsAnchorModifier(anchor: anchor))
	}
}

private struct SettingsAnchorModifier: ViewModifier {
	internal let anchor: SettingsAnchor

	@Environment(\.settingsHighlightedAnchor)
	private var highlighted: SettingsAnchor?

	internal func body(content: Content) -> some View {
		content
			.background {
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(.tint.opacity(highlighted == anchor ? 0.16 : 0))
					.padding(.horizontal, -8)
					.allowsHitTesting(false)
			}
			.animation(.easeOut(duration: 0.35), value: highlighted == anchor)
			.id(anchor)
			.transformPreference(SettingsAnchorsKey.self) { $0.insert(anchor) }
	}
}

/// The anchors a pane places, so tests can check that every search entry finds its row.
internal struct SettingsAnchorsKey: PreferenceKey {
	internal static let defaultValue: Set<SettingsAnchor> = []

	internal static func reduce(
		value: inout Set<SettingsAnchor>,
		nextValue: () -> Set<SettingsAnchor>
	) {
		value.formUnion(nextValue())
	}
}

extension EnvironmentValues {
	@Entry
	internal var settingsHighlightedAnchor: SettingsAnchor?
}

/// The `ARX_PENDING_SETTINGS` feature flag (DEV-871): debug builds list the options that don't
/// work yet. Read through `FeatureFlag`: on by default (DEV-1143), so debug builds list them
/// unless it's turned off; release builds never do.
internal enum PendingSettingsFeatureFlag {
	internal static let name: String = FeatureFlag.pendingSettings.name

	/// `0`, `false`, `no` or `off` turns it off; anything else, or nothing, leaves it on.
	internal static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.pendingSettings.isOn(environment: environment, defaults: defaults)
	}
}
