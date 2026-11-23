import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// What an agent's password sign-in asks the user (DEV-708): the site, which
/// saved account, and whether agents may sign in here without asking next time.
internal struct PasswordSignInApproval: View {
	internal let store: StoreOf<AppFeature>
	internal let requestID: UUID
	internal let listing: PasswordSignInListing

	internal var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(localized: .appUI.automation.passwordSignIn)
			LabeledContent(String.localized(.appUI.automation.passwordSite), value: listing.origin)
			if listing.accounts.count > 1 {
				Picker(
					String.localized(.appUI.automation.passwordAccount),
					selection: Binding(
						get: { listing.selectedAccountID ?? listing.accounts[0].id },
						set: { store.send(.automation(.ui(.passwordAccount(requestID, $0)))) }
					)
				) {
					ForEach(listing.accounts) { account in
						Text(verbatim: Self.name(account)).tag(account.id)
					}
				}
			} else if let account = listing.accounts.first {
				LabeledContent(String.localized(.appUI.automation.passwordAccount), value: Self.name(account))
			}
			Toggle(
				String.localized(.appUI.automation.passwordAllowWithoutAsking(listing.origin)),
				isOn: Binding(
					get: { listing.allowsWithoutAsking },
					set: { store.send(.automation(.ui(.passwordAllowsWithoutAsking(requestID, $0)))) }
				)
			)
			Text(localized: .appUI.automation.passwordSignInWarning)
				.font(.callout)
		}
	}

	internal static func name(_ account: BrowserSavedAccount) -> String {
		account.username.isEmpty ? String.localized(.appUI.passwords.noUsername) : account.username
	}
}

/// Offers to save a password the user just submitted, to the tab's own profile. A pop-up at the
/// bottom of the page (DEV-1260), in the app link prompt's family (DEV-1233): the key, the
/// question and the account, then full-width buttons with Save, the primary one, last.
internal struct PasswordSaveView: View {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID

	internal var body: some View {
		let shown = store.focusedWindowID ?? store.main.id
		if let offer = store.automation.passwordSave, shown == windowID {
			PagePopupCard(
				symbol: offer.isUpdate ? "key.horizontal.fill" : "key.fill",
				title: String.localized(
					offer.isUpdate
					? .appUI.passwords.updateTitle(offer.origin)
					: .appUI.passwords.saveTitle(offer.origin)
				),
				detail: offer.username.isEmpty ? String.localized(.appUI.passwords.noUsername) : offer.username
			) {
				Text(localized: .appUI.passwords.profileOnly)
					.font(.caption)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.frame(maxWidth: .infinity)
			} actions: {
				HStack(spacing: ArxModalMetrics.buttonSpacing) {
					AppLinkPromptButton(
						String.localized(offer.isUpdate ? .appUI.passwords.keepOld : .appUI.passwords.never)
					) {
						store.send(.automation(.ui(.answerPasswordSave(.never))))
					}
					AppLinkPromptButton(String.localized(.appUI.passwords.notNow)) {
						store.send(.automation(.ui(.answerPasswordSave(.notNow))))
					}
				}
				AppLinkPromptButton(
					String.localized(offer.isUpdate ? .appUI.passwords.update : .appUI.passwords.save),
					prominence: .primary,
					keyHint: .return
				) {
					store.send(.automation(.ui(.answerPasswordSave(.save))))
				}
				.keyboardShortcut(.defaultAction)
			}
		}
	}
}
