import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var advancedSearchIndex: [SettingsSearchEntry] {
		let memory = String.localized(.appUI.settings.section.memory)
		return [
			.init(
				String.localized(.appUI.automation.title),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.automation)),
				in: .advanced,
				destination: .automation
			),
			.init(
				String.localized(.appUI.settings.restoreWindows),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.restoreWindows)),
				in: .advanced,
				trail: [String.localized(.appUI.settings.section.windows)],
				destination: .row(.advanced, .restoreWindows)
			),
			.init(
				String.localized(.appUI.settings.haptics),
				in: .advanced,
				destination: .row(.advanced, .haptics)
			),
			.init(
				String.localized(.appUI.settings.section.webKit),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.webKit)),
				in: .advanced,
				destination: .row(.advanced, .webKitPages)
			),
			.init(
				String.localized(.appUI.featureFlags.title),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.featureFlags))
					+ FeatureFlag.allCases.flatMap { [$0.title, $0.name] },
				in: .advanced,
				destination: .page(.featureFlags)
			),
			.init(
				String.localized(.appUI.settings.webKitSites),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.webKitSites))
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.webKit))
					+ [SettingsAddTarget.webKitSite.title],
				in: .advanced,
				trail: [String.localized(.appUI.settings.section.webKit)],
				destination: .page(.webKitSites)
			),
			.init(
				String.localized(.appUI.settings.protectedMedia),
				keywords: [String.localized(.appUI.settings.protectedMediaExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.protectedMedia)),
				in: .advanced,
				trail: [String.localized(.appUI.settings.section.webKit)],
				destination: .row(.advanced, .protectedMedia)
			),
			.init(
				String.localized(.appUI.settings.widevineAnswer),
				keywords: [String.localized(.appUI.settings.widevineAnswerExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.widevineAnswer)),
				in: .advanced,
				trail: [String.localized(.appUI.settings.section.webKit)],
				destination: .row(.advanced, .widevineAnswer)
			),
			.init(
				String.localized(.appUI.settings.tabUnloading),
				keywords: [String.localized(.appUI.settings.tabUnloadingExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.tabUnloading)),
				in: .advanced,
				trail: [memory],
				destination: .row(.advanced, .memoryTabUnloading)
			),
			.init(
				String.localized(.appUI.settings.tabUnloadPressureGrace),
				keywords: [String.localized(.appUI.settings.tabUnloadPressureGraceExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.tabUnloading)),
				in: .advanced,
				trail: [memory],
				destination: .row(.advanced, .memoryPressureGrace)
			),
			.init(
				String.localized(.appUI.settings.keptLoadedSites),
				keywords: [String.localized(.appUI.settings.keptLoadedSitesExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.tabUnloading))
					+ [SettingsAddTarget.keptLoadedSite.title],
				in: .advanced,
				trail: [memory],
				destination: .page(.keptLoadedSites)
			),
			.init(
				String.localized(.appUI.settings.keepPinnedTabsLoaded),
				keywords: [String.localized(.appUI.settings.keepPinnedTabsLoadedExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.tabUnloading)),
				in: .advanced,
				trail: [memory],
				destination: .row(.advanced, .memoryPinnedTabs)
			),
			.init(
				String.localized(.appUI.settings.backForwardCache),
				keywords: [String.localized(.appUI.settings.backForwardCacheExplanation)]
					+ SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.backForwardCache)),
				in: .advanced,
				trail: [memory],
				destination: .row(.advanced, .backForwardCache)
			),
			.init(
				String.localized(.appUI.settings.section.browserData),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.browserData)),
				in: .advanced,
				destination: .row(.advanced, .browserData)
			),
		]
	}

	internal var advancedPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			SettingsSection {
				SettingsRow(String.localized(.appUI.automation.title)) {
					Button(String.localized(.appUI.automation.manage), action: openAutomation)
				}
				.settingsAnchor(.automation)
			}
			SettingsSection(
				String.localized(.appUI.settings.section.windows),
				footer: String.localized(.appUI.settings.restoreWindowsExplanation)
			) {
				SettingsToggle(
					String.localized(.appUI.settings.restoreWindows),
					isOn: Binding(
						get: { store.general.restoresWindowsAtStartup },
						set: { store.send(.ui(.restoresWindowsAtStartup($0))) }
					)
				)
				.settingsAnchor(.restoreWindows)
			}
			SettingsSection(footer: String.localized(.appUI.settings.hapticsExplanation)) {
				SettingsToggle(
					String.localized(.appUI.settings.haptics),
					isOn: Binding(
						get: { store.general.hapticsEnabled },
						set: { store.send(.ui(.hapticsEnabled($0))) }
					)
				)
				.settingsAnchor(.haptics)
			}
			memorySection
			keptLoadedSection
			#if DEBUG
			if SettingsPage.showsPendingOptions {
				SettingsPendingGroup([
					String.localized(.appUI.settings.dragPage),
					String.localized(.appUI.settings.quotes),
					String.localized(.appUI.settings.themeData),
					String.localized(.appUI.settings.boosts),
					String.localized(.appUI.settings.engineSettings),
				])
			}
			#endif
			SettingsWebKitPagesSection(store: store) {
				pageRow(.webKitSites)
			}
			SettingsSection(footer: String.localized(.appUI.featureFlags.rowFooter)) {
				pageRow(.featureFlags)
			}
			browserDataSection
				.settingsAnchor(.browserData)
		}
	}

	/// Keep pinned tabs loaded, and the row that opens the sites kept loaded (DEV-932, DEV-1114).
	private var keptLoadedSection: some View {
		SettingsSection(String.localized(.appUI.settings.keptLoadedSites)) {
			SettingsToggle(
				String.localized(.appUI.settings.keepPinnedTabsLoaded),
				detail: String.localized(.appUI.settings.keepPinnedTabsLoadedExplanation),
				isOn: Binding(
					get: { store.general.keepsPinnedTabsLoaded },
					set: { store.send(.ui(.keepsPinnedTabsLoaded($0))) }
				)
			)
			.settingsAnchor(.memoryPinnedTabs)
			pageRow(.keptLoadedSites)
		}
	}

	/// What Arx keeps in memory (DEV-873, DEV-943): when hidden tabs unload, also in General ›
	/// Tabs, how long low memory waits before unloading them, and the back/forward cache.
	private var memorySection: some View {
		SettingsSection(
			String.localized(.appUI.settings.section.memory),
			footer: String.localized(.appUI.settings.memoryNote)
		) {
			tabUnloadDelayRow
				.settingsAnchor(.memoryTabUnloading)
			SettingsRow(
				String.localized(.appUI.settings.tabUnloadPressureGrace),
				detail: String.localized(.appUI.settings.tabUnloadPressureGraceExplanation)
			) {
				Picker(
					String.localized(.appUI.settings.tabUnloadPressureGrace),
					selection: Binding(
						get: { store.general.tabUnloadPressureGrace },
						set: { store.send(.ui(.tabUnloadPressureGrace($0))) }
					)
				) {
					ForEach(TabUnloadPressureGrace.allCases, id: \.self) { grace in
						Text(grace.title).tag(grace)
					}
				}
				.labelsHidden()
				.fixedSize()
			}
			.settingsAnchor(.memoryPressureGrace)
			SettingsRow(
				String.localized(.appUI.settings.backForwardCache),
				detail: backForwardCacheDetail
			) {
				Picker(
					String.localized(.appUI.settings.backForwardCache),
					selection: Binding(
						get: { store.backForwardCachePages },
						set: { store.send(.ui(.backForwardCachePages($0))) }
					)
				) {
					ForEach(Array(BackForwardCachePages.counts), id: \.self) { count in
						Text(Self.backForwardCacheTitle(count)).tag(count)
					}
				}
				.labelsHidden()
				.fixedSize()
			}
			.settingsAnchor(.backForwardCache)
		}
	}

	/// The explanation, and once the number changed, that it applies from the next launch.
	private var backForwardCacheDetail: String {
		let explanation = String.localized(.appUI.settings.backForwardCacheExplanation)
		guard store.backForwardCachePages != store.backForwardCachePagesAtLaunch
		else { return explanation }

		return explanation + "\n" + String.localized(.appUI.settings.backForwardCacheNextLaunch)
	}

	private static func backForwardCacheTitle(_ count: Int) -> String {
		switch count {
		case 0: String.localized(.appUI.settings.backForwardCacheOff)
		default: String.localized(.appUI.settings.backForwardCachePageCount(count))
		}
	}

	/// Unload inactive tabs, in General › Tabs and Advanced › Memory alike (DEV-873).
	internal var tabUnloadDelayRow: some View {
		SettingsRow(
			String.localized(.appUI.settings.tabUnloading),
			detail: String.localized(.appUI.settings.tabUnloadingExplanation)
		) {
			Picker(
				String.localized(.appUI.settings.tabUnloading),
				selection: Binding(
					get: { store.general.tabUnloadDelay },
					set: { store.send(.ui(.tabUnloadDelay($0))) }
				)
			) {
				ForEach(TabUnloadDelay.allCases, id: \.self) { delay in
					Text(delay.title).tag(delay)
				}
			}
			.labelsHidden()
			.fixedSize()
		}
	}

	/// Import and export, with what an archive includes and an export's progress.
	private var browserDataSection: some View {
		SettingsSection(
			String.localized(.appUI.settings.section.browserData),
			footer: String.localized(.appUI.settings.browserDataNote)
		) {
			SettingsRow(String.localized(.appUI.settings.browserData)) {
				Button(String.localized(.appUI.settings.importData), action: importData)
				Button(String.localized(.appUI.settings.exportBookmarks), action: exportBookmarks)
				Button(String.localized(.appUI.settings.exportArchive), action: exportArchive)
			}
			.disabled(browserDataExport.progress != nil)
			SettingsToggle(
				String.localized(.appUI.settings.exportIncludesHistory),
				isOn: Binding(
					get: { browserDataExport.includesHistory },
					set: { browserDataExport.setIncludesHistory($0) }
				)
			)
			.disabled(browserDataExport.progress != nil)
			SettingsToggle(
				String.localized(.appUI.settings.exportIncludesArchivedTabs),
				isOn: Binding(
					get: { browserDataExport.includesArchivedTabs },
					set: { browserDataExport.setIncludesArchivedTabs($0) }
				)
			)
			.disabled(browserDataExport.progress != nil)
			if let progress = browserDataExport.progress {
				HStack {
					ProgressView(value: progress) {
						Text(localized: .appUI.settings.exporting)
					}
					Button(String.localized(.appUI.settings.cancelExport), action: browserDataExport.cancel)
				}
				.settingsRow()
			}
		}
	}
}

