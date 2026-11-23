import AppKit
@testable import AppUI
import Foundation
import Observation
import SwiftUI
import Testing

/// DEV-1249: a folder opening and closing in the real sidebar, frame by frame. Writes each frame
/// of the motion as a PNG to the directory `ARX_FOLDER_MOTION_FRAMES` names.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views"),
	.enabled(if: ProcessInfo.processInfo.environment["ARX_FOLDER_MOTION_FRAMES"] != nil)
)
internal struct SidebarFolderMotionFramesTests {
	@Test(arguments: [(false, 360), (true, 360), (true, 230)])
	internal func folderOpensAndCloses(selectionInside: Bool, height: Int) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_FOLDER_MOTION_FRAMES"]))
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let scene = FolderScene(selectionInside: selectionInside, height: CGFloat(height))
		defer { scene.close() }
		spin(0.6)

		let name = (selectionInside ? "inside" : "outside") + (height < 300 ? "-short" : "")
		for (step, expanded) in [(0, true), (1, false)] {
			scene.model.isExpanded = expanded
			let start = CACurrentMediaTime()
			for frame in 0..<30 {
				spin(0.004)
				let ms = Int((CACurrentMediaTime() - start) * 1_000)
				try scene.write(to: directory.appending(path: "\(name)-\(step == 0 ? "open" : "close")-\(String(format: "%02d", frame))-\(ms)ms.png"))
			}
			spin(0.4)
		}
	}
}

/// Lets the main run loop turn for `seconds`, so SwiftUI draws the frames due meanwhile.
@MainActor
private func spin(_ seconds: TimeInterval) {
	RunLoop.main.run(until: .now.addingTimeInterval(seconds))
}

@MainActor
@Observable
private final class FolderModel {
	var isExpanded: Bool = false
}

@MainActor
private final class FolderScene {
	let model = FolderModel()
	private let window: NSWindow
	private let host: NSHostingView<AnyView>
	private let size: CGSize

	init(selectionInside: Bool, height: CGFloat) {
		self.size = CGSize(width: 260, height: height)
		let children: [SidebarItem] = (0..<5).map { index in
			SidebarItem(id: .tab(Self.uuid(10 + index)), title: "Folder tab \(index)", isPinned: true)
		}
		let selected: SidebarItem.ID = selectionInside ? children[3].id : .tab(Self.uuid(2))
		let open: [SidebarItem] = (0..<4).map { SidebarItem(id: .tab(Self.uuid($0)), title: "Open tab \($0)", isPinned: false) }
		let model = model
		let size = size
		self.host = NSHostingView(rootView: AnyView(
			FolderSceneView(model: model, children: children, open: open, selected: selected)
				.frame(width: size.width, height: size.height)
		))
		host.frame = CGRect(origin: .zero, size: size)
		window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderFrontRegardless()
	}

	func write(to url: URL) throws {
		host.layoutSubtreeIfNeeded()
		let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: rep)
		try #require(rep.representation(using: .png, properties: [:])).write(to: url)
	}

	func close() { window.close() }

	static func uuid(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
	}
}

private struct FolderSceneView: View {
	let model: FolderModel
	let children: [SidebarItem]
	let open: [SidebarItem]
	let selected: SidebarItem.ID

	var body: some View {
		BrowserSidebar(
			spaceName: "Space",
			savedItems: [
				SidebarItem(id: .tab(FolderScene.uuid(900)), title: "Pinned above", isPinned: true),
				SidebarItem(
					id: .folder(FolderScene.uuid(1000)),
					title: "Folder",
					children: children,
					isExpanded: model.isExpanded
				),
				SidebarItem(id: .tab(FolderScene.uuid(901)), title: "Pinned below", isPinned: true),
			],
			unpinnedTabs: open,
			selectedID: selected,
			onAction: { _ in }
		)
		.environment(\.sidebarTabHoverChanged) { _ in }
		.environment(\.sidebarTabDragChanged) { _ in }
		.environment(\.sidebarHoverPreviews, .init(tabs: { _ in [:] }))
	}
}
