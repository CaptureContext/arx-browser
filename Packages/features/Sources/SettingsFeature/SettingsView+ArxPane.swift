import AppUI
import AppUpdaterClient
import BrowserCore
import DefaultBrowserClient
import SwiftUI

extension SettingsView {
	internal static var arxSearchIndex: [SettingsSearchEntry] {
		[
			.init(
				String.localized(.appUI.settingsSearch.identityCard),
				in: .arx,
				destination: .row(.arx, .identityCard)
			),
			.init(
				String.localized(.appUI.settings.identity.member.section),
				in: .arx,
				destination: .row(.arx, .memberNumber)
			),
			.init(
				String.localized(.appUI.settings.defaultBrowser),
				keywords: SettingsSearchEntry.keywords(String.localized(.appUI.settingsSearch.keywords.defaultBrowser)),
				in: .arx,
				destination: .row(.arx, .defaultBrowser)
			),
		]
	}

	internal var arxPane: some View {
		VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
			HStack(alignment: .top, spacing: 16) {
				SettingsGroupCard {
					ArxIdentityCard(
						style: store.general.identityCardStyle,
						stats: identityCardStats,
						member: store.memberNumber.number,
						memberSince: store.cardMemberSince,
						cycle: { store.send(.ui(.cycleIdentityCardStyle)) },
						share: { store.send(.ui(.shareIdentityCard)) }
					)
					.identityCardSharing(
						isPresented: store.isSharingIdentityCard,
						style: store.general.identityCardStyle,
						stats: identityCardStats,
						member: store.memberNumber.number,
						memberSince: store.cardMemberSince,
						onFinish: { store.send(.ui(.identityCardShareFinished)) }
					)
					.padding(.vertical, 14)
				}
				.fixedSize(horizontal: true, vertical: false)
				.settingsAnchor(.identityCard)

				VStack(alignment: .leading, spacing: SettingsMetrics.cardSpacing) {
					defaultBrowserSection
					memberNumberSection
				}
			}
			#if DEBUG
			if SettingsPage.showsPendingOptions {
				Text(localized: .appUI.settings.reviewNote)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.padding(.horizontal, 14)
			}
			#endif
		}
	}

	private var identityCardStats: ArxIdentityCard.Stats {
		.init(
			profiles: organization.profiles.count,
			spaces: organization.spaces.count,
			tabs: organization.tabs.count
		)
	}

	/// The member number beside the card (DEV-701): Get your member number, the privacy policy,
	/// then the number. The saved one comes back when the pane first shows.
	private var memberNumberSection: some View {
		MemberNumberSection(
			status: store.memberNumber.status,
			providers: store.memberNumber.providers,
			claim: { store.send(.memberNumber(.ui(.claim($0)))) }
		)
		.settingsAnchor(.memberNumber)
		.task { store.send(.memberNumber(.ui(.appeared))) }
	}

	/// Whether Arx opens links from other apps, with Make Default when it doesn't.
	private var defaultBrowserSection: some View {
		SettingsSection(footer: String.localized(.appUI.settings.defaultDescription)) {
			SettingsRow(String.localized(.appUI.settings.defaultBrowser), detail: defaultBrowserStatusText) {
				if store.isRequestingDefaultBrowser {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(Text(localized: .appUI.settings.makeDefaultBrowser))
				}
				if store.defaultBrowser == .isDefault {
					Image(systemName: "checkmark.circle.fill")
						.foregroundStyle(.green)
						.accessibilityHidden(true)
				} else {
					Button(String.localized(.appUI.settings.makeDefaultBrowser)) {
						store.send(.ui(.makeDefaultBrowser))
					}
					.disabled(!canMakeDefaultBrowser)
				}
			}
			.settingsAnchor(.defaultBrowser)
		}
		.task { store.send(.ui(.checkDefaultBrowser)) }
	}

	private var canMakeDefaultBrowser: Bool {
		guard
			case .otherBrowser = store.defaultBrowser,
			!store.isRequestingDefaultBrowser
		else { return false }

		return true
	}

	private var defaultBrowserStatusText: String? {
		if store.defaultBrowserOutcome == .declined, store.defaultBrowser != .isDefault {
			return String.localized(.appUI.settings.defaultBrowserDeclined)
		}

		switch store.defaultBrowser {
		case .isDefault:
			return String.localized(.appUI.settings.defaultBrowserIsArx)

		case let .otherBrowser(name?):
			return String.localized(.appUI.settings.defaultBrowserCurrent(name))

		case .otherBrowser(nil):
			return String.localized(.appUI.settings.defaultBrowserUnknown)

		case .unavailable:
			return String.localized(.appUI.settings.defaultBrowserUnavailable)

		case nil:
			return nil
		}
	}
}
