import AppUI
import BrowserCore
import SwiftUI

/// The review an extension's permissions get before Chromium installs it: the Extensions
/// sheet's installs and updates, and installs an agent asks for. Extensions brought over from
/// another browser get MigrationAssistantFeature's shorter `ExtensionImportReview` (DEV-1300).
/// Granting takes a click; Return doesn't install.
public struct ExtensionInstallReview: View {
	private let prompt: BrowserExtensionInstallPrompt
	private let profileName: String?
	private let requester: String?
	private let respond: (Bool) -> Void

	/// - Parameters:
	///   - requester: the MCP client that asked for this install (DEV-951), named at the top.
	public init(
		prompt: BrowserExtensionInstallPrompt,
		profileName: String?,
		requester: String? = nil,
		respond: @escaping (Bool) -> Void
	) {
		self.prompt = prompt
		self.profileName = profileName
		self.requester = requester
		self.respond = respond
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(String.localized(
				prompt.candidate.isUpdate
				? .appUI.extensions.updateTitle
				: .appUI.extensions.installTitle
			))
			.font(.title2.bold())
			if let requester {
				Text(String.localized(.appUI.extensions.requestedBy(requester)))
					.font(.callout.weight(.medium))
			}
			Text(localized: .appUI.extensions.consent)
				.font(.callout)
			ScrollView {
				VStack(alignment: .leading, spacing: 12) {
					Text(prompt.candidate.name)
						.font(.headline)

					// DEV-968: who publishes it, when its manifest says.
					if let publisher = prompt.candidate.publisher {
						LabeledContent(String.localized(.appUI.extensions.publisher), value: publisher)
					}
					LabeledContent(String.localized(.appUI.extensions.version), value: prompt.candidate.version)
					LabeledContent(
						String.localized(.appUI.extensions.identifier),
						value: prompt.candidate.extensionID
					)

					LabeledContent(
						String.localized(.appUI.extensions.package),
						value: prompt.candidate.sourceBasename
					)

					LabeledContent(
						String.localized(.appUI.extensions.packageHash),
						value: prompt.candidate.packageSHA256
					)
					.font(.caption)
					if let profileName { Text(profileName).fontWeight(.medium) }
					if !prompt.candidate.warnings.isEmpty {
						Text(localized: .appUI.extensions.permissionWarnings).font(.headline)
					}
					ForEach(Array(prompt.candidate.warnings.enumerated()), id: \.offset) { _, warning in
						VStack(alignment: .leading, spacing: 4) {
							Text(warning.message).fontWeight(.medium)
							ForEach(Array(warning.details.enumerated()), id: \.offset) { _, detail in
								Text(detail)
							}
						}
					}
					ExtensionPermissionsList(
						title: String.localized(.appUI.extensions.required),
						permissions: prompt.candidate.requiredPermissions
					)
					ExtensionPermissionsList(
						title: String.localized(.appUI.extensions.optional),
						permissions: prompt.candidate.optionalPermissions
					)
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.textSelection(.enabled)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer()
				ArxModalButton.cancel {
					respond(false)
				}

				// Granting an extension's permissions takes a click: Return doesn't install it.
				ArxModalButton(
					String.localized(
						prompt.candidate.isUpdate
						? .appUI.extensions.update
						: .appUI.extensions.install
					),
					key: nil
				) {
					respond(true)
				}
			}
		}
		.padding(24)
		.frame(width: 640, height: 580)
		.arxModalSheet()
	}
}

/// One kind of an extension's permissions, folded; also in the import's review (DEV-1300).
public struct ExtensionPermissionsList: View {
	public let title: String
	public let permissions: BrowserExtension.Permissions

	public init(
		title: String,
		permissions: BrowserExtension.Permissions
	) {
		self.title = title
		self.permissions = permissions
	}

	public var body: some View {
		DisclosureGroup(title) {
			VStack(alignment: .leading, spacing: 5) {
				if permissions.apis.isEmpty && permissions.hosts.isEmpty {
					Text(localized: .appUI.extensions.none)
						.foregroundStyle(.secondary)
				}

				if !permissions.apis.isEmpty {
					Text(localized: .appUI.extensions.apis)
						.fontWeight(.medium)

					ForEach(Array(permissions.apis.enumerated()), id: \.offset) { _, name in
						Text(name)
							.textSelection(.enabled)
					}
				}

				if !permissions.hosts.isEmpty {
					Text(localized: .appUI.extensions.hosts)
						.fontWeight(.medium)

					ForEach(Array(permissions.hosts.enumerated()), id: \.offset) { _, host in
						Text(host)
							.textSelection(.enabled)
					}
				}
			}
			.font(.caption)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.top, 5)
		}
	}
}
