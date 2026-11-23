import AppUI
import SwiftUI
import WorkspaceSync

/// What a merge does, before it happens (DEV-1216): what merges, what's added, and which settings
/// come from iCloud, or from the profile that stays. Each merge can be kept separate instead.
internal struct ICloudSyncMergePreview: View {
	internal let preview: MergePreview
	internal let keepingSeparate: Set<UUID>
	internal let isMerging: Bool
	internal let error: String?
	internal let setKeepingSeparate: (UUID, Bool) -> Void
	internal let confirm: () -> Void
	internal let cancel: () -> Void

	internal var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(title)
				.font(.headline)
			Text(message)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					if !preview.plan.profiles.isEmpty {
						group(String.localized(.appUI.settings.iCloudSync.merge.willMerge)) {
							ForEach(preview.plan.profiles) { profile in
								profileRows(profile)
							}
						}
					}
					if !additions.isEmpty {
						group(String.localized(.appUI.settings.iCloudSync.merge.willBeAdded)) {
							ForEach(additions, id: \.self) { line in
								Text(line)
							}
						}
					}
					if !settingLines.isEmpty {
						group(settingsTitle) {
							ForEach(settingLines, id: \.self) { line in
								Text(line)
							}
						}
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			if let error {
				Text(String.localized(.appUI.settings.iCloudSync.merge.failed(error)))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			HStack {
				if isMerging {
					ProgressView()
						.controlSize(.small)
				}
				Spacer()
				Button(String.localized(.appUI.settings.iCloudSync.merge.cancel), action: cancel)
					.keyboardShortcut(.cancelAction)
				Button(confirmTitle, action: confirm)
					.keyboardShortcut(.defaultAction)
			}
			.disabled(isMerging)
		}
		.padding(20)
		.frame(width: 480)
		.frame(minHeight: 260, maxHeight: 560)
	}

	private var title: String {
		switch preview.kind {
		case .joining:
			String.localized(.appUI.settings.iCloudSync.merge.joiningTitle)
		case .profiles:
			String.localized(.appUI.settings.iCloudSync.merge.profilesTitle(preview.plan.profiles.first?.name ?? ""))
		}
	}

	private var message: String {
		switch preview.kind {
		case .joining: String.localized(.appUI.settings.iCloudSync.merge.joiningMessage)
		case .profiles: String.localized(.appUI.settings.iCloudSync.merge.profilesMessage)
		}
	}

	private var settingsTitle: String {
		switch preview.kind {
		case .joining: String.localized(.appUI.settings.iCloudSync.merge.settingsFromIcloud)
		case .profiles: String.localized(.appUI.settings.iCloudSync.merge.settingsFromKept)
		}
	}

	private var confirmTitle: String {
		switch preview.kind {
		case .joining: String.localized(.appUI.settings.iCloudSync.merge.mergeAndSync)
		case .profiles: String.localized(.appUI.settings.iCloudSync.merge.merge)
		}
	}

