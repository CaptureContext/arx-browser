import BrowserCore
import SwiftUI

/// "Your Arx on every Mac": two Macs around iCloud (`OnboardingICloudIllustration`), and a line
/// saying what sync is doing (DEV-1215).
///
/// Sync with iCloud, Not now, Continue without waiting and Try again are in the footer, which
/// the onboarding window draws.
public struct OnboardingICloudPage: View {
	/// What the line under the illustration says.
	public enum Status: Equatable, Sendable {
		/// Checking the iCloud account, or waiting for the person's choice: the line stays empty.
		case none

		/// The first fetch is running, on this part once it's known.
		case syncing(Stage?)

		/// The first fetch is taking a while.
		case slow(Stage?)

		/// Sync couldn't turn on, a fetch failed, or iCloud can't be reached (`nil`).
		case failed(String?)

		/// iCloud's workspace is here.
		case adopted

		/// iCloud had nothing: this Mac's starts it.
		case empty

		/// Sync goes on in the background.
		case continuedWithoutWaiting

		/// Not now.
		case notNow
	}

	/// The part of the workspace being fetched.
	public enum Stage: Equatable, Sendable {
		case organization
		case preferences
		case history
		case archive
	}

	public let status: Status

	public init(status: Status) {
		self.status = status
	}

	public var body: some View {
		OnboardingPageLayout(
			title: OnboardingStep.iCloud.headline,
			message: OnboardingStep.iCloud.message
		) {
			VStack(spacing: 20) {
				OnboardingICloudIllustration(phase: illustrationPhase)
				statusLine
			}
		}
		.onChange(of: status) { _, status in
			guard let text = Self.text(status) else { return }

			AccessibilityNotification.Announcement(text).post()
		}
	}

	/// What the illustration shows: the other Mac empty until sync starts, filling in while it
	/// runs or goes on in the background, and complete once iCloud's Arx is here.
	private var illustrationPhase: OnboardingICloudIllustration.Phase {
		switch status {
		case .none, .failed, .notNow: .ready
		case .syncing, .slow, .continuedWithoutWaiting: .syncing
		case .adopted, .empty: .done
		}
	}

	@ViewBuilder
	private var statusLine: some View {
		Group {
			switch status {
			case .none:
				// Keeps the line's height, so the page doesn't move once it's syncing.
				Text(verbatim: " ")
					.accessibilityHidden(true)

			case .syncing, .slow:
				HStack(spacing: 8) {
					ProgressView()
						.controlSize(.small)
					Text(Self.text(status) ?? "")
				}

			case .failed:
				Label {
					Text(Self.text(status) ?? "")
				} icon: {
					Image(systemName: "exclamationmark.icloud")
						.foregroundStyle(.orange)
				}

			case .adopted, .empty, .continuedWithoutWaiting:
				Label {
					Text(Self.text(status) ?? "")
				} icon: {
					Image(systemName: "checkmark.icloud")
						.foregroundStyle(.green)
				}

			case .notNow:
				Text(Self.text(status) ?? "")
			}
		}
		.font(.callout)
		.foregroundStyle(.secondary)
		.multilineTextAlignment(.center)
		.fixedSize(horizontal: false, vertical: true)
		.frame(maxWidth: 440)
	}

	private static func text(_ status: Status) -> String? {
		switch status {
		case .none:
			nil

		case let .syncing(stage):
			stageText(stage)

		case let .slow(stage):
			String.localized(.appUI.onboarding.iCloud.slow(stageText(stage)))

		case let .failed(message?):
			String.localized(.appUI.onboarding.iCloud.failed(message))

		case .failed(nil):
			String.localized(.appUI.onboarding.iCloud.unreachable)

		case .adopted:
			String.localized(.appUI.onboarding.iCloud.adopted)

		case .empty:
			String.localized(.appUI.onboarding.iCloud.empty)

		case .continuedWithoutWaiting:
			String.localized(.appUI.onboarding.iCloud.inBackground)

		case .notNow:
			String.localized(.appUI.onboarding.iCloud.notNowNote)
		}
	}

	private static func stageText(_ stage: Stage?) -> String {
		switch stage {
		case nil: String.localized(.appUI.onboarding.iCloud.connecting)
		case .organization: String.localized(.appUI.onboarding.iCloud.fetchingOrganization)
		case .preferences: String.localized(.appUI.onboarding.iCloud.fetchingPreferences)
		case .history: String.localized(.appUI.onboarding.iCloud.fetchingHistory)
		case .archive: String.localized(.appUI.onboarding.iCloud.fetchingArchive)
		}
	}
}
