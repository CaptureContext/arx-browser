#if DEBUG
import BrowserEngineClient
import Foundation

extension BrowserWindow {
	/// Shows the window's bottom pop-ups with made-up content, for screenshots of where they sit
	/// (DEV-1260, DEV-1233). Debug builds only, with `ARX_POPUP_DEMO` set to `save-error`,
	/// `password`, `update` or a comma-separated list of them. The password offer is fake: its
	/// answer reaches the engine with a token it never issued, which it ignores.
	internal func startPagePopupDemo() {
		guard let value = environment["ARX_POPUP_DEMO"] else { return }

		let names: Set<Substring> = Set(value.split(separator: ","))
		Task { @MainActor [store] in

			// After the first page has a tab to offer the password for.
			try? await Task.sleep(for: .seconds(2))
			if names.contains("save-error") {
				store.send(.event(.saveFailed(
					"The operation couldn’t be completed. (BrowserCore.BrowserOrganization.ValidationError error 20.)"
				)))
			}
			guard
				names.contains("password") || names.contains("update"),
				let tabID = store.main.viewer.item.tab?.id
			else { return }

			store.send(.automation(.event(.passwordSaveOffered(.init(
				tabID: tabID,
				token: 0,
				origin: "localhost",
				username: "tester@example.com",
				isUpdate: names.contains("update")
			)))))
		}
	}
}
#endif
