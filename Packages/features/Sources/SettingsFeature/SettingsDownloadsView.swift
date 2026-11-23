import AppUI
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// A profile's downloads folder and "Ask where to save each file" (DEV-647). Chromium
/// keeps both with the profile; a new profile saves to the user's Downloads folder.
internal struct SettingsDownloadsView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let profile: Profile

	@SwiftUI.State
	private var isChoosingFolder: Bool = false

	internal init(
		store: StoreOf<SettingsFeature>,
		profile: Profile
	) {
		self.store = store
		self.profile = profile
	}

	internal var body: some View {
		let settings = store.downloadSettings[profile.id]
		let isManaged = settings?.isManaged == true
		let isChanging = store.downloadSettingsChanging.contains(profile.id)
		SettingsSection(
			String.localized(.appUI.downloadSettings.title),
			content: {
				SettingsRow(String.localized(.appUI.downloadSettings.location)) {
					if let settings {
						Label {
							Text(verbatim: FileManager.default.displayName(atPath: settings.directory.path(percentEncoded: false)))
						} icon: {
							Image(systemName: "folder.fill")
						}
						.help(settings.directory.path(percentEncoded: false))
						.foregroundStyle(.secondary)
						if !isManaged, settings.directory.standardizedFileURL != settings.defaultDirectory.standardizedFileURL {
							Button(String.localized(.appUI.downloadSettings.reset)) {
								store.send(.ui(.resetDownloadFolder(profile.id)))
							}
							.disabled(isChanging)
						}
						Button(String.localized(.appUI.downloadSettings.change)) {
							isChoosingFolder = true
						}
						.disabled(isManaged || isChanging)
					} else {
						Text(localized: .appUI.downloadSettings.loading)
							.foregroundStyle(.secondary)
					}
				}
				SettingsToggle(
					String.localized(.appUI.downloadSettings.ask),
					detail: String.localized(.appUI.downloadSettings.askDetail),
					isOn: Binding(
						get: { settings?.asksWhereToSave ?? false },
						set: { store.send(.ui(.asksWhereToSave(profile.id, $0))) }
					)
				)
				.disabled(settings == nil || isManaged || isChanging)
			},
			footer: {
				if isManaged {
					Text(localized: .appUI.downloadSettings.managed)
				}
				if let notice = store.downloadSettingsNotice[profile.id] {
					Text(verbatim: Self.message(notice))
						.foregroundStyle(.red)
				}
			}
		)
		.task(id: profile.id) { store.send(.ui(.loadDownloadSettings(profile.id))) }
		.fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
			guard case let .success(folder) = result else { return }
			store.send(.ui(.chooseDownloadFolder(profile.id, folder)))
		}
		.fileDialogDefaultDirectory(settings?.directory)
	}

	private static func message(_ failure: ProfileDataFailure) -> String {
		switch failure {
		case .unavailable, .busy: String.localized(.appUI.downloadSettings.unavailable)
		case .invalid: String.localized(.appUI.downloadSettings.invalid)
		case .managed: String.localized(.appUI.downloadSettings.managed)
		case .failed: String.localized(.appUI.downloadSettings.failed)
		}
	}
}
