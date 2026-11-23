import AppKit
import AppUI
import Testing

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct QuitConfirmationPanelTests {
	/// A 0×0 panel ran its modal session unseen: ⌘Q showed nothing and every later quit waited on it.
	@Test
	internal func panelIsSizedToItsDialog() {
		let panel: QuitConfirmationPanel = .make()
		defer { panel.close() }

		#expect(panel.frame.width == QuitConfirmationView.width)
		#expect(panel.frame.height > 100)
	}
}