extension TabUnloadPressureGrace {
	fileprivate var title: String {
		switch self {
		case .thirtySeconds: String.localized(.appUI.settings.tabUnloadPressureAfterThirtySeconds)
		case .oneMinute: String.localized(.appUI.settings.tabUnloadPressureAfterOneMinute)
		case .twoMinutes: String.localized(.appUI.settings.tabUnloadPressureAfterTwoMinutes)
		case .fiveMinutes: String.localized(.appUI.settings.tabUnloadPressureAfterFiveMinutes)
		case .tenMinutes: String.localized(.appUI.settings.tabUnloadPressureAfterTenMinutes)
		}
	}
}

extension TabUnloadDelay {
	fileprivate var title: String {
		switch self {
		case .oneHour: String.localized(.appUI.settings.tabUnloadAfterOneHour)
		case .twoHours: String.localized(.appUI.settings.tabUnloadAfterTwoHours)
		case .threeHours: String.localized(.appUI.settings.tabUnloadAfterThreeHours)
		case .sixHours: String.localized(.appUI.settings.tabUnloadAfterSixHours)
		case .twelveHours: String.localized(.appUI.settings.tabUnloadAfterTwelveHours)
		case .never: String.localized(.appUI.settings.tabUnloadOnlyWhenLow)
		}
	}
}
