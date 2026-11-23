#if DEBUG
import AppKit
import AppUI
import BrowserCore
import ChromiumBrowserEngine
import SwiftUI
import _ComposableArchitecture

/// DEV-1247's Little Arx half, run by `PagePictureInPictureSmoke`: a real Little Arx window,
/// built as BrowserWindow builds one (the panel, `BrowserHostingView` and `AppLittleArxView` on a
/// store of its own), dragged by its URL bar and by its "Open in" button. The window moves,
/// neither control acts, and a click without movement still reaches each: the URL bar opens the
/// command bar, and "Open in" moves the tab to the main window.
@MainActor
internal enum LittleArxDrag {
	internal static func run(
		engine: ChromiumBrowserEngine,
		url: URL,
		profileID: Profile.ID,
		on screen: NSScreen
	) async throws {
		let space = Space(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			name: "Little Arx drag"
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: profileID, name: "Little Arx drag")],
			spaces: [space],
			tabs: []
		)
		let store = Store(initialState: AppFeature.State(main: .init(organization: organization, spaceID: space.id))) {
			AppFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
			$0.browserSurface = engine.surface
		}
		store.send(.ui(.openLittleArx(space.id, url)))
		let child = try require(store.scope(state: \.littleWindows, action: \.littleWindows).first)
		let tabID = child.tab.id

		let visible = screen.visibleFrame
		let panel = LittleArxPanel(origin: .init(x: visible.minX + 420, y: visible.maxY - 120))
		panel.contentView = BrowserHostingView(
			rootView: AppLittleArxView(
				app: store,
				child: child,
				surface: engine.surface,
				onCommandHeightChange: { _ in }
			),
			minimumSize: panel.minimumBrowserContentSize
		)
		defer {
			panel.contentView = nil
			panel.close()
			engine.client.close(tabID)
		}

		// As BrowserWindow shows a new Little Arx: in front, with the keyboard.
		panel.orderFrontRegardless()
		panel.makeKey()
		try await wait { panel.isKeyWindow && engine.isAttached(tabID) } else: {
			report("not-ready", panel: panel, store: store)
		}
		try await Task.sleep(for: .milliseconds(300))

		func commandBarIsPresented() -> Bool {
			store.littleWindows.first?.commandBar.isPresented == true
		}

		// By the URL bar: it moves, and the command bar doesn't open.
		let address = CGPoint(x: panel.frame.width / 2, y: BrowserMetrics.LittleArx.toolbarHeight / 2)
		var before = panel.frame.origin
		try PagePictureInPictureSmoke.drag(from: address, across: screen, in: panel)
		try await PagePictureInPictureSmoke.rests(panel, awayFrom: before)
		try await Task.sleep(for: .milliseconds(200))
		guard !commandBarIsPresented() else { throw PagePictureInPictureSmoke.Failure.controlTriggered }
		try PagePictureInPictureSmoke.click(header: address, in: panel)
		try await wait { commandBarIsPresented() } else: { report("address-click", panel: panel, store: store) }
		store.send(.littleWindows(.element(id: child.id, action: .commandBar(.ui(.dismissed)))))
		try await wait { !commandBarIsPresented() } else: { report("address-dismiss", panel: panel, store: store) }
		print("ARX_LITTLE_ARX_DRAG_ADDRESS_SUCCESS")

		// By "Open in": it moves, and the tab stays in Little Arx.
		before = panel.frame.origin
		try PagePictureInPictureSmoke.drag(from: openIn(in: panel), across: screen, in: panel)
		try await PagePictureInPictureSmoke.rests(panel, awayFrom: before)
		try await Task.sleep(for: .milliseconds(200))
		guard store.littleWindows.count == 1 else { throw PagePictureInPictureSmoke.Failure.controlTriggered }
		try PagePictureInPictureSmoke.click(header: openIn(in: panel), in: panel)
		try await wait { store.littleWindows.isEmpty } else: { report("button-click", panel: panel, store: store) }
		print("ARX_LITTLE_ARX_DRAG_BUTTON_SUCCESS")
	}

	/// The label of "Open in", the main half of the header's last control. From the trailing
	/// edge: the header's 8 point inset, the split button's 2 point inset, its 22 point ⌄ and the
	/// divider, then 20 points into the label.
	private static func openIn(in panel: NSWindow) -> CGPoint {
		.init(
			x: (panel.contentView?.bounds.width ?? panel.frame.width) - 56,
			y: BrowserMetrics.LittleArx.toolbarHeight / 2
		)
	}

	private static func require<Value>(_ value: Value?) throws -> Value {
		guard let value else { throw PagePictureInPictureSmoke.Failure.unexpectedState }
		return value
	}

	private static func wait(
		_ condition: () -> Bool,
		else report: () -> Void
	) async throws {
		for _ in 0..<100 {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		report()
		throw PagePictureInPictureSmoke.Failure.unexpectedState
	}

	private static func report(
		_ step: String,
		panel: NSPanel,
		store: StoreOf<AppFeature>
	) {
		let responder: String = panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
		let keyWindow: String = NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil"
		let commandBar: Bool = store.littleWindows.first?.commandBar.isPresented == true
		let fields: [String] = [
			"step=\(step)",
			"windows=\(store.littleWindows.count)",
			"commandBar=\(commandBar)",
			"key=\(panel.isKeyWindow)",
			"active=\(NSApp.isActive)",
			"keyWindow=\(keyWindow)",
			"responder=\(responder)",
			"frame=\(panel.frame)",
		]
		FileHandle.standardError.write(Data(("ARX_LITTLE_ARX_DRAG_DIAGNOSTIC " + fields.joined(separator: " ") + "\n").utf8))
	}
}
#endif
