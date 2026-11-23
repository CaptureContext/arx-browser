import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var assistantSearchIndex: [SettingsSearchEntry] {
		assistantSearchIndex(listing: SettingsPage.available)
	}

	/// Assistant's entries: only the pages `pages` lists, so search never opens a page the pane
	/// leaves out.
	internal static func assistantSearchIndex(listing pages: [SettingsPage]) -> [SettingsSearchEntry] {
		var entries: [SettingsSearchEntry] = []
		if pages.contains(.aiCommands) {
			entries.append(
				.init(
					String.localized(.appUI.settings.aiCommands),
					keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.aiCommands)),
					in: .assistant,
					destination: .page(.aiCommands)
				)
			)
		}
		if pages.contains(.assistantFeatures) {
			entries.append(
				.init(
					String.localized(.appUI.settings.assistantFeatures),
					keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.assistantFeatures)),
					in: .assistant,
					destination: .page(.assistantFeatures)
				)
			)
		}
		entries.append(
			.init(
				String.localized(.appUI.chat.settingsProviders),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.providers)),
				in: .assistant,
				destination: .row(.assistant, .assistantProviders)
			)
		)
		return entries
	}

	/// Assistant: its pages first (AI Commands, Assistant Features), then the app's chat
	/// settings, Providers and Profiles.
	internal var assistantPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			Text(localized: .appUI.chat.settingsDescription)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
				.padding(.horizontal, 14)

			// Release builds list neither page while each holds only unfinished options.
			if !assistantPages.isEmpty {
				SettingsSection {
					ForEach(assistantPages, id: \.self) { page in
						pageRow(page)
					}
				}
			}
			if let assistant {
				// The app's chat settings start with Providers.
				assistant.settingsAnchor(.assistantProviders)
			}
		}
	}

	/// The pages the Assistant pane lists.
	private var assistantPages: [SettingsPage] {
		SettingsPage.available.filter { $0.category == .assistant }
	}

	/// A row that opens a page inside the pane (DEV-1114): its title, what it holds and a chevron.
	internal func pageRow(_ page: SettingsPage) -> some View {
		SettingsDrillDownRow(page.title, symbol: page.symbol, summary: pageSummary(page)) {
			store.send(.ui(.pagePresented(page)))
		}
	}

	/// What a page holds, as its row shows it: a count for a list.
	private func pageSummary(_ page: SettingsPage) -> String? {
		switch page {
		case .aiCommands, .assistantFeatures:
			String.localized(.appUI.settings.aiCommandsComing)
		case .profile:
			nil
		case .searchShortcuts:
			String.localized(.appUI.settings.shortcutCount(store.searchShortcuts.count))
		case .proxyLinks:
			String.localized(.appUI.links.ruleCount(store.proxyLinkRules.count))
		case .routing:
			String.localized(.appUI.routing.routeCount(store.routingPreferences.rules.count))
		case .appLinks:
			String.localized(.appUI.appLinks.handlerCount(store.routingPreferences.appLinks.handlers.count))
		case .keptLoadedSites:
			String.localized(.appUI.settings.siteCount(
				organization.profiles.reduce(0) { $0 + ($1.keptLoadedSites?.count ?? 0) }
			))
		case .webKitSites:
			String.localized(.appUI.settings.siteCount(store.webKitPages.sites.count))
		case .featureFlags:
			nil
		}
	}

	@ViewBuilder
	internal func pageContent(_ page: SettingsPage) -> some View {
		switch page {
		case .aiCommands: aiCommandsPage
		case .assistantFeatures: assistantFeaturesPage
		case .profile: SettingsProfileView(store: store, organization: organization)
		case .searchShortcuts: SearchShortcutsSettingsView(store: store)
		case .proxyLinks: ProxyLinksSettingsView(store: store)
		case .routing: RoutingSettingsView(store: store, organization: organization, context: routingContext)
		case .appLinks: AppLinkSettingsView(store: store, organization: organization)
		case .keptLoadedSites: SettingsKeptLoadedSitesView(store: store, organization: organization)
		case .webKitSites: SettingsWebKitSitesView(store: store)
		case .featureFlags: SettingsFeatureFlagsView(store: store)
		}
	}

	/// Assistant › AI Commands: actions you'd run, none available yet. Debug builds list them;
	/// release builds don't list the page until one works (`SettingsPage.hasAICommands`).
	private var aiCommandsPage: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			#if DEBUG
			if SettingsPage.showsPendingOptions {
				SettingsSection(caption: String.localized(.appUI.settings.aiCommandsList)) {
					SettingsPendingRow(String.localized(.appUI.settings.organizeTabs), symbol: "square.stack.3d.up")
					SettingsPendingRow(String.localized(.appUI.settings.tidyTabs), symbol: "pin")
					SettingsPendingRow(String.localized(.appUI.settings.tidyDownloads), symbol: "arrow.down.doc")
					SettingsPendingRow(String.localized(.appUI.settings.linkSummaries), symbol: "text.bubble")
					SettingsPendingRow(String.localized(.appUI.settings.instantSearch), symbol: "magnifyingglass")
				}
			}
			#endif
		}
	}

	/// Assistant › Assistant Features: how the assistant joins the rest of Arx. Debug builds only.
	@ViewBuilder
	private var assistantFeaturesPage: some View {
		#if DEBUG
		if SettingsPage.showsPendingOptions {
			SettingsSection(caption: String.localized(.appUI.settings.assistantFeaturesDetail)) {
				SettingsPendingRow(String.localized(.appUI.settings.assistantSearch), symbol: "magnifyingglass")
				SettingsPendingRow(String.localized(.appUI.settings.futureAi), symbol: "sparkles")
			}
		}
		#endif
	}
}
