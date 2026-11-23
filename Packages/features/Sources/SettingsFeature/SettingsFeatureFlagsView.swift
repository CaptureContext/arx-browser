import AppKit
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The Feature Flags page: Relaunch while a change waits for one, then every flag with what it
/// does, its name, a warning where it has one, why it's off by default where it is, and its
/// toggle, locked when the environment sets it.
internal struct SettingsFeatureFlagsView: View {
	private let store: StoreOf<SettingsFeature>

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			if !store.featureFlagsAwaitingRelaunch.isEmpty {
				SettingsSection {
					SettingsRow(String.localized(.appUI.featureFlags.relaunchNeeded)) {
						Button(String.localized(.appUI.featureFlags.relaunch)) {
							store.send(.ui(.relaunchForFeatureFlags))
						}
						.buttonStyle(.arx(.primary))
					}
				}
			}
			SettingsSection(
				caption: String.localized(.appUI.featureFlags.description),
				content: {
					ForEach(FeatureFlag.allCases, id: \.self) { flag in
						row(flag)
					}
				},
				footer: { Text(localized: .appUI.featureFlags.environmentNote) }
			)
		}
		.task { store.send(.ui(.featureFlagsAppeared)) }
	}

	private func row(_ flag: FeatureFlag) -> some View {
		let state = store.featureFlagStates[flag] ?? .init(isOn: flag.isOnByDefault, source: .default)
		let isLocked = state.source == .environment
		return HStack(alignment: .firstTextBaseline, spacing: 12) {
			VStack(alignment: .leading, spacing: 3) {
				Text(flag.title)
				Text(flag.detail)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Text(verbatim: flag.name)
					.font(.caption.monospaced())
					.foregroundStyle(.tertiary)
					.textSelection(.enabled)
				if let warning = flag.warning {
					Label(warning, systemImage: "exclamationmark.triangle.fill")
						.font(SettingsTypography.caption)
						.foregroundStyle(.orange)
						.fixedSize(horizontal: false, vertical: true)
				}
				if let offReason = flag.offReason {
					Label(offReason, systemImage: "pause.circle")
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				if isLocked {
					Label(
						String.localized(.appUI.featureFlags.setByEnvironment(flag.name)),
						systemImage: "lock.fill"
					)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
				} else if flag.needsRelaunch {
					Text(localized: .appUI.featureFlags.takesRelaunch)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer(minLength: 16)
			Toggle(
				flag.title,
				isOn: Binding(
					get: { state.isOn },
					set: { store.send(.ui(.featureFlagChanged(flag, $0))) }
				)
			)
			.labelsHidden()
			.toggleStyle(.switch)
			.disabled(isLocked)
		}
		.settingsRow()
		.accessibilityElement(children: .combine)
	}
}

extension FeatureFlag {
	/// Its name in Settings.
	internal var title: String {
		switch self {
		case .agentTabs: String.localized(.appUI.featureFlags.agentTabs)
		case .readingMode: String.localized(.appUI.featureFlags.readingMode)
		case .liveCalendar: String.localized(.appUI.featureFlags.liveCalendar)
		case .pagePrompts: String.localized(.appUI.featureFlags.pagePrompts)
		case .deviceCapture: String.localized(.appUI.featureFlags.deviceCapture)
		case .sqliteWorkspace: String.localized(.appUI.featureFlags.sqliteWorkspace)
		case .iCloudSync: String.localized(.appUI.featureFlags.iCloudSync)
		case .iCloudSyncMerge: String.localized(.appUI.featureFlags.iCloudSyncMerge)
		case .sidebarPressSelects: String.localized(.appUI.featureFlags.sidebarPressSelects)
		case .scrollPocketHider: String.localized(.appUI.featureFlags.scrollPocketHider)
		case .scrollPocketAdaptive: String.localized(.appUI.featureFlags.scrollPocketAdaptive)
		case .translate: String.localized(.appUI.featureFlags.translate)
		case .hideElement: String.localized(.appUI.featureFlags.hideElement)
		case .elementPicker: String.localized(.appUI.featureFlags.elementPicker)
		case .collapsedFolderShowsSelection: String.localized(.appUI.featureFlags.collapsedFolderShowsSelection)
		case .swipeToCreateSpace: String.localized(.appUI.featureFlags.swipeToCreateSpace)
		case .idleTrim: String.localized(.appUI.featureFlags.idleTrim)
		case .bootstrapBackgroundPages: String.localized(.appUI.featureFlags.bootstrapBackgroundPages)
		case .spareRenderer: String.localized(.appUI.featureFlags.spareRenderer)
		case .spareLiveConnections: String.localized(.appUI.featureFlags.spareLiveConnections)
		case .littleArxAutoArchive: String.localized(.appUI.featureFlags.littleArxAutoArchive)
		case .sitePreviewImages: String.localized(.appUI.featureFlags.sitePreviewImages)
		case .darkPages: String.localized(.appUI.featureFlags.darkPages)
		case .linkStatus: String.localized(.appUI.featureFlags.linkStatus)
		case .matchSiteBackground: String.localized(.appUI.featureFlags.matchSiteBackground)
		case .accentColor: String.localized(.appUI.featureFlags.accentColor)
		case .pendingSettings: String.localized(.appUI.featureFlags.pendingSettings)
		case .independentWindows: String.localized(.appUI.featureFlags.independentWindows)
		case .fairPlayInChromium: String.localized(.appUI.featureFlags.fairPlayInChromium)
		case .sidebarRowPolish: String.localized(.appUI.featureFlags.sidebarRowPolish)
		case .inlineButtons: String.localized(.appUI.featureFlags.inlineButtons)
		case .copySubmenu: String.localized(.appUI.featureFlags.copySubmenu)
		case .settingsScrollRestore: String.localized(.appUI.featureFlags.settingsScrollRestore)
		case .settingsToolbarAdd: String.localized(.appUI.featureFlags.settingsToolbarAdd)
		case .pagePictureInPictureAddress: String.localized(.appUI.featureFlags.pagePictureInPictureAddress)
		case .recentTabSwitcher: String.localized(.appUI.featureFlags.recentTabSwitcher)
		case .returnToPreviousTab: String.localized(.appUI.featureFlags.returnToPreviousTab)
		case .pinResetShake: String.localized(.appUI.featureFlags.pinResetShake)
		case .shiftHoverPreview: String.localized(.appUI.featureFlags.shiftHoverPreview)
		case .newTabsAtTop: String.localized(.appUI.featureFlags.newTabsAtTop)
		case .sidebarRowAnimations: String.localized(.appUI.featureFlags.sidebarRowAnimations)
		case .pagePictureInPictureSpaces: String.localized(.appUI.featureFlags.pagePictureInPictureSpaces)
		case .schemeAddresses: String.localized(.appUI.featureFlags.schemeAddresses)
		case .windowUndo: String.localized(.appUI.featureFlags.windowUndo)
		case .browserLinks: String.localized(.appUI.featureFlags.browserLinks)
		case .captureBeyondViewport: String.localized(.appUI.featureFlags.captureBeyondViewport)
		case .extensionUpdateReview: String.localized(.appUI.featureFlags.extensionUpdateReview)
		case .onboardingICloud: String.localized(.appUI.featureFlags.onboardingIcloud)
		case .customizableHomepage: String.localized(.appUI.featureFlags.customizableHomepage)
		case .webKitSwipe: String.localized(.appUI.featureFlags.webKitSwipe)
		case .translucentChrome: String.localized(.appUI.featureFlags.translucentChrome)
		case .feedbackForm: String.localized(.appUI.featureFlags.feedbackForm)
		}
	}

	/// One line on what it does.
	internal var detail: String {
		switch self {
		case .agentTabs: String.localized(.appUI.featureFlags.agentTabsDetail)
		case .readingMode: String.localized(.appUI.featureFlags.readingModeDetail)
		case .liveCalendar: String.localized(.appUI.featureFlags.liveCalendarDetail)
		case .pagePrompts: String.localized(.appUI.featureFlags.pagePromptsDetail)
		case .deviceCapture: String.localized(.appUI.featureFlags.deviceCaptureDetail)
		case .sqliteWorkspace: String.localized(.appUI.featureFlags.sqliteWorkspaceDetail)
		case .iCloudSync: String.localized(.appUI.featureFlags.iCloudSyncDetail)
		case .iCloudSyncMerge: String.localized(.appUI.featureFlags.iCloudSyncMergeDetail)
		case .sidebarPressSelects: String.localized(.appUI.featureFlags.sidebarPressSelectsDetail)
		case .scrollPocketHider: String.localized(.appUI.featureFlags.scrollPocketHiderDetail)
		case .scrollPocketAdaptive: String.localized(.appUI.featureFlags.scrollPocketAdaptiveDetail)
		case .translate: String.localized(.appUI.featureFlags.translateDetail)
		case .hideElement: String.localized(.appUI.featureFlags.hideElementDetail)
		case .elementPicker: String.localized(.appUI.featureFlags.elementPickerDetail)
		case .collapsedFolderShowsSelection: String.localized(.appUI.featureFlags.collapsedFolderShowsSelectionDetail)
		case .swipeToCreateSpace: String.localized(.appUI.featureFlags.swipeToCreateSpaceDetail)
		case .idleTrim: String.localized(.appUI.featureFlags.idleTrimDetail)
		case .bootstrapBackgroundPages: String.localized(.appUI.featureFlags.bootstrapBackgroundPagesDetail)
		case .spareRenderer: String.localized(.appUI.featureFlags.spareRendererDetail)
		case .spareLiveConnections: String.localized(.appUI.featureFlags.spareLiveConnectionsDetail)
		case .littleArxAutoArchive: String.localized(.appUI.featureFlags.littleArxAutoArchiveDetail)
		case .sitePreviewImages: String.localized(.appUI.featureFlags.sitePreviewImagesDetail)
		case .darkPages: String.localized(.appUI.featureFlags.darkPagesDetail)
		case .linkStatus: String.localized(.appUI.featureFlags.linkStatusDetail)
		case .matchSiteBackground: String.localized(.appUI.featureFlags.matchSiteBackgroundDetail)
		case .accentColor: String.localized(.appUI.featureFlags.accentColorDetail)
		case .pendingSettings: String.localized(.appUI.featureFlags.pendingSettingsDetail)
		case .independentWindows: String.localized(.appUI.featureFlags.independentWindowsDetail)
		case .fairPlayInChromium: String.localized(.appUI.featureFlags.fairPlayInChromiumDetail)
		case .sidebarRowPolish: String.localized(.appUI.featureFlags.sidebarRowPolishDetail)
		case .inlineButtons: String.localized(.appUI.featureFlags.inlineButtonsDetail)
		case .copySubmenu: String.localized(.appUI.featureFlags.copySubmenuDetail)
		case .settingsScrollRestore: String.localized(.appUI.featureFlags.settingsScrollRestoreDetail)
		case .settingsToolbarAdd: String.localized(.appUI.featureFlags.settingsToolbarAddDetail)
		case .pagePictureInPictureAddress: String.localized(.appUI.featureFlags.pagePictureInPictureAddressDetail)
		case .recentTabSwitcher: String.localized(.appUI.featureFlags.recentTabSwitcherDetail)
		case .returnToPreviousTab: String.localized(.appUI.featureFlags.returnToPreviousTabDetail)
		case .pinResetShake: String.localized(.appUI.featureFlags.pinResetShakeDetail)
		case .shiftHoverPreview: String.localized(.appUI.featureFlags.shiftHoverPreviewDetail)
		case .newTabsAtTop: String.localized(.appUI.featureFlags.newTabsAtTopDetail)
		case .sidebarRowAnimations: String.localized(.appUI.featureFlags.sidebarRowAnimationsDetail)
		case .pagePictureInPictureSpaces: String.localized(.appUI.featureFlags.pagePictureInPictureSpacesDetail)
		case .schemeAddresses: String.localized(.appUI.featureFlags.schemeAddressesDetail)
		case .windowUndo: String.localized(.appUI.featureFlags.windowUndoDetail)
		case .browserLinks: String.localized(.appUI.featureFlags.browserLinksDetail)
		case .captureBeyondViewport: String.localized(.appUI.featureFlags.captureBeyondViewportDetail)
		case .extensionUpdateReview: String.localized(.appUI.featureFlags.extensionUpdateReviewDetail)
		case .onboardingICloud: String.localized(.appUI.featureFlags.onboardingIcloudDetail)
		case .customizableHomepage: String.localized(.appUI.featureFlags.customizableHomepageDetail)
		case .webKitSwipe: String.localized(.appUI.featureFlags.webKitSwipeDetail)
		case .translucentChrome: String.localized(.appUI.featureFlags.translucentChromeDetail)
		case .feedbackForm: String.localized(.appUI.featureFlags.feedbackFormDetail)
		}
	}

	/// What can go wrong with it on, for a flag that `isRisky`.
	internal var warning: String? {
		switch self {
		case .sqliteWorkspace: String.localized(.appUI.featureFlags.sqliteWorkspaceWarning)
		case .iCloudSync: String.localized(.appUI.featureFlags.iCloudSyncWarning)
		case .iCloudSyncMerge: String.localized(.appUI.featureFlags.iCloudSyncMergeWarning)
		case .agentTabs, .readingMode, .liveCalendar, .pagePrompts, .deviceCapture, .sidebarPressSelects,
			.scrollPocketHider, .scrollPocketAdaptive, .translate, .hideElement, .elementPicker, .collapsedFolderShowsSelection,
			.swipeToCreateSpace, .idleTrim, .bootstrapBackgroundPages, .spareRenderer, .spareLiveConnections,
			.littleArxAutoArchive, .sitePreviewImages, .darkPages, .linkStatus, .matchSiteBackground, .accentColor,
			.pendingSettings,
			.independentWindows, .fairPlayInChromium, .sidebarRowPolish, .inlineButtons, .copySubmenu,
			.settingsScrollRestore, .settingsToolbarAdd, .pagePictureInPictureAddress, .recentTabSwitcher, .returnToPreviousTab, .pinResetShake, .shiftHoverPreview, .newTabsAtTop, .sidebarRowAnimations, .pagePictureInPictureSpaces, .schemeAddresses, .windowUndo, .browserLinks,
			.captureBeyondViewport, .extensionUpdateReview, .onboardingICloud, .customizableHomepage, .webKitSwipe, .translucentChrome, .feedbackForm: nil
		}
	}

	/// Why it's off by default, for a flag in `FeatureFlag.offByDefault` (DEV-1143): for the beta,
	/// only the Customizable homepage is.
	internal var offReason: String? {
		guard Self.offByDefault.contains(self) else { return nil }

		return String.localized(.appUI.featureFlags.offUntilReady)
	}
}
