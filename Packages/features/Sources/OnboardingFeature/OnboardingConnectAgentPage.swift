import AgentClient
import AppUI
import ChatFeature
import SwiftUI
import _ComposableArchitecture

/// One row per provider with its status and, when it's ready, Connect.
///
/// Every control is a standard button, so the page works with the keyboard and VoiceOver.
/// Each row reads as one element: the provider, its status and what to do next.
internal struct OnboardingConnectAgentPage: View {
	internal let store: StoreOf<OnboardingConnectAgent>

	internal var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			VStack(spacing: 0) {
				ForEach(Array(store.providers.enumerated()), id: \.element) { index, provider in
					if index > 0 {
						Divider()
					}
					row(provider)
				}
			}
			.background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
			.accessibilityElement(children: .contain)
			.accessibilityLabel(Text(localized: .appUI.onboarding.connectAgent.list))

			HStack(alignment: .firstTextBaseline, spacing: 12) {
				Text(localized: .appUI.onboarding.connectAgent.note)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 0)
				Button(String.localized(.appUI.onboarding.connectAgent.checkAgain)) {
					store.send(.ui(.checkAgain))
				}
				.disabled(store.isChecking)
			}
		}
		.frame(maxWidth: 520)
		.task { store.send(.ui(.task)) }
	}

	private func row(_ provider: AgentProvider) -> some View {
		let status: OnboardingConnectAgent.Status? = store.state.status(of: provider)
		let isConnected: Bool = store.connected == provider

		return HStack(alignment: .center, spacing: 12) {
			Image(systemName: provider.symbol)
				.font(.title2)
				.frame(width: 32)
				.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 2) {
				HStack(spacing: 8) {
					Text(provider.title).font(.headline)
					Text(statusTitle(status, isConnected: isConnected))
						.font(.caption.weight(.medium))
						.foregroundStyle(status?.isReady == true ? Color.green : Color.secondary)
				}
				if let detail = detail(status, provider: provider) {
					Text(detail)
						.font(.callout)
						.foregroundStyle(.secondary)
						.textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.accessibilityElement(children: .combine)

			Spacer(minLength: 0)

			if status?.isReady == true, !isConnected {
				Button(String.localized(.appUI.onboarding.connectAgent.connect)) {
					store.send(.ui(.connect(provider)))
				}
				.accessibilityLabel(Text(localized: .appUI.onboarding.connectAgent.connectProvider(provider.title)))
			}
		}
		.padding(12)
	}

	private func statusTitle(
		_ status: OnboardingConnectAgent.Status?,
		isConnected: Bool
	) -> String {
		if isConnected { return String.localized(.appUI.onboarding.connectAgent.connected) }

		switch status {
		case nil: return String.localized(.appUI.onboarding.connectAgent.checking)
		case .signedIn: return String.localized(.appUI.onboarding.connectAgent.signedIn)
		case .needsPaidPlan: return String.localized(.appUI.onboarding.connectAgent.needsPaidPlan)
		case .notSetUp: return String.localized(.appUI.onboarding.connectAgent.notSetUp)
		case .unavailable: return String.localized(.appUI.onboarding.connectAgent.unavailable)
		}
	}

	private func detail(
		_ status: OnboardingConnectAgent.Status?,
		provider: AgentProvider
	) -> String? {
		switch status {
		case let .signedIn(label):
			label.map { String.localized(.appUI.onboarding.connectAgent.signedInAs($0)) }
				?? String.localized(.appUI.onboarding.connectAgent.ready)

		case .needsPaidPlan:
			String.localized(.appUI.onboarding.connectAgent.paidPlanDetail)

		case .notSetUp(.missing):
			String.localized(.appUI.onboarding.connectAgent.install(provider.toolName))

		case let .notSetUp(.signedOut(instructions)):
			instructions

		case let .notSetUp(.unsupportedSignIn(method)):
			String.localized(.appUI.onboarding.connectAgent.unsupported(provider.toolName, method))

		case .unavailable, nil:
			nil
		}
	}
}
