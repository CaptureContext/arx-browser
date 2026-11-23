import AgentClient
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings › Assistant: the providers this Mac is connected to, then under Profiles each
/// profile's default provider and model and how long its chats are kept, which profiles never share.
public struct ChatSettingsView: View {
	/// One store per profile, in Settings' profile order.
	public let stores: [StoreOf<ChatFeature>]
	public let profiles: [Profile]

	@Dependency(\.agentProviders)
	private var providers

	public init(
		stores: [StoreOf<ChatFeature>],
		profiles: [Profile]
	) {
		self.stores = stores
		self.profiles = profiles
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			SettingsSection(
				String.localized(.appUI.chat.settingsProviders),
				caption: String.localized(.appUI.chat.settingsProvidersDetail)
			) {
				ForEach(providers.providers, id: \.self) { provider in
					ChatProviderRow(provider: provider, account: account(provider))
				}
			}
			ChatComposerSettings()
			VStack(alignment: .leading, spacing: 14) {
				Text(localized: .appUI.profile.profiles)
					.font(.system(size: 15, weight: .semibold))
					.padding(.horizontal, 14)
					.accessibilityAddTraits(.isHeader)
				if profiles.isEmpty {
					Text(localized: .appUI.chat.settingsNoProfiles)
						.foregroundStyle(.secondary)
						.padding(.horizontal, 14)
				}
				ForEach(stores, id: \.id) { profile in
					ChatProfileSettings(
						store: profile,
						name: profiles.first { $0.id == profile.id }?.name ?? "",
						providers: providers.providers
					)
				}
			}
		}
	}

	/// Connections are app-wide, so any profile's check answers for all of them.
	private func account(_ provider: AgentProvider) -> AgentAccount? {
		stores.lazy.compactMap { $0.accounts[provider] }.first
	}
}

/// What plain Return does in the chat composer (DEV-798). App-wide, as it's how the person types.
private struct ChatComposerSettings: View {
	@Shared(.chatReturnKey)
	private var returnKey: ChatReturnKeyBehavior

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.chat.settingsComposer),
			footer: String.localized(.appUI.chat.settingsReturnKeyDetail)
		) {
			SettingsRow(String.localized(.appUI.chat.settingsReturnKey)) {
				Menu(title(returnKey)) {
					ForEach(ChatReturnKeyBehavior.allCases, id: \.self) { behavior in
						ChatMenuChoice(title: title(behavior), isSelected: returnKey == behavior) {
							$returnKey.withLock { $0 = behavior }
						}
					}
				}
				.fixedSize()
			}
		}
	}

	private func title(_ behavior: ChatReturnKeyBehavior) -> String {
		switch behavior {
		case .send: String.localized(.appUI.chat.settingsReturnSend)
		case .newLine: String.localized(.appUI.chat.settingsReturnNewLine)
		case .sendOneLiners: String.localized(.appUI.chat.settingsReturnOneLiners)
		}
	}
}

/// A provider's mark and name, the tool Arx runs for it, and whether it's signed in.
private struct ChatProviderRow: View {
	internal let provider: AgentProvider
	internal let account: AgentAccount?

	internal var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 10) {
			Image(systemName: provider.symbol)
				.font(.system(size: 14, weight: .medium))
				.frame(width: 20)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 4) {
				HStack(spacing: 8) {
					Text(provider.title)
					Text(localized: .appUI.chat.settingsProviderThrough(provider.toolName))
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				HStack(spacing: 6) {
					Circle()
						.fill(statusColor)
						.frame(width: 7, height: 7)
						.accessibilityHidden(true)
					Text(statusText)
						.font(.caption)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 0)
		}
		.settingsGroupRow()
		.accessibilityElement(children: .combine)
	}

	private var statusText: String {
		guard let account else { return String.localized(.appUI.onboarding.connectAgent.checking) }
		if case let .signedIn(identity) = account.status, let label = identity.label, let plan = identity.plan {
			return String.localized(.appUI.chat.settingsAccountPlan(label, plan))
		}
		return ChatAccountText.status(account)
	}

	private var statusColor: Color {
		switch account?.status {
		case .signedIn: .green
		case .signedOut, .unsupportedSignIn: .orange
		case .runtimeMissing, .unavailable, nil: .secondary
		}
	}
}

/// One profile's defaults for new chats and how long its chats are kept.
private struct ChatProfileSettings: View {
	internal let store: StoreOf<ChatFeature>
	internal let name: String
	internal let providers: [AgentProvider]

	internal var body: some View {
		SettingsSection(name, footer: String.localized(.appUI.chat.settingsRetentionDetail)) {
			SettingsRow(String.localized(.appUI.chat.settingsDefaultProvider)) {
				Menu {
					ForEach(providers, id: \.self) { provider in
						ChatMenuChoice(title: provider.title, isSelected: store.settings.provider == provider) {
							store.send(.ui(.defaultProviderChanged(provider)))
						}
					}
				} label: {
					Label(store.settings.provider.title, systemImage: store.settings.provider.symbol)
				}
				.fixedSize()
			}
			SettingsRow(String.localized(.appUI.chat.settingsDefaultModel)) {
				Menu(modelTitle) {
					ChatMenuChoice(
						title: String.localized(.appUI.chat.modelDefault),
						isSelected: store.settings.modelID == nil
					) {
						store.send(.ui(.defaultModelChanged(nil)))
					}
					ForEach(store.models[store.settings.provider] ?? []) { model in
						ChatMenuChoice(title: model.title, isSelected: store.settings.modelID == model.id) {
							store.send(.ui(.defaultModelChanged(model.id)))
						}
					}
				}
				.fixedSize()
			}
			SettingsRow(String.localized(.appUI.chat.settingsRetention)) {
				Menu(retentionTitle(store.settings.retention)) {
					ForEach([AgentRetention.ephemeral, .persistent], id: \.self) { retention in
						ChatMenuChoice(title: retentionTitle(retention), isSelected: store.settings.retention == retention) {
							store.send(.ui(.retentionChanged(retention)))
						}
					}
				}
				.fixedSize()
			}
		}
		.task { store.send(.ui(.task)) }
	}

	private var modelTitle: String {
		guard
			let modelID = store.settings.modelID,
			let model = store.models[store.settings.provider]?.first(where: { $0.id == modelID })
		else { return String.localized(.appUI.chat.modelDefault) }

		return model.title
	}

	private func retentionTitle(_ retention: AgentRetention) -> String {
		switch retention {
		case .ephemeral: String.localized(.appUI.chat.settingsEphemeral)
		case .persistent: String.localized(.appUI.chat.settingsPersistent)
		}
	}
}

internal enum ChatAccountText {
	internal static func status(_ account: AgentAccount) -> String {
		switch account.status {
		case let .signedIn(identity):
			identity.label.map { String.localized(.appUI.chat.statusSignedInAs($0)) }
			?? String.localized(.appUI.chat.statusSignedIn)

		case let .signedOut(instructions):
			String.localized(.appUI.chat.statusSignedOut) + " — " + instructions

		case let .unsupportedSignIn(method):
			String.localized(.appUI.chat.statusUnsupported(method))

		case .runtimeMissing:
			String.localized(.appUI.chat.statusMissing)

		case .unavailable:
			String.localized(.appUI.chat.statusUnavailable)
		}
	}
}
