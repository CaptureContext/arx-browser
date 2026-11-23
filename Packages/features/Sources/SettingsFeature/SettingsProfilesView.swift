import AppUI
import BrowserCore
import BrowserWorkspaceClient
import ExtensionsFeature
import SwiftUI
import _ComposableArchitecture

/// Settings › Profiles: one plain list of profiles. Each opens its settings on a page of its own
/// (`SettingsProfileView`); New Profile is the "+" on the window's top bar, or sits above the list
/// with the `ARX_SETTINGS_TOOLBAR_ADD` feature flag off, and each row's context menu renames or
/// removes it.
internal struct SettingsProfilesView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let organization: BrowserOrganization

	@Environment(\.settingsToolbarAdd)
	private var addsFromToolbar

	/// Profiles marked for deletion (DEV-1336).
	@SharedReader(.iCloudRemoval)
	private var iCloudRemoval

	internal init(
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization
	) {
		self.store = store
		self.organization = organization
	}

	internal static var searchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.settings.yourProfiles),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.profiles))
					+ [SettingsAddTarget.profile.title],
				in: .profiles,
				destination: .row(.profiles, .profileList)
			),
			.init(
				String.localized(.appUI.extensions.title),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.extensions)),
				in: .profiles,
				destination: .extensions
			),
		]
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			profiles
			if !store.profileRetirements.isEmpty {
				retirements
			}
		}
	}

	private var profiles: some View {
		// The pane's bar already says Profiles, so the list has no title of its own (DEV-1241).
		VStack(alignment: .trailing, spacing: 6) {
			if !addsFromToolbar {
				Button(String.localized(.appUI.settings.newProfile), systemImage: "plus") {
					store.send(.ui(.editOrganization(.init())))
				}
				.disabled(store.isManagingOrganization)
				.padding(.horizontal, 14)
			}

			SettingsSection(
				content: {
					if organization.profiles.isEmpty {
						Text(localized: .appUI.settings.emptyProfiles)
							.foregroundStyle(.secondary)
							.settingsRow()
					}
					ForEach(organization.profiles) { profile in
						profileRow(profile)
					}
				},
				footer: { Text(localized: .appUI.settings.profileSandbox) }
			)
			.settingsAnchor(.profileList)
		}
	}

	private func profileRow(_ profile: Profile) -> some View {
		let spaces = organization.spaces.filter { $0.profileID == profile.id }.count
		let spaceCount = String.localized(.appUI.settings.spaceCount(spaces))
		let mark: DeletionMark? = iCloudRemoval.marked[profile.id.rawValue]
		return Button { open(profile) } label: {
			HStack(spacing: 10) {
				ProfileSmiley()
					.foregroundStyle(.secondary)
					.frame(width: 20, height: 20)
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 4) {
						Text(profile.name)
							.lineLimit(1)
							.truncationMode(.middle)
						if mark != nil { DeletionMarkBadge() }
					}
					Text(spaceCount)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
					if let mark {
						Text(DeletionMarkText.hint(deviceName: mark.deviceName, deletesAt: mark.deletesAt))
							.font(SettingsTypography.caption)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				Spacer(minLength: 12)
				Image(systemName: "chevron.right")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(.tertiary)
					.accessibilityHidden(true)
			}
			.settingsRow()
			.contentShape(.rect)
		}
		.buttonStyle(.settingsGroupRow)
		.accessibilityElement(children: .combine)
		.contextMenu {
			Button(String.localized(.appUI.settings.profileOpen)) { open(profile) }
			if mark != nil {
				Button(String.localized(.appUI.management.removeHereToo), role: .destructive) {
					store.send(.ui(.changeOrganization(.removeProfile(profile.id))))
				}
				.disabled(!organization.canRemove(profile))
				Button(String.localized(.appUI.management.keepMarked)) {
					store.send(.ui(.keepMarked(organization.itemsCovered(by: profile.id.rawValue))))
				}
			}
			Divider()
			Button(String.localized(.appUI.settings.profileRename)) {
				store.send(.ui(.editOrganization(.init(profile: profile))))
			}
			Button(String.localized(.appUI.settings.profileRemove), role: .destructive) {
				store.send(.ui(.editOrganization(.init(kind: .removeProfile(profile.id), name: profile.name))))
			}
			.disabled(!organization.canRemove(profile))
		}
		.disabled(store.isManagingOrganization)
	}

	private func open(_ profile: Profile) {
		store.send(.ui(.profileSelected(profile.id)))
		store.send(.ui(.pagePresented(.profile)))
	}

	/// Profiles whose website data is still being removed, with Retry when it failed.
	private var retirements: some View {
		SettingsSection(String.localized(.appUI.retirement.title)) {
			ForEach(store.profileRetirements) { record in
				SettingsRow(record.name, detail: record.message) {
					if record.canRetry {
						Button(String.localized(.appUI.retirement.retry)) {
							store.send(.ui(.retryProfileRetirement(record.id)))
						}
						.disabled(store.isManagingOrganization)
					}
				}
			}
		}
	}
}

