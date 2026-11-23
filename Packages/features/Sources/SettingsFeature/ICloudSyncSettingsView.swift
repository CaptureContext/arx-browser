import AppUI
import SwiftUI
import WorkspaceDatabase
import WorkspaceSync
import _ComposableArchitecture

/// The iCloud Sync section, Settings › Sync's content (DEV-1336; it was on the Arx pane). Nothing
/// shows unless the `ARX_ICLOUD_SYNC` feature flag is on.
internal struct ICloudSyncSettingsSection: View {
	internal let store: StoreOf<ICloudSyncSettingsFeature>

	internal var body: some View {
		// Availability is known when Settings' state is made: an empty view would never run a task.
		if store.isAvailable {
			section
				.task { store.send(.ui(.appeared)) }
				.sheet(
					isPresented: Binding(
						get: { store.status.mergePreview != nil },
						set: { if !$0 { store.send(.ui(.cancelMerge)) } }
					)
				) {
					if let preview = store.status.mergePreview {
						ICloudSyncMergePreview(
							preview: preview,
							keepingSeparate: store.keepingSeparate,
							isMerging: store.status.isMerging,
							error: store.status.mergeError,
							setKeepingSeparate: { store.send(.ui(.setKeepingSeparate($0, $1))) },
							confirm: { store.send(.ui(.confirmMerge)) },
							cancel: { store.send(.ui(.cancelMerge)) }
						)
					}
				}
		}
	}

	private var section: some View {
		SettingsSection(
			String.localized(.appUI.settings.iCloudSync.title),
			caption: String.localized(.appUI.settings.iCloudSync.caption),
			footer: String.localized(.appUI.settings.iCloudSync.footer)
		) {
			// The `ARX_ICLOUD_SYNC` feature flag is for testing until the rest of ADR 0001 is built.
			Label(String.localized(.appUI.settings.iCloudSync.developmentWarning), systemImage: "exclamationmark.triangle.fill")
				.font(SettingsTypography.caption)
				.foregroundStyle(.orange)
				.settingsRow()
			SettingsToggle(
				String.localized(.appUI.settings.iCloudSync.enabled),
				isOn: Binding(
					get: { store.status.isEnabled },
					set: { store.send(.ui(.setEnabled($0))) }
				)
			)
			SettingsRow(String.localized(.appUI.settings.iCloudSync.statusTitle)) {
				Text(statusText(store.status.overall))
					.foregroundStyle(.secondary)
			}
			if store.status.review == .accountChanged {
				review
			}
			if store.status.isStopped {
				Text(localized: .appUI.settings.iCloudSync.stop.stopped)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.settingsRow()
			}
			if store.status.isEnabled {
				ForEach(store.status.availableCategories, id: \.self) { category in
					categoryRow(category)
					devicesRow(category)
					if category == .history, store.status[.history] != .off {
						historyWindowRow
					}
					if category == .preferences {
						ForEach(PreferenceGroup.allCases, id: \.self) { group in
							groupRow(group)
						}
						if let error = store.preferenceGroupError {
							Text(String.localized(.appUI.settings.iCloudSync.groupSync.failed(error)))
								.font(SettingsTypography.caption)
								.foregroundStyle(.red)
								.settingsRow()
						}
					}
				}
				syncDeletionsRow
				ForEach(store.status.duplicateProfiles) { duplicates in
					duplicatesRow(duplicates)
				}
			}

			// Also while sync is off, so a paused Mac leaves without sending what it queued.
			if store.status.canStopSyncing {
				stopRow
			}
		}
	}

	/// The Macs syncing `category`, from the device directory (DEV-979). Each Mac's own choices show
	/// here read-only: only that Mac changes them.
	@ViewBuilder
	private func devicesRow(_ category: SyncCategory) -> some View {
		let devices: [SyncDevice] = store.status.devices(syncing: category)
		if !devices.isEmpty {
			VStack(alignment: .leading, spacing: 2) {
				ForEach(devices) { device in
					Text(deviceLine(device, category: category))
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
				}
			}
			.padding(.leading, 16)
			.settingsRow()
		}
	}

	private func deviceLine(
		_ device: SyncDevice,
		category: SyncCategory
	) -> String {
		let name: String = device.isThisMac
		? String.localized(.appUI.settings.iCloudSync.device.thisMac)
		: String.localized(.appUI.settings.iCloudSync.device.seen(
			device.name,
			device.lastSeen.formatted(.relative(presentation: .named))
		))
		guard category == .preferences, !device.isThisMac, !device.preferenceGroups.isEmpty else { return name }

		let groups: String = PreferenceGroup.allCases
			.filter(device.preferenceGroups.contains)
			.map(title)
			.formatted(.list(type: .and))
		return String.localized(.appUI.settings.iCloudSync.device.keeps(name, groups))
	}

