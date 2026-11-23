import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var linksSearchIndex: [SettingsSearchEntry] {
		let littleArx = String.localized(.appUI.settings.section.littleArx)
		let peek = String.localized(.appUI.settings.peek)
		return [
			.init(
				String.localized(.appUI.links.proxyTitle),
				keywords: [String.localized(.appUI.links.restoreDefaults), SettingsAddTarget.proxyLinkRule.title],
				in: .links,
				destination: .page(.proxyLinks)
			),
			.init(
				littleArx,
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.littleArx))
					+ [String.localized(.appUI.settings.littleShortcut)],
				in: .links,
				destination: .row(.links, .littleArx)
			),
			.init(
				String.localized(.appUI.settings.globalShortcut),
				in: .links,
				trail: [littleArx],
				destination: .row(.links, .globalLittleArx)
			),
			.init(
				String.localized(.appUI.settings.littleBarPosition),
				in: .links,
				trail: [littleArx],
				destination: .row(.links, .littleArxPosition)
			),
			.init(
				String.localized(.appUI.settings.modifiedLinks),
				in: .links,
				trail: [littleArx],
				destination: .row(.links, .modifiedLinks)
			),
			.init(
				peek,
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.peek))
					+ [String.localized(.appUI.settings.shiftClickLinks)],
				in: .links,
				destination: .row(.links, .peek)
			),
			.init(
				String.localized(.appUI.settings.forceClickLinks),
				in: .links,
				trail: [peek],
				destination: .row(.links, .forceClick)
			),
			.init(
				String.localized(.appUI.settings.crossSiteLinksFavorites),
				keywords: [String.localized(.appUI.settings.crossSiteLinksPinned)],
				in: .links,
				trail: [peek],
				destination: .row(.links, .crossSitePeek)
			),
			.init(
				String.localized(.appUI.settings.linkStatus),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.linkStatus)),
				in: .links,
				destination: .row(.links, .linkStatus)
			),
			.init(
				String.localized(.appUI.settings.routing),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.routing))
					+ [SettingsAddTarget.route.title],
				in: .links,
				destination: .page(.routing)
			),
			.init(
				String.localized(.appUI.appLinks.section),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.appLinks))
					+ [SettingsAddTarget.appLink.title],
				in: .links,
				trail: [String.localized(.appUI.settings.routing)],
				destination: .page(.appLinks)
			),
			.init(
				String.localized(.appUI.settings.runwayAppearance),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.runwayAppearance)),
				in: .links,
				trail: [String.localized(.appUI.settings.routing)],
				destination: .row(.links, .runwayAppearance)
			),
		] + (LittleArxAutoArchiveFeatureFlag.isEnabled() ? [
			// DEV-1138: only while its feature flag shows the row.
			SettingsSearchEntry(
				String.localized(.appUI.settings.archiveLittle),
				in: .links,
				trail: [littleArx],
				destination: .row(.links, .littleArxArchive)
			),
		] : [])
	}

	internal var linksPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			VStack(alignment: .leading, spacing: 16) {
				SettingsSection(caption: String.localized(.appUI.links.proxySummary)) {
					pageRow(.proxyLinks)
				}
				DisclosureGroup(String.localized(.appUI.links.cleanRules)) {
					VStack(alignment: .leading, spacing: 8) {
						Text(localized: .appUI.links.cleanDescription)
						Text(ProxyLinksSettingsView.cleanRulesSummary(.bundled))
							.font(.caption.monospaced()).textSelection(.enabled)
					}
					.padding(.vertical, 8)
				}
			}
			SettingsSection(
				String.localized(.appUI.settings.section.littleArx),
				caption: String.localized(.appUI.settings.littleDescription)
			) {
				if let shortcut = shortcuts.first(where: { $0.id == "littleArx" }) {
					SettingsRow(String.localized(.appUI.settings.littleShortcut)) {
						Text(shortcut.keys).font(.body.monospaced())
					}
				}
				SettingsToggle(
					String.localized(.appUI.settings.globalShortcut),
					detail: store.globalShortcutMessage ?? String.localized(.appUI.settings.globalShortcutExplanation),
					isOn: Binding(
						get: { store.linkClicks.globalLittleArxEnabled },
						set: { store.send(.ui(.globalLittleArxEnabled($0))) }
					)
				)
				.settingsAnchor(.globalLittleArx)
				SettingsRow(String.localized(.appUI.settings.littleBarPosition)) {
					Picker(
						String.localized(.appUI.settings.littleBarPosition),
						selection: Binding(
							get: { store.linkClicks.littleArxLauncherPosition },
							set: { store.send(.ui(.littleArxLauncherPosition($0))) }
						)
					) {
						Text(localized: .appUI.settings.positionTopRight).tag(LittleArxLauncherPosition.topRight)
						Text(localized: .appUI.settings.positionTopCenter).tag(LittleArxLauncherPosition.topCenter)
						Text(localized: .appUI.settings.positionTopLeft).tag(LittleArxLauncherPosition.topLeft)
						Text(localized: .appUI.settings.positionCenter).tag(LittleArxLauncherPosition.center)
					}
					.labelsHidden()
					.fixedSize()
				}
				.settingsAnchor(.littleArxPosition)
				SettingsRow(String.localized(.appUI.settings.modifiedLinks)) {
					Picker(
						String.localized(.appUI.settings.modifiedLinks),
						selection: Binding(
							get: { store.linkClicks.littleArxLinkBinding },
							set: { store.send(.ui(.littleArxLinkBinding($0))) }
						)
					) {
						Text(verbatim: "⌥⌘ Click").tag(LittleArxLinkBinding.optionCommand)
						Text(verbatim: "⇧⌥⌘ Click").tag(LittleArxLinkBinding.shiftOptionCommand)
						Text(localized: .appUI.settings.linkClickOff).tag(LittleArxLinkBinding.off)
					}
					.labelsHidden()
					.fixedSize()
				}
				.settingsAnchor(.modifiedLinks)
				if LittleArxAutoArchiveFeatureFlag.isEnabled() {
					SettingsRow(
						String.localized(.appUI.settings.archiveLittle),
						detail: String.localized(.appUI.settings.archiveLittleExplanation)
					) {
						Picker(
							String.localized(.appUI.settings.archiveLittle),
							selection: Binding(
								get: { store.linkClicks.littleArxArchiveInterval },
								set: { store.send(.ui(.littleArxArchiveInterval($0))) }
							)
						) {
							Text(localized: .appUI.settings.archiveNever).tag(LittleArxArchiveInterval?.none)
							ForEach(LittleArxArchiveInterval.allCases, id: \.self) { interval in
								Text(interval.title).tag(Optional(interval))
							}
						}
						.labelsHidden()
						.fixedSize()
					}
					.settingsAnchor(.littleArxArchive)
				}
			}
			.settingsAnchor(.littleArx)
			SettingsSection(
				String.localized(.appUI.settings.peek),
				caption: String.localized(.appUI.settings.peekDescription)
			) {
				SettingsRow(String.localized(.appUI.settings.shiftClickLinks)) {
					Picker(
						String.localized(.appUI.settings.shiftClickLinks),
						selection: Binding(
							get: { store.linkClicks.shiftClickLinkAction },
							set: { store.send(.ui(.shiftClickLinkAction($0))) }
						)
					) {
						Text(localized: .appUI.settings.peek).tag(ShiftClickLinkAction.peek)
						Text(localized: .appUI.routing.littleArx).tag(ShiftClickLinkAction.littleArx)
						Text(localized: .appUI.settings.linkClickNewTab).tag(ShiftClickLinkAction.newTab)
						Text(localized: .appUI.settings.linkClickNewWindow).tag(ShiftClickLinkAction.newWindow)
					}
					.labelsHidden()
					.fixedSize()
				}
				.settingsAnchor(.peek)
				SettingsRow(String.localized(.appUI.settings.forceClickLinks)) {
					Picker(
						String.localized(.appUI.settings.forceClickLinks),
						selection: Binding(
							get: { store.linkClicks.forceClickLinkAction },
							set: { store.send(.ui(.forceClickLinkAction($0))) }
						)
					) {
						Text(localized: .appUI.settings.peek).tag(ForceClickLinkAction.peek)
						Text(localized: .appUI.routing.littleArx).tag(ForceClickLinkAction.littleArx)
						Text(localized: .appUI.settings.linkClickNewTab).tag(ForceClickLinkAction.newTab)
						Text(localized: .appUI.settings.linkClickLookUp).tag(ForceClickLinkAction.off)
					}
					.labelsHidden()
					.fixedSize()
				}
				.settingsAnchor(.forceClick)
				SettingsRow(String.localized(.appUI.settings.crossSiteLinksFavorites)) {
					Picker(
						String.localized(.appUI.settings.crossSiteLinksFavorites),
						selection: Binding(
							get: { store.linkClicks.crossSiteLinkFromFavorites },
							set: { store.send(.ui(.crossSiteLinkFromFavorites($0))) }
						)
					) {
						Text(localized: .appUI.settings.peek).tag(CrossSiteLinkAction.peek)
						Text(localized: .appUI.routing.littleArx).tag(CrossSiteLinkAction.littleArx)
						Text(localized: .appUI.settings.linkClickNewTab).tag(CrossSiteLinkAction.newTab)
						Text(localized: .appUI.settings.linkClickCurrentTab).tag(CrossSiteLinkAction.currentTab)
					}
					.labelsHidden()
					.fixedSize()
				}
				.settingsAnchor(.crossSitePeek)
				SettingsRow(String.localized(.appUI.settings.crossSiteLinksPinned)) {
					Picker(
						String.localized(.appUI.settings.crossSiteLinksPinned),
						selection: Binding(
							get: { store.linkClicks.crossSiteLinkFromPinnedTabs },
							set: { store.send(.ui(.crossSiteLinkFromPinnedTabs($0))) }
						)
					) {
						Text(localized: .appUI.settings.peek).tag(CrossSiteLinkAction.peek)
						Text(localized: .appUI.routing.littleArx).tag(CrossSiteLinkAction.littleArx)
						Text(localized: .appUI.settings.linkClickNewTab).tag(CrossSiteLinkAction.newTab)
						Text(localized: .appUI.settings.linkClickCurrentTab).tag(CrossSiteLinkAction.currentTab)
					}
					.labelsHidden()
					.fixedSize()
				}
			}
			if store.linkStatusAvailable {
				SettingsSection(
					String.localized(.appUI.settings.section.linkStatus),
					caption: String.localized(.appUI.settings.linkStatusDescription)
				) {
					SettingsToggle(
						String.localized(.appUI.settings.linkStatus),
						isOn: Binding(
							get: { store.linkClicks.showsLinkStatus },
							set: { store.send(.ui(.showsLinkStatus($0))) }
						)
					)
					.settingsAnchor(.linkStatus)
				}
			}
			SettingsSection(
				String.localized(.appUI.settings.routing),
				caption: String.localized(.appUI.settings.routingDescription)
			) {
				pageRow(.routing)
				pageRow(.appLinks)
				SettingsRow(
					String.localized(.appUI.settings.runwayAppearance),
					detail: String.localized(.appUI.settings.runwayAppearanceExplanation)
				) {
					Picker(
						String.localized(.appUI.settings.runwayAppearance),
						selection: Binding(
							get: { store.linkClicks.runwayAppearance },
							set: { store.send(.ui(.runwayAppearance($0))) }
						)
					) {
						Text(localized: .appUI.settings.runwayRegular).tag(RunwayAppearance.regular)
						Text(localized: .appUI.settings.runwayCompact).tag(RunwayAppearance.compact)
					}
					.labelsHidden()
					.fixedSize()
				}
				.settingsAnchor(.runwayAppearance)
			}
		}
	}

	/// The browser default for unread badges (DEV-907, DEV-1258), then the sites that choose for
	/// themselves in their site menu, each with Use Default.
	@ViewBuilder
	internal var unreadBadgesRow: some View {
		SettingsToggle(
			String.localized(.appUI.settings.showsUnreadBadges),
			detail: String.localized(.appUI.settings.showsUnreadBadgesDetail),
			isOn: Binding(
				get: { store.general.showsUnreadBadges },
				set: { store.send(.ui(.showsUnreadBadges($0))) }
			)
		)
		.settingsAnchor(.unreadBadges)
		let sites = store.unreadBadgeOverrides.sortedSites
		if !sites.isEmpty {
			SettingsRow(
				String.localized(.appUI.settings.unreadBadgeSites),
				detail: String.localized(.appUI.settings.unreadBadgeSitesDetail)
			) {}
			ForEach(sites, id: \.host) { site in
				SettingsRow(site.host, detail: site.visibility.title) {
					Button(String.localized(.appUI.settings.unreadBadgeSiteReset)) {
						store.send(.ui(.resetUnreadBadgeSite(site.host)))
					}
				}
			}
		}
	}
}

extension LittleArxArchiveInterval {
	fileprivate var title: String {
		switch self {
		case .fifteenMinutes: String.localized(.appUI.settings.archiveAfterFifteenMinutes)
		case .hour: String.localized(.appUI.settings.archiveAfterHour)
		case .twelveHours: String.localized(.appUI.settings.archiveAfterTwelveHours)
		case .day: String.localized(.appUI.settings.archiveAfterDay)
		}
	}
}
