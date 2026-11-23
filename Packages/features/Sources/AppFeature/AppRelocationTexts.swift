import AppRelocationClient
import AppUI

extension AppRelocationClient.Texts {
	/// The move-to-Applications prompts from AppUI's catalog (DEV-1291).
	public static var localized: Self {
		.init(
			promptTitle: String.localized(.appUI.relocation.promptTitle),
			promptMessage: String.localized(.appUI.relocation.promptMessage),
			move: String.localized(.appUI.relocation.move),
			notNow: String.localized(.appUI.relocation.notNow),
			dontAskAgain: String.localized(.appUI.relocation.dontAskAgain),
			failureTitle: String.localized(.appUI.relocation.failureTitle),
			failureMessage: String.localized(.appUI.relocation.failureMessage),
			ok: String.localized(.appUI.common.ok)
		)
	}
}