	/// "Stop syncing this Mac" (DEV-979), in place of Delete from iCloud.
	private var stopRow: some View {
		SettingsRow(
			String.localized(.appUI.settings.iCloudSync.stop.title),
			detail: String.localized(.appUI.settings.iCloudSync.stop.detail)
		) {
			HStack {
				if store.status.isStopping {
					ProgressView()
						.controlSize(.small)
				}
				Button(String.localized(.appUI.settings.iCloudSync.stop.button)) {
					store.send(.ui(.stopSyncingThisMac))
				}
				.disabled(store.status.isStopping || store.status.isResolving)
			}
		}
		.confirmationDialog(
			String.localized(.appUI.settings.iCloudSync.stop.confirmTitle),
			isPresented: Binding(
				get: { store.isConfirmingStop },
				set: { if !$0 { store.send(.ui(.cancelStopSyncingThisMac)) } }
			),
			titleVisibility: .visible
		) {
			Button(String.localized(.appUI.settings.iCloudSync.stop.confirm), role: .destructive) {
				store.send(.ui(.confirmStopSyncingThisMac))
			}
		} message: {
			Text(localized: .appUI.settings.iCloudSync.stop.message)
		}
	}

	/// A failing category says why under its row (DEV-1209): the status line above names only the most
	/// pressing state.
	@ViewBuilder
	private func categoryRow(_ category: SyncCategory) -> some View {
		SettingsRow(title(category), detail: detail(category) + " " + offNote(category)) {
			toggle(.category(category), title: title(category))
		}
		if store.status[category].isError {
			Text(statusText(store.status[category]))
				.font(SettingsTypography.caption)
				.foregroundStyle(.red)
				.settingsRow()
		}
	}

	/// What turning the category off does: a leave for Profiles and spaces and Tab Archive (DEV-1148),
	/// a pause for the others until their rejoins are built.
	private func offNote(_ category: SyncCategory) -> String {
		category.leavesWhenTurnedOff
		? String.localized(.appUI.settings.iCloudSync.leaveNote)
		: String.localized(.appUI.settings.iCloudSync.pauseNote)
	}

	/// A part of Preferences (DEV-982). Its choice stays while Preferences is off, which shows it
	/// dimmed: a group turned off keeps this Mac's values then too.
	private func groupRow(_ group: PreferenceGroup) -> some View {
		SettingsRow(title(group), detail: detail(group)) {
			toggle(.preferenceGroup(group), title: title(group))
				.disabled(store.status[.preferences] == .off || store.isChangingPreferenceGroup)
		}
		.padding(.leading, 16)
		.confirmationDialog(
			String.localized(.appUI.settings.iCloudSync.groupSync.title(title(group))),
			isPresented: Binding(
				get: { store.syncingPreferenceGroup == group },
				set: { if !$0 { store.send(.ui(.cancelSyncingPreferenceGroup)) } }
			),
			titleVisibility: .visible
		) {
			Button(String.localized(.appUI.settings.iCloudSync.groupSync.keepThisMac)) {
				store.send(.ui(.syncPreferenceGroup(keepingThisMac: true)))
			}
			Button(String.localized(.appUI.settings.iCloudSync.groupSync.useSynced)) {
				store.send(.ui(.syncPreferenceGroup(keepingThisMac: false)))
			}
		} message: {
			Text(localized: .appUI.settings.iCloudSync.groupSync.message)
		}
	}

	private func toggle(
		_ toggle: SyncToggle,
		title: String
	) -> some View {
		Toggle(
			title,
			isOn: Binding(
				get: { store.status.isOn(toggle) },
				set: { store.send(.ui(.setToggle(toggle, $0))) }
			)
		)
		.toggleStyle(.switch)
		.controlSize(.small)
		.labelsHidden()
	}

	/// Synced profiles with the same name, such as two Macs' Defaults, merged on request (DEV-1216).
	private func duplicatesRow(_ duplicates: DuplicateProfiles) -> some View {
		SettingsRow(
			String.localized(.appUI.settings.iCloudSync.merge.duplicatesTitle),
			detail: String.localized(.appUI.settings.iCloudSync.merge.duplicatesDetail)
		) {
			// Two at a time: a third is offered again after.
			Button(String.localized(.appUI.settings.iCloudSync.merge.button(duplicates.name, duplicates.name))) {
				store.send(.ui(.previewProfileMerge(Array(duplicates.profileIDs.prefix(2)))))
			}
			.disabled(store.status.isMerging || store.status.mergePreview != nil)
		}
	}

	/// Deletions stay on this Mac unless this is on (DEV-980).
	private var syncDeletionsRow: some View {
		SettingsRow(
			String.localized(.appUI.settings.iCloudSync.syncDeletions),
			detail: String.localized(.appUI.settings.iCloudSync.syncDeletionsDetail)
		) {
			Toggle(
				String.localized(.appUI.settings.iCloudSync.syncDeletions),
				isOn: Binding(
					get: { store.status.syncDeletionsAfterDays != nil },
					set: { store.send(.ui(.setSyncsDeletions($0))) }
				)
			)
			.toggleStyle(.switch)
			.controlSize(.small)
			.labelsHidden()
		}
	}

