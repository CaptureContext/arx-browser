import AppUI
import BrowserCore
import BrowserWorkspaceClient
import SwiftUI
import _ComposableArchitecture

internal struct OrganizationEditorView: View {
	@Bindable
	private var store: StoreOf<SettingsFeature>

	private let organization: BrowserOrganization

	/// Whether a removal asks where (DEV-1336).
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
		if store.organizationEditor.kind == .profile(nil) {
			ProfileCreationView(
				name: $store.organizationEditor.sending(\.ui.organizationEditorChanged).name,
				error: store.organizationError,
				isBusy: store.isManagingOrganization,
				onCancel: { store.send(.ui(.dismissOrganizationEditor)) },
				onCreate: { store.send(.ui(.submitOrganizationEditor)) }
			)
			.interactiveDismissDisabled(store.isManagingOrganization)

		} else {
			editor
		}
	}

	/// The Close bar the other Settings sheets use (DEV-772): × (Escape) cancels, and the one
	/// action stays in the row under the fields.
	private var editor: some View {
		VStack(alignment: .leading, spacing: 0) {
			SettingsNavigationBar(
				.close { store.send(.ui(.dismissOrganizationEditor)) },
				title: title,
				trail: [SettingsCategory.profiles.title]
			)
			fields
				.padding(.horizontal, SettingsSheetMetrics.contentPadding)
				.padding(.top, 4)
				.padding(.bottom, SettingsSheetMetrics.contentPadding)
		}
		.disabled(store.isManagingOrganization)
		.interactiveDismissDisabled(store.isManagingOrganization)
		.frame(width: 440)
		.arxModalSheet()
	}

	private var fields: some View {
		VStack(alignment: .leading, spacing: 20) {
			if store.organizationEditor.isRemoval {
				Text(store.organizationEditor.name).font(.headline)
				if let note = store.organizationEditor.note {
					Text(note)
				}
				Text(removalDetail)
				if asksWhere {
					Picker(
						selection: $store.organizationEditor.sending(\.ui.organizationEditorChanged).keepsElsewhere
					) {
						Text(localized: .appUI.management.deleteFromThisMacOnly).tag(true)
						Text(localized: .appUI.management.removeFromIcloud).tag(false)
					} label: {
						EmptyView()
					}
					.pickerStyle(.radioGroup)
					.labelsHidden()
					Text(localized: .appUI.management.removeWhereDetail).foregroundStyle(.secondary)
				}
				if store.organizationEditor.kind.isProfileRemoval {
					Toggle(
						String.localized(.appUI.retirement.eraseOption),
						isOn: $store.organizationEditor.sending(\.ui.organizationEditorChanged).eraseWebsiteData
					)
					.disabled(!store.retirementAvailable)
					if !store.retirementAvailable {
						Text(localized: .appUI.retirement.unavailable).foregroundStyle(.secondary)
					}
					if store.organizationEditor.eraseWebsiteData {
						Text(localized: .appUI.retirement.confirmDetail).foregroundStyle(.secondary)
						SettingsTextField(
							String.localized(.appUI.retirement.typeName),
							text: $store.organizationEditor.sending(\.ui.organizationEditorChanged).eraseConfirmation,
							prompt: store.organizationEditor.name
						)
					}
				}

			} else {
				SettingsTextField(
					String.localized(.appUI.management.name),
					text: $store.organizationEditor.sending(\.ui.organizationEditorChanged).name,
					prompt: namePrompt
				)
			}

			if let error = store.organizationError {
				Text(error).foregroundStyle(.red)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				if store.isManagingOrganization { ProgressView().controlSize(.small) }
				Spacer()
				ArxModalButton(
					submitTitle,
					role: store.organizationEditor.isRemoval ? .destructive : nil
				) {
					store.send(.ui(.submitOrganizationEditor))
				}
				.disabled(!store.organizationEditor.isRemoval && nameIsEmpty)
				.disabled(eraseConfirmationIsMissing)
			}
		}
	}

	/// A synced profile or space another Mac syncs: removing it asks whether to delete it from this Mac
	/// only or remove it from iCloud (DEV-1336). A "this Mac only" profile and its spaces never ask.
	private var asksWhere: Bool {
		guard iCloudRemoval.asksWhere else { return false }

		let profileID: Profile.ID? = switch store.organizationEditor.kind {
		case let .removeProfile(id): id
		case let .removeSpace(id): organization.spaces[id: id]?.profileID
		case .profile, .space: nil
		}
		guard
			let profileID,
			let profile = organization.profiles[id: profileID],
			let removed = store.organizationEditor.removedID
		else { return false }

		// Another Mac already removed it from iCloud: removing it here agrees.
		return !profile.isThisMacOnly && iCloudRemoval.marked[removed] == nil
	}

	/// An example name for what's being named.
	private var namePrompt: String {
		switch store.organizationEditor.kind {
		case .space, .removeSpace: String.localized(.appUI.settings.example.spaceName)
		case .profile, .removeProfile: String.localized(.appUI.settings.example.profileName)
		}
	}

	private var nameIsEmpty: Bool {
		store.organizationEditor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private var eraseConfirmationIsMissing: Bool {
		store.organizationEditor.eraseWebsiteData
		&& (
			!store.retirementAvailable
			|| store.organizationEditor.eraseConfirmation != store.organizationEditor.name
		)
	}

	private var removalDetail: String {
		guard store.organizationEditor.kind.isProfileRemoval
		else { return String.localized(.appUI.management.removeSpaceDetail) }
		return String.localized(
			store.organizationEditor.eraseWebsiteData
			? .appUI.retirement.removeDetail
			: .appUI.management.removeProfileDetail
		)
	}

	private var submitTitle: String {
		if store.organizationEditor.eraseWebsiteData {
			return String.localized(.appUI.retirement.removeAndErase)
		}

		return String.localized(
			store.organizationEditor.isRemoval
			? .appUI.management.remove
			: .appUI.management.save
		)
	}

	private var title: String {
		switch store.organizationEditor.kind {
		case .profile(nil): String.localized(.appUI.profile.create)
		case .profile: String.localized(.appUI.management.renameProfile)
		case .space(nil): String.localized(.appUI.sidebar.newSpace)
		case .space: String.localized(.appUI.management.editSpace)
		case .removeProfile: String.localized(.appUI.management.removeProfile)
		case .removeSpace: String.localized(.appUI.management.removeSpace)
		}
	}
}

extension OrganizationEditor.Kind {
	fileprivate var isProfileRemoval: Bool {
		if case .removeProfile = self { return true }
		return false
	}
}
