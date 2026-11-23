import AppKit
import AppUI
import CustomDump
import SwiftUI
import Testing

@testable import AppFeature

@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct WindowChromeTests {
	@Test
	internal func hostingContentDoesNotReplaceNativeMinimumSizes() {
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 1120, height: 850),
			styleMask: [.titled, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		let minimum = NSSize(width: 760, height: 620)
		window.contentMinSize = minimum
		let host = BrowserHostingView(rootView: Color.clear, minimumSize: minimum)
		window.contentView = host
		host.layoutSubtreeIfNeeded()
		host.rootView.content = Color.red
		host.layoutSubtreeIfNeeded()
		window.update()

		expectNoDifference(window.contentMinSize, minimum)
		#expect(host.sizingOptions == [.minSize])
		expectNoDifference(NSHostingController(rootView: host.rootView).sizeThatFits(in: .zero), minimum)
	}

	@Test
	internal func littleArxMinimumSurvivesCommandToViewerTransition() {
		let panel = LittleArxPanel(commandOnly: true)
		defer { panel.close() }
		let host = BrowserHostingView(rootView: Color.clear, minimumSize: panel.minimumBrowserContentSize)
		panel.contentView = host
		panel.fitCommandBar(height: 138)
		#expect(panel.frame.height == 138)

		panel.updatePresentation(commandOnly: false)
		panel.contentView?.layoutSubtreeIfNeeded()
		panel.update()
		expectNoDifference(panel.contentMinSize, NSSize(width: 600, height: 320))
		expectNoDifference(
			NSHostingController(rootView: host.rootView).sizeThatFits(in: .zero),
			NSSize(width: 600, height: 320)
		)
		let viewerFrame = panel.frame
		panel.fitCommandBar(height: 138)
		expectNoDifference(panel.frame, viewerFrame)
	}

	@Test
	internal func nativeWindowControlsStayCenteredAfterRepeatedResizing() throws {
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 900, height: 700),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		defer { window.close() }
		let root = NSView(frame: .init(x: 0, y: 0, width: 900, height: 700))
		let controls = WindowControlsView(frame: .init(x: 12, y: 656, width: 64, height: 44))
		controls.autoresizingMask = [.minYMargin]
		root.addSubview(controls)
		window.contentView = root

		let sizes: [NSSize] = [
			.init(width: 760, height: 620),
			.init(width: 1200, height: 900),
			.init(width: 800, height: 650),
		]
		for size in sizes {
			window.setContentSize(size)
			root.layoutSubtreeIfNeeded()
			window.update()

			for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
				let button = try #require(window.standardWindowButton(type))
				#expect(button.superview === controls)
				#expect(abs(button.frame.midY - controls.bounds.midY) < 0.5)
				#expect(button.autoresizingMask.isEmpty)
			}
			let close = try #require(window.standardWindowButton(.closeButton))
			close.setFrameOrigin(.init(x: 12, y: -7))
			#expect(abs(close.frame.midY - controls.bounds.midY) < 0.5)
		}
	}

	@Test
	internal func zoomButtonSettlesBeforeDrawingAfterTheTitleBarChanges() throws {
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 900, height: 700),
			styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.titlebarAppearsTransparent = true
		window.titleVisibility = .hidden
		defer { window.close() }
		let root = NSView(frame: .init(x: 0, y: 0, width: 900, height: 700))
		let controls = WindowControlsView(frame: .init(x: 12, y: 656, width: 64, height: 44))
		root.addSubview(controls)
		window.contentView = root
		root.layoutSubtreeIfNeeded()
		let zoom = try #require(window.standardWindowButton(.zoomButton))
		let settled = zoom.frame.origin

		// A space switch changes the window's appearance, which makes AppKit lay out its title bar again.
		for change in [
			{ window.appearance = NSAppearance(named: .aqua) },
			{ window.appearance = NSAppearance(named: .darkAqua) },
			{ window.title = "Space" },
		] as [() -> Void] {
			change()
			window.displayIfNeeded()
			#expect(zoom.superview === controls)
			expectNoDifference(zoom.frame.origin, settled)
		}
	}
}