	/// How many days of visits History sync mirrors (ADR 0001, decision 5).
	private var historyWindowRow: some View {
		SettingsRow(String.localized(.appUI.settings.iCloudSync.historyWindow)) {
			Picker(
				String.localized(.appUI.settings.iCloudSync.historyWindow),
				selection: Binding(
					get: { store.status.historyWindowDays },
					set: { store.send(.ui(.setHistoryWindow($0))) }
				)
			) {
				ForEach(historyWindowChoices, id: \.self) { days in
					Text(String.localized(.appUI.settings.iCloudSync.historyWindowDays(days)))
						.tag(days)
				}
			}
			.labelsHidden()
			.fixedSize()
		}
	}

	/// The offered windows, and the current one if it was set some other way.
	private var historyWindowChoices: [Int] {
		Set(SyncSettings.historyWindowChoices + [store.status.historyWindowDays]).sorted()
	}

	/// The three choices when another account is signed in (ADR 0001, section 8).
	private var review: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(localized: .appUI.settings.iCloudSync.review.title)
				.font(.headline)
			Text(localized: .appUI.settings.iCloudSync.review.message)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			HStack {
				Button(String.localized(.appUI.settings.iCloudSync.review.useWithThisAccount)) {
					store.send(.ui(.resolve(.useWithThisAccount)))
				}
				Button(String.localized(.appUI.settings.iCloudSync.review.keepOnThisMac)) {
					store.send(.ui(.resolve(.keepOnThisMac)))
				}
				Button(String.localized(.appUI.settings.iCloudSync.review.replace), role: .destructive) {
					store.send(.ui(.resolve(.replaceWithAccountData)))
				}
				.help(String.localized(.appUI.settings.iCloudSync.review.replaceDetail))
				if store.status.isResolving {
					ProgressView()
						.controlSize(.small)
				}
			}
			.disabled(store.status.isResolving)
			if let error = store.status.resolutionError {
				Text(String.localized(.appUI.settings.iCloudSync.status.error(error)))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
		}
		.settingsRow()
	}

	private func title(_ category: SyncCategory) -> String {
		switch category {
		case .organization: String.localized(.appUI.settings.iCloudSync.organization)
		case .preferences: String.localized(.appUI.settings.iCloudSync.preferences)
		case .history: String.localized(.appUI.settings.iCloudSync.history)
		case .archive: String.localized(.appUI.settings.iCloudSync.archive)
		}
	}

	private func title(_ group: PreferenceGroup) -> String {
		switch group {
		case .appearance: String.localized(.appUI.settings.iCloudSync.group.appearance)
		case .searchEngines: String.localized(.appUI.settings.iCloudSync.group.searchEngines)
		case .shortcuts: String.localized(.appUI.settings.iCloudSync.group.shortcuts)
		case .routing: String.localized(.appUI.settings.iCloudSync.group.routing)
		}
	}

	private func detail(_ group: PreferenceGroup) -> String {
		switch group {
		case .appearance: String.localized(.appUI.settings.iCloudSync.group.appearanceDetail)
		case .searchEngines: String.localized(.appUI.settings.iCloudSync.group.searchEnginesDetail)
		case .shortcuts: String.localized(.appUI.settings.iCloudSync.group.shortcutsDetail)
		case .routing: String.localized(.appUI.settings.iCloudSync.group.routingDetail)
		}
	}

	private func detail(_ category: SyncCategory) -> String {
		switch category {
		case .organization: String.localized(.appUI.settings.iCloudSync.organizationDetail)
		case .preferences: String.localized(.appUI.settings.iCloudSync.preferencesDetail)
		case .history: String.localized(.appUI.settings.iCloudSync.historyDetail)
		case .archive: String.localized(.appUI.settings.iCloudSync.archiveDetail)
		}
	}

	private func statusText(_ status: CategoryStatus) -> String {
		switch status {
		case .off:
			String.localized(.appUI.settings.iCloudSync.status.off)

		case .synced:
			String.localized(.appUI.settings.iCloudSync.status.synced)

		case .syncing:
			String.localized(.appUI.settings.iCloudSync.status.syncing)

		case .paused(.noAccount):
			String.localized(.appUI.settings.iCloudSync.status.noAccount)

		case .paused(.accountUnavailable):
			String.localized(.appUI.settings.iCloudSync.status.accountUnavailable)

		case .paused(.quotaExceeded):
			String.localized(.appUI.settings.iCloudSync.status.quotaExceeded)

		case .paused(.mergeReview):
			String.localized(.appUI.settings.iCloudSync.status.mergeReview)

		case .accountChanged:
			String.localized(.appUI.settings.iCloudSync.status.accountChanged)

		case let .error(message):
			String.localized(.appUI.settings.iCloudSync.status.error(message))

		case let .refused(count):
			String.localized(.appUI.settings.iCloudSync.status.refused(count))
		}
	}
}
