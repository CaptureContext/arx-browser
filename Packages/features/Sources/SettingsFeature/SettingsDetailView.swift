import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// A sheet opened from a pane's row: Previews. Lists that grow open as pages (DEV-1114).
internal struct SettingsDetailView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let panel: SettingsPanel

	internal init(
		store: StoreOf<SettingsFeature>,
		panel: SettingsPanel
	) {
		self.store = store
		self.panel = panel
	}

	internal var body: some View {
		SettingsSheet(panel.title, trail: [panel.category.title], height: height) {
			store.send(.ui(.panelPresented(nil)))
		} content: {
			switch panel {
			case .previews:
				previews
			}
		}
	}

	/// Previews: what folders and favorite sites show on hover (DEV-802), and what cards show for
	/// pages that aren't loaded (DEV-730). Each needs Previews on hover; sources that don't work
	/// yet stay listed in debug builds only.
	private var previews: some View {
		let isOn = store.general.hoverPreviewsEnabled

		// Live Calendar (DEV-804) shows only while its feature flag is on.
		let liveCalendar = LiveCalendar.isEnabled()
		let sitePreviewImages = SitePreviewImagesFeatureFlag.isOn()
		return VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			SettingsSection(
				caption: String.localized(.appUI.settings.previewsDescription),
				content: {
					previewToggle(String.localized(.appUI.settings.folderPreviews), \.folders)
					previewToggle(String.localized(.appUI.settings.mailPreviews), \.mail)
					previewToggle(String.localized(.appUI.settings.recentPreviews), \.recentPages)
					if liveCalendar {
						calendarToggle
					}
				},
				footer: {
					Text(isOn
					? String.localized(.appUI.settings.previewsPrivacy)
					: String.localized(.appUI.settings.previewsNeedHover))
				}
			)
			.disabled(!isOn)

			// Tabs whose page isn't loaded (DEV-730): a choice under `ARX_SITE_PREVIEW_IMAGES`
			// (DEV-1142), its two switches otherwise.
			SettingsSection(
				String.localized(.appUI.settings.unloadedPreviews),
				caption: String.localized(.appUI.settings.unloadedPreviewsDescription),
				content: {
					if sitePreviewImages {
						unloadedPagesChoice
					} else {
						previewToggle(String.localized(.appUI.settings.pageDetailsPreviews), \.pageDetails)
						previewToggle(String.localized(.appUI.settings.fullPreviews), \.fullPages)
					}
					if SidebarShiftHoverPreview.isEnabled {
						previewToggle(String.localized(.appUI.settings.shiftHoverLoadsPages), \.shiftLoadsPages)
					}
				},
				footer: {
					Text(sitePreviewImages
					? String.localized(.appUI.settings.unloadedPreviewChoicePrivacy)
					: String.localized(.appUI.settings.unloadedPreviewsPrivacy))
				}
			)
			.disabled(!isOn)
			#if DEBUG
			if SettingsPage.showsPendingOptions {
				SettingsSection {
					SettingsPendingRow(liveCalendar
					? String.localized(.appUI.settings.otherCalendarPreviews)
					: String.localized(.appUI.settings.calendarPreviews))
					SettingsPendingRow(String.localized(.appUI.settings.outlookMailPreviews))
				}
			}
			#endif
		}
	}

	/// What a card shows for a page that isn't loaded and has no saved picture (DEV-1142).
	private var unloadedPagesChoice: some View {
		let title = String.localized(.appUI.settings.unloadedPreviewChoice)
		return SettingsRow(title) {
			Picker(
				title,
				selection: Binding(
					get: { store.general.hoverPreviewSources.unloadedPages },
					set: { choice in
						var sources = store.general.hoverPreviewSources
						sources.unloadedPages = choice
						store.send(.ui(.hoverPreviewSources(sources)))
					}
				)
			) {
				Text(localized: .appUI.settings.unloadedPreviewSitePicture).tag(UnloadedPagePreview.sitePicture)
				Text(localized: .appUI.settings.unloadedPreviewLoadPage).tag(UnloadedPagePreview.loadPage)
				Text(localized: .appUI.settings.unloadedPreviewSavedPicture).tag(UnloadedPagePreview.savedPicture)
			}
			.labelsHidden()
			.fixedSize()
		}
	}

	/// Turning Live Calendar on also brings back the favorites whose card turned it off.
	private var calendarToggle: some View {
		SettingsToggle(
			String.localized(.appUI.settings.googleCalendarPreviews),
			isOn: Binding(
				get: { store.general.hoverPreviewsEnabled && store.general.hoverPreviewSources.calendars },
				set: { isOn in
					var sources = store.general.hoverPreviewSources
					sources.calendars = isOn
					if isOn { sources.disabledCalendars = [] }
					store.send(.ui(.hoverPreviewSources(sources)))
				}
			)
		)
	}

	private func previewToggle(
		_ title: String,
		_ source: WritableKeyPath<HoverPreviewSources, Bool>
	) -> some View {
		SettingsToggle(
			title,
			isOn: Binding(
				get: { store.general.hoverPreviewsEnabled && store.general.hoverPreviewSources[keyPath: source] },
				set: { isOn in
					var sources = store.general.hoverPreviewSources
					sources[keyPath: source] = isOn
					store.send(.ui(.hoverPreviewSources(sources)))
				}
			)
		)
	}

	/// Every sheet scrolls inside a steady height.
	private var height: CGFloat {
		switch panel {
		case .previews: 640
		}
	}
}
