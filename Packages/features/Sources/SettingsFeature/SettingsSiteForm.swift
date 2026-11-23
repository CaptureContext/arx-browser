import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Add Site and Edit Site for Settings › Advanced's site lists (DEV-1001): the site and, for a
/// site kept loaded in one of several profiles, which profile.
internal struct SettingsSiteForm: View {
	private let store: StoreOf<SettingsFeature>
	private let profiles: [Profile]

	internal init(
		store: StoreOf<SettingsFeature>,
		profiles: [Profile] = []
	) {
		self.store = store
		self.profiles = profiles
	}

	private var draft: SettingsSiteDraft {
		store.siteDraft ?? .init(list: .webKit)
	}

	internal var body: some View {
		SettingsListForm(
			title: String.localized(draft.isNew ? .appUI.settings.siteForm.addTitle : .appUI.settings.siteForm.editTitle),
			primaryTitle: String.localized(draft.isNew ? .appUI.settings.siteForm.add : .appUI.common.save),
			isValid: draft.isValid,
			message: draft.error.map(Self.message),
			deleteTitle: String.localized(.appUI.settings.siteForm.remove),
			onCancel: { send(.cancel) },
			onSubmit: { send(.save) },
			onDelete: draft.isNew ? nil : { send(.delete) }
		) {
			SettingsTextField(
				String.localized(.appUI.settings.siteForm.site),
				text: Binding(
					get: { draft.site },
					set: { site in update { $0.site = site } }
				),
				prompt: String.localized(.appUI.settings.webKitSitePlaceholder)
			)
			if draft.list == .keptLoaded, profiles.count > 1 {
				// A picker row, as Site settings' forms choose a permission.
				SettingsSection {
					SettingsRow(String.localized(.appUI.settings.keptLoadedSiteProfile)) {
						Picker(
							String.localized(.appUI.settings.keptLoadedSiteProfile),
							selection: Binding(
								get: { draft.profileID ?? profiles[0].id },
								set: { profileID in update { $0.profileID = profileID } }
							)
						) {
							ForEach(profiles) { profile in
								Text(profile.name).tag(profile.id)
							}
						}
						.labelsHidden()
						.fixedSize()
					}
				}
			}
		}
	}

	internal static func message(_ failure: SettingsSiteDraft.Failure) -> String {
		switch failure {
		case .invalidSite: String.localized(.appUI.settings.webKitSiteInvalid)
		case .duplicate: String.localized(.appUI.settings.siteForm.duplicate)
		}
	}

	private func update(_ change: (inout SettingsSiteDraft) -> Void) {
		var next = draft
		change(&next)
		send(.changed(next))
	}

	private func send(_ action: SettingsSiteDraft.Action) {
		store.send(.ui(.siteDraft(action)))
	}
}

extension View {
	/// Presents Settings › Advanced's site form for `list` while it's open (DEV-1001).
	internal func settingsSiteFormSheet(
		_ list: SettingsSiteDraft.List,
		store: StoreOf<SettingsFeature>,
		profiles: [Profile] = []
	) -> some View {
		sheet(
			isPresented: Binding(
				get: { store.siteDraft?.list == list },
				set: { if !$0 { store.send(.ui(.siteDraft(.cancel))) } }
			)
		) {
			SettingsSiteForm(store: store, profiles: profiles)
		}
	}
}
