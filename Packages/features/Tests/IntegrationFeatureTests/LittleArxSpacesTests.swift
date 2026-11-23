import AppKit
import Testing

@testable import AppFeature

/// DEV-1227: Little Arx stays on the macOS Space it opened on, as a document window does, and
/// moves only when the person moves it; the launcher bar and Page PiP follow the person onto
/// every Space, full-screen ones included. ⌥⌘P switches between the two, both ways.
@MainActor
@Suite
internal struct LittleArxSpacesTests {
	@Test
	internal func littleArxStaysOnItsSpace() {
		let panel = LittleArxPanel()
		defer { panel.close() }

		#expect(panel.collectionBehavior == LittleArxPanel.windowBehavior)
		Self.expectStaysOnItsSpace(panel.collectionBehavior)

		// It still floats over other windows on its Space, as it always has.
		#expect(panel.level == .floating)
	}

	@Test
	internal func theLauncherFollowsAndTheWindowItBecomesStays() {
		let panel = LittleArxPanel(commandOnly: true)
		defer { panel.close() }

		#expect(panel.collectionBehavior == LittleArxPanel.launcherBehavior)
		#expect(panel.collectionBehavior.contains(.moveToActiveSpace))
		#expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))

		panel.updatePresentation(commandOnly: false)
		#expect(panel.collectionBehavior == LittleArxPanel.windowBehavior)

		panel.updatePresentation(commandOnly: true)
		#expect(panel.collectionBehavior == LittleArxPanel.launcherBehavior)
	}

	/// ⌥⌘P: as Page PiP it joins every Space, full-screen ones included; back in Little Arx it
	/// stays on the Space it's on again, however many times it switches.
	@Test
	internal func pagePictureInPictureFollowsAndLittleArxStaysAgain() {
		let panel = LittleArxPanel()
		defer { panel.close() }

		for _ in 0..<2 {
			panel.updatePictureInPicture(true, siteKey: nil)
			#expect(panel.isPictureInPicture)
			#expect(panel.collectionBehavior == PagePictureInPicturePanel.collectionBehavior)
			#expect(panel.level == .floating)

			// A presentation update while it's Page PiP leaves Page PiP's behavior alone.
			panel.updatePresentation(commandOnly: false)
			#expect(panel.collectionBehavior == PagePictureInPicturePanel.collectionBehavior)

			panel.updatePictureInPicture(false, siteKey: nil)
			#expect(!panel.isPictureInPicture)
			#expect(panel.collectionBehavior == LittleArxPanel.windowBehavior)
			#expect(panel.level == .floating)
		}
	}

	@Test
	internal func pagePictureInPicturesOwnWindowFollowsOntoEverySpace() {
		let panel = PagePictureInPicturePanel(contentSize: PagePictureInPicturePanel.defaultSize, on: nil, siteKey: nil)
		defer { panel.close() }

		#expect(panel.collectionBehavior == PagePictureInPicturePanel.collectionBehavior)
		#expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
		#expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
		#expect(panel.level == .floating)
	}

	/// What keeps a window on its Space: managed, so neither transient (a floating window's
	/// default) nor stationary, and nothing that moves it onto the active Space or every Space.
	private static func expectStaysOnItsSpace(_ behavior: NSWindow.CollectionBehavior) {
		#expect(behavior.contains(.managed))
		#expect(!behavior.contains(.moveToActiveSpace))
		#expect(!behavior.contains(.canJoinAllSpaces))
		#expect(!behavior.contains(.canJoinAllApplications))
		#expect(!behavior.contains(.transient))
		#expect(!behavior.contains(.stationary))
	}
}