	private func group(
		_ title: String,
		@ViewBuilder content: () -> some View
	) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(title)
				.font(.subheadline.weight(.semibold))
			VStack(alignment: .leading, spacing: 6, content: content)
				.padding(.leading, 8)
		}
	}

	@ViewBuilder
	private func profileRows(_ profile: WorkspaceMerge.ProfileMatch) -> some View {
		let isSeparate: Bool = keepingSeparate.contains(profile.mergedID)
		matchRow(
			String.localized(.appUI.settings.iCloudSync.merge.pair(profile.mergedName, profile.name)),
			details: isSeparate ? [] : profileDetails(profile),
			id: profile.mergedID,
			isSeparate: isSeparate
		)
		if !isSeparate {
			ForEach(profile.spaces) { space in
				let isSpaceSeparate: Bool = keepingSeparate.contains(space.mergedID)
				matchRow(
					String.localized(.appUI.settings.iCloudSync.merge.pair(space.mergedName, space.name)),
					details: isSpaceSeparate || space.pins.total == 0
					? []
					: [String.localized(.appUI.settings.iCloudSync.merge.pins(space.pins.total, space.pins.new))],
					id: space.mergedID,
					isSeparate: isSpaceSeparate
				)
				.padding(.leading, 16)
			}
		}
	}

	private func matchRow(
		_ title: String,
		details: [String],
		id: UUID,
		isSeparate: Bool
	) -> some View {
		HStack(alignment: .firstTextBaseline) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.foregroundStyle(isSeparate ? .secondary : .primary)
				ForEach(details, id: \.self) { detail in
					Text(detail)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer(minLength: 12)
			Toggle(
				String.localized(.appUI.settings.iCloudSync.merge.keepSeparate),
				isOn: Binding(
					get: { isSeparate },
					set: { setKeepingSeparate(id, $0) }
				)
			)
			.toggleStyle(.checkbox)
			.controlSize(.small)
		}
	}

	private func profileDetails(_ profile: WorkspaceMerge.ProfileMatch) -> [String] {
		let spaces: [WorkspaceMerge.SpaceMatch] = profile.spaces.filter { !keepingSeparate.contains($0.mergedID) }
		let total: Int = spaces.map(\.pins.total).reduce(0, +)
		let new: Int = spaces.map(\.pins.new).reduce(0, +)
		var details: [String] = []
		if total > 0 {
			details.append(String.localized(.appUI.settings.iCloudSync.merge.pins(total, new)))
		}
		if profile.favorites.total > 0 {
			details.append(String.localized(.appUI.settings.iCloudSync.merge.favorites(profile.favorites.total, profile.favorites.new)))
		}
		return details
	}

	/// Profiles and spaces added as they are, the ones kept separate among them, renamed when their
	/// name is taken.
	private var additions: [String] {
		func line(
			_ name: String,
			_ newName: String?
		) -> String {
			guard let newName, newName != name else { return name }

			return String.localized(.appUI.settings.iCloudSync.merge.renamed(name, newName))
		}

		var lines: [String] = []
		for profile in preview.plan.profiles {
			if keepingSeparate.contains(profile.mergedID) {
				lines.append(line(profile.mergedName, profile.separateName))
				continue
			}

			for space in profile.spaces where keepingSeparate.contains(space.mergedID) {
				lines.append(String.localized(.appUI.settings.iCloudSync.merge.inProfile(line(space.mergedName, space.separateName), profile.name)))
			}
			for space in profile.addedSpaces {
				lines.append(String.localized(.appUI.settings.iCloudSync.merge.inProfile(line(space.name, space.newName), profile.name)))
			}
		}
		for profile in preview.plan.addedProfiles {
			lines.append(line(profile.name, profile.newName))
		}
		return lines
	}

	/// What the merged items take from the kept ones: iCloud wins.
	private var settingLines: [String] {
		var lines: [String] = []
		for profile in preview.plan.profiles where !keepingSeparate.contains(profile.mergedID) {
			let changes: [WorkspaceMerge.SettingChange] = profile.settings
				+ profile.spaces.filter { !keepingSeparate.contains($0.mergedID) }.flatMap(\.settings)
			for change in changes {
				let text: String = switch change.setting {
				case .name, .title:
					String.localized(.appUI.settings.iCloudSync.merge.setting.name(change.from ?? "", change.to ?? ""))
				case .icon:
					String.localized(.appUI.settings.iCloudSync.merge.setting.icon(change.itemName))
				case .colors:
					String.localized(.appUI.settings.iCloudSync.merge.setting.colors(change.itemName))
				case .searchEngine:
					String.localized(.appUI.settings.iCloudSync.merge.setting.searchEngine(change.itemName))
				case .appearance, .tabArchive, .searchSuggestions, .fullURL, .keptLoadedSites, .darkPagesOffSites, .unreadBadges:
					String.localized(.appUI.settings.iCloudSync.merge.setting.other(change.itemName))
				}
				if !lines.contains(text) {
					lines.append(text)
				}
			}
		}
		return lines
	}
}