/// Profiles › a profile: its settings in grouped sections, as every other pane lays them out.
internal struct SettingsProfileView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let organization: BrowserOrganization

	/// Spaces marked for deletion (DEV-1336).
	@SharedReader(.iCloudRemoval)
	private var iCloudRemoval

	internal init(
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization
	) {
		self.store = store
		self.organization = organization
	}

	internal var body: some View {
		if let profile = organization.profiles[id: store.selectedProfileID] {
			content(profile)
				.disabled(store.isManagingOrganization)
		} else {
			Text(localized: .appUI.settings.profileGone)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity)
				.padding(.top, 120)
		}
	}

	private func content(_ profile: Profile) -> some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			SettingsSection(
				String.localized(.appUI.settings.section.search),
				footer: String.localized(.appUI.settings.suggestionsExplanation)
			) {
				SettingsRow(String.localized(.appUI.settings.searchEngine)) {
					Picker(
						String.localized(.appUI.settings.searchEngine),
						selection: Binding(
							get: { profile.searchEngine ?? .google },
							set: { store.send(.ui(.changeOrganization(.setSearchEngine(profile.id, $0)))) }
						)
					) {
						ForEach(SearchEngine.allCases, id: \.self) { engine in
							Text(engine.title).tag(engine)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
				SettingsToggle(
					String.localized(.appUI.settings.suggestions),
					isOn: Binding(
						get: { profile.suggestsRemotely },
						set: { store.send(.ui(.changeOrganization(.setRemoteSearchSuggestions(profile.id, $0)))) }
					)
				)
			}
			SettingsSection(String.localized(.appUI.settings.section.tabs)) {
				SettingsRow(
					String.localized(.appUI.settings.archiveTabs),
					detail: String.localized(.appUI.settings.archiveTabsExplanation)
				) {
					Picker(
						String.localized(.appUI.settings.archiveTabs),
						// A choice is stored as made, the default included (DEV-1326).
						selection: Binding(
							get: { profile.effectiveTabArchiveInterval },
							set: { store.send(.ui(.changeOrganization(.setTabArchiveInterval(profile.id, $0)))) }
						)
					) {
						ForEach(TabArchiveInterval.allCases, id: \.self) { interval in
							Text(interval.title).tag(interval)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
				SettingsToggle(
					String.localized(.appUI.settings.fullURL),
					detail: String.localized(.appUI.settings.fullURLExplanation),
					isOn: Binding(
						get: { profile.showsWholeURL },
						set: { store.send(.ui(.changeOrganization(.setShowsFullURL(profile.id, $0)))) }
					)
				)

				// DEV-1258: a site's or a tab's own choice wins over the profile's.
				SettingsRow(
					String.localized(.appUI.settings.profileUnreadBadges),
					detail: String.localized(.appUI.settings.profileUnreadBadgesDetail)
				) {
					UnreadBadgeVisibilityPicker(
						String.localized(.appUI.settings.profileUnreadBadges),
						selection: Binding(
							get: { profile.unreadBadges },
							set: { store.send(.ui(.changeOrganization(.setProfileUnreadBadges(profile.id, $0)))) }
						),
						inherited: UnreadBadgeVisibility(shows: store.general.showsUnreadBadges)
					)
					.labelsHidden()
					.fixedSize()
				}

				// Off makes the profile "this Mac only" (DEV-981): only with iCloud sync in this run.
				if store.iCloudSync.isAvailable {
					SettingsToggle(
						String.localized(.appUI.settings.profileSync),
						detail: String.localized(.appUI.settings.profileSyncDetail),
						isOn: Binding(
							get: { !profile.isThisMacOnly },
							set: { store.send(.ui(.changeOrganization(.setSyncsWithICloud(profile.id, $0)))) }
						)
					)
					SettingsRow(String.localized(.appUI.settings.iCloudSync.title)) {
						Button(String.localized(.appUI.settings.profileSyncSettings)) {
							store.send(.ui(.categorySelected(.sync)))
						}
					}
				}
			}
			SettingsSection(String.localized(.appUI.appearance.windowBackground)) {
				SpaceThemeEditor(
					level: .profile,
					layout: .settings,
					choices: profile.appearance ?? .init(),
					inherited: store.chromeAppearance,
					offersMatchSite: store.matchSiteAvailable,
					offersAccent: ChromeAccent.isEnabled(),
					onCommit: { store.send(.ui(.changeOrganization(.setProfileAppearance(profile.id, $0)))) },
					onClear: { store.send(.ui(.changeOrganization(.setProfileAppearance(profile.id, .init())))) }
				)
			}
			SettingsDownloadsView(store: store, profile: profile)
			SettingsHistoryView(store: store, profile: profile)
			dataSection(profile)
			spacesSection(profile)
		}
	}

	/// Sheets for this profile's own data: none of it is shared with another profile.
	private func dataSection(_ profile: Profile) -> some View {
		let canManageExtensions = store.extensions.isAvailable && store.extensions.profile?.id == profile.id
		return SettingsSection(String.localized(.appUI.settings.profileData)) {
			drillRow(String.localized(.appUI.settings.siteSettings), symbol: "hand.raised") {
				store.send(.ui(.showSiteSettings(profile.id)))
			}
			drillRow(String.localized(.appUI.settings.passwords), symbol: "key") {
				store.send(.ui(.showSavedPasswords(profile.id)))
			}
			drillRow(String.localized(.appUI.autofill.title), symbol: "creditcard") {
				store.send(.ui(.showAutofill(profile.id)))
			}
			if canManageExtensions {
				// DEV-1210: store updates the automatic check left for the person's review.
				let reviews = store.extensions.pendingUpdateReviews.count
				SettingsDrillDownRow(
					String.localized(.appUI.extensions.title),
					symbol: "puzzlepiece.extension",
					summary: reviews == 0 ? nil : String.localized(.appUI.extensions.updatesNeedReview(reviews))
				) {
					store.send(.extensions(.ui(.present)))
				}
			}
			drillRow(String.localized(.appUI.settings.clearData), symbol: "trash") {
				store.send(.ui(.showClearBrowsingData(profile.id)))
			}
			if PageTranslationFeatureFlag.isEnabled() {
				translationChoicesRow(profile)
			}
			#if DEBUG
			if SettingsPage.showsPendingOptions {
				SettingsPendingRow(String.localized(.appUI.settings.privacy))
				SettingsPendingRow(String.localized(.appUI.settings.newDocuments))
			}
			#endif
		}
	}

	/// The sites this profile never translates and the languages it always translates (DEV-871),
	/// chosen from the translation popover, put back to asking.
	private func translationChoicesRow(_ profile: Profile) -> some View {
		SettingsRow(
			String.localized(.appUI.settings.translationChoices),
			detail: String.localized(.appUI.settings.translationChoicesDetail)
		) {
			Button(String.localized(.appUI.settings.translationChoicesReset)) {
				store.send(.ui(.resetTranslationChoices(profile.id)))
			}
			.disabled(store.translation[profile.id].isEmpty)
		}
	}

	/// The spaces that use this profile, then Rename and Remove.
	private func spacesSection(_ profile: Profile) -> some View {
		let spaces = organization.spaces.filter { $0.profileID == profile.id }
		return SettingsSection(
			String.localized(.appUI.settings.spaces),
			footer: String.localized(.appUI.management.profileHasSpaces)
		) {
			if spaces.isEmpty {
				Text(localized: .appUI.settings.profileNoSpaces)
					.foregroundStyle(.secondary)
					.settingsRow()
			}
			ForEach(spaces) { space in
				spaceRow(space)
			}
			HStack {
				Button(String.localized(.appUI.settings.profileRename)) {
					store.send(.ui(.editOrganization(.init(profile: profile))))
				}
				Spacer()
				Button(String.localized(.appUI.settings.profileRemove), role: .destructive) {
					store.send(.ui(.editOrganization(.init(kind: .removeProfile(profile.id), name: profile.name))))
				}
				.disabled(!organization.canRemove(profile))
			}
			.settingsRow()
		}
	}

	/// A space, with its mark and Keep when another Mac removed it from iCloud (DEV-1336).
	@ViewBuilder
	private func spaceRow(_ space: Space) -> some View {
		if let mark = iCloudRemoval.marked[space.id.rawValue] {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				VStack(alignment: .leading, spacing: 2) {
					HStack(spacing: 4) {
						Text(space.name)
						DeletionMarkBadge()
					}
					Text(DeletionMarkText.hint(deviceName: mark.deviceName, deletesAt: mark.deletesAt))
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
				Spacer(minLength: 12)
				Button(String.localized(.appUI.management.removeHereToo), role: .destructive) {
					store.send(.ui(.changeOrganization(.removeSpace(space.id))))
				}
				.disabled(organization.spaces.count == 1)
				Button(String.localized(.appUI.management.keepMarked)) {
					store.send(.ui(.keepMarked(organization.itemsCovered(by: space.id.rawValue))))
				}
			}
			.settingsRow()

		} else {
			Text(space.name)
				.frame(maxWidth: .infinity, alignment: .leading)
				.settingsRow()
		}
	}

	private func drillRow(
		_ title: String,
		symbol: String,
		action: @escaping () -> Void
	) -> some View {
		SettingsDrillDownRow(title, symbol: symbol, action: action)
	}
}

extension BrowserOrganization {
	/// A profile can go once it's not the last one and no space uses it.
	fileprivate func canRemove(_ profile: Profile) -> Bool {
		profiles.count > 1 && !spaces.contains { $0.profileID == profile.id }
	}
}

extension TabArchiveInterval {
	fileprivate var title: String {
		switch self {
		case .sixHours: String.localized(.appUI.settings.archiveAfterSixHours)
		case .twelveHours: String.localized(.appUI.settings.archiveAfterTwelveHours)
		case .day: String.localized(.appUI.settings.archiveAfterDay)
		case .week: String.localized(.appUI.settings.archiveAfterWeek)
		case .month: String.localized(.appUI.settings.archiveAfterMonth)
		case .never: String.localized(.appUI.settings.archiveNever)
		}
	}
}
