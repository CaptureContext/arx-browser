import BrowserCore
import SwiftUI

/// Settings › Arx's Member number section beside the identity card (DEV-701): what claiming does,
/// Get your member number, and the privacy policy, then the number once claimed.
///
/// It draws a ``Status`` and sends the person's choices out; SettingsFeature does the claiming.
public struct MemberNumberSection: View {
	/// What the section shows, each in plain words.
	public enum Status: Equatable, Sendable {
		/// No number yet: the explanation and Get your member number.
		case notClaimed

		/// Apple's sign-in is open, or the token is on its way to the server.
		case signingIn(MemberSignInProvider)

		/// This Mac has the number. It stays after a relaunch.
		case claimed(MemberNumber)

		/// The last try didn't finish; Try Again starts over.
		case failed(MemberNumberFailure)
	}

	private let status: Status
	private let providers: [MemberSignInProvider]
	private let claim: (MemberSignInProvider) -> Void

	@Environment(\.openURL)
	private var openURL

	/// `providers` are the sign-ins this build offers; with none, the section says sign-in isn't
	/// set up and the button stays off.
	public init(
		status: Status,
		providers: [MemberSignInProvider],
		claim: @escaping (MemberSignInProvider) -> Void
	) {
		self.status = status
		self.providers = providers
		self.claim = claim
	}

	public var body: some View {
		SettingsSection(
			String.localized(.appUI.settings.identity.member.section),
			caption: caption
		) {
			// The status on its own line and the controls under it: beside the identity card the
			// column is too narrow for both on one line.
			VStack(alignment: .leading, spacing: 8) {
				VStack(alignment: .leading, spacing: 2) {
					Text(title)
						.fixedSize(horizontal: false, vertical: true)
					if let detail {
						Text(detail)
							.font(SettingsGroupMetrics.footerFont)
							.foregroundStyle(.secondary)
					}
				}
				.accessibilityElement(children: .combine)
				accessory
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.settingsGroupRow()
		}
	}

	private var caption: String? {
		guard case .claimed = status else {
			return String.localized(.appUI.settings.identity.member.explanation)
		}
		return nil
	}

	/// The row says where things stand; only a claimed number has a second line.
	private var title: String {
		switch status {
		case .notClaimed:
			providers.isEmpty
			? String.localized(.appUI.settings.identity.member.unavailable)
			: String.localized(.appUI.settings.identity.member.notClaimed)

		case .signingIn:
			String.localized(.appUI.settings.identity.member.signingIn)

		case let .claimed(number):
			number.claimedText

		case let .failed(failure):
			Self.message(for: failure)
		}
	}

	private var detail: String? {
		guard case let .claimed(number) = status else { return nil }

		switch number.provider {
		case .apple: return String.localized(.appUI.settings.identity.member.confirmedWith.apple)
		}
	}

	/// The words for a failed claim.
	public static func message(for failure: MemberNumberFailure) -> String {
		switch failure {
		case .offline: String.localized(.appUI.settings.identity.member.failed.offline)
		case .cancelled: String.localized(.appUI.settings.identity.member.failed.cancelled)
		case .refused: String.localized(.appUI.settings.identity.member.failed.refused)
		case .signInFailed: String.localized(.appUI.settings.identity.member.failed.signIn)
		case .unavailable: String.localized(.appUI.settings.identity.member.unavailable)
		}
	}

	@ViewBuilder
	private var accessory: some View {
		HStack(spacing: 12) {
			switch status {
			case .claimed:
				EmptyView()

			case .signingIn:
				ProgressView()
					.controlSize(.small)
					.accessibilityLabel(Text(localized: .appUI.settings.identity.member.signingIn))

			case .notClaimed:
				claimButton(String.localized(.appUI.settings.identity.member.claim))

			case .failed:
				claimButton(String.localized(.appUI.settings.identity.member.tryAgain))
			}
			privacyPolicy
		}
	}

	private var privacyPolicy: some View {
		Button(String.localized(.appUI.settings.identity.member.privacyPolicy)) {
			openURL(ArxService.privacyPolicy)
		}
		.buttonStyle(.link)
		.fixedSize()
		.help(ArxService.privacyPolicy.absoluteString)
	}

	/// Signs in with the build's provider at once: Apple, the only one (DEV-1323).
	private func claimButton(_ label: String) -> some View {
		Button(label) {
			if let provider = providers.first { claim(provider) }
		}
		.disabled(providers.isEmpty)
		.fixedSize()
	}
}
