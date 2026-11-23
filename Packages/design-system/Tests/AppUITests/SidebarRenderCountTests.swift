#if DEBUG
// Row bodies are counted only in Debug builds.
import AppKit
import BrowserCore
@testable import AppUI
import Foundation
import SwiftUI
import Testing

/// DEV-732: a change in the tab tree re-evaluates only the rows it touches. Every row used to
/// run its body on every change, so tab commands slowed down with each open tab.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct SidebarRenderCountTests {
	@Test
	internal func selectingATabRendersOnlyTheTwoRowsWhoseSelectionChanged() {
		let sidebar = HostedSidebar(selectedID: Self.tab(3))
		defer { sidebar.close() }

		let counts = sidebar.recording { $0.selectedID = Self.tab(7) }
		#expect(Set(counts.keys) == [Self.tab(3), Self.tab(7)], "rendered: \(counts.count) rows")
		#expect(counts.values.allSatisfy { $0 <= 2 }, "\(counts)")
	}

	@Test
	internal func renamingATabRendersOnlyItsRow() {
		let sidebar = HostedSidebar(selectedID: Self.tab(3))
		defer { sidebar.close() }

		let counts = sidebar.recording { $0.titles[Self.tab(20)] = "Renamed" }
		#expect(Set(counts.keys) == [Self.tab(20)], "rendered: \(counts.count) rows")
	}

	@Test
	internal func openingATabRendersOnlyTheNewRowAndTheSelectionChange() {
		let sidebar = HostedSidebar(selectedID: Self.tab(3))
		defer { sidebar.close() }

		let counts = sidebar.recording { state in
			state.extraTabs += 1
			state.selectedID = Self.tab(tabCount)
		}
		#expect(Set(counts.keys) == [Self.tab(3), Self.tab(tabCount)], "rendered: \(counts.count) rows")
	}

	@Test
	internal func turningHoverPreviewsOffBringsBackEveryTooltip() {
		let sidebar = HostedSidebar(selectedID: Self.tab(3))
		defer { sidebar.close() }

		let counts = sidebar.recording { $0.previewsOff = true }
		#expect(counts.count == 71)
	}

	@Test(.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events"))
	internal func anUnchangedRowStillSendsToTheLatestHandler() {
		let sidebar = HostedSidebar(selectedID: Self.tab(3))
		defer { sidebar.close() }

		// A new handler alone changes no row, so no row runs its body to pick it up.
		var received: [SidebarAction] = []
		let counts = sidebar.recording { $0.onAction = { received.append($0) } }
		#expect(counts.isEmpty)

		sidebar.clickRow(atTop: 160)
		#expect(received.contains { $0.is(\.select) || $0.is(\.toggle) }, "\(received)")
	}

	/// DEV-1235: a row's menu is built when it opens, not with the row. A right click still gets
	/// its items.
	@Test(.enabled(if: CGSessionCopyCurrentDictionary() != nil, "Needs a window server to deliver mouse events"))
	internal func aRowsMenuStillHasItsItems() throws {
		let sidebar = HostedSidebar(selectedID: Self.tab(3))
		defer { sidebar.close() }

		let titles = try #require(sidebar.menuTitles(atTop: 160))
		#expect(titles.contains(BrowserCommand.duplicateTab.title), "\(titles)")
		#expect(titles.contains(String.localized(.appUI.common.rename)), "\(titles)")
	}

	internal static func tab(_ index: Int) -> SidebarItem.ID { .tab(uuid(index)) }
}

private let tabCount: Int = 60
private let folderChildren: Int = 10

private func uuid(_ value: Int) -> UUID {
	UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
}

/// The state a window's sidebar is built from; each update rebuilds the sidebar from the top
/// with new closures, as the window does after every store change.
@MainActor
private struct SidebarInputs {
	internal var selectedID: SidebarItem.ID?
	internal var titles: [SidebarItem.ID: String]
	internal var extraTabs: Int
	internal var onAction: (SidebarAction) -> Void
	internal var previewsOff: Bool

	internal init(
		selectedID: SidebarItem.ID? = nil,
		titles: [SidebarItem.ID: String] = [:],
		extraTabs: Int = 0,
		onAction: @escaping (SidebarAction) -> Void = { _ in },
		previewsOff: Bool = false
	) {
		self.selectedID = selectedID
		self.titles = titles
		self.extraTabs = extraTabs
		self.onAction = onAction
		self.previewsOff = previewsOff
	}

	internal var savedItems: [SidebarItem] {
		[
			SidebarItem(
				id: .folder(uuid(10_000)),
				title: "Folder",
				children: (0..<folderChildren).map { index in
					item(.tab(uuid(5_000 + index)), pinned: true)
				},
				isExpanded: true
			),
		]
	}

	internal var unpinnedTabs: [SidebarItem] {
		(0..<(tabCount + extraTabs)).map { index in
			item(SidebarRenderCountTests.tab(index), pinned: false)
		}
	}

	private func item(
		_ id: SidebarItem.ID,
		pinned: Bool
	) -> SidebarItem {
		SidebarItem(
			id: id,
			title: titles[id] ?? "Tab \(id)",
			isPinned: pinned
		)
	}
}

@MainActor
private final class HostedSidebar {
	private var inputs: SidebarInputs
	private let window: NSWindow
	private let host: NSHostingView<AnyView>

	internal init(selectedID: SidebarItem.ID?) {
		self.inputs = .init(selectedID: selectedID)
		let size = CGSize(width: 260, height: 3_600)
		self.host = NSHostingView(rootView: AnyView(EmptyView()))
		host.frame = CGRect(origin: .zero, size: size)

		// Never shown: the window only gives the hosting view somewhere to lay out.
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		render()
		settle()
	}

	internal func update(_ change: (inout SidebarInputs) -> Void) {
		change(&inputs)
		render()
		settle()
	}

	internal func recording(_ change: (inout SidebarInputs) -> Void) -> [SidebarItem.ID: Int] {
		SidebarRenderTrace.startRecording()
		defer { SidebarRenderTrace.stopRecording() }
		update(change)
		return SidebarRenderTrace.counts ?? [:]
	}

	internal func close() {
		window.close()
	}

	/// Clicks a row this far below the top, below the space's heading. The window stays far off
	/// every screen and never becomes key.
	internal func clickRow(atTop offset: CGFloat) {
		window.orderFrontRegardless()
		settle()
		let point = CGPoint(x: 80, y: host.frame.height - offset)
		for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
			let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: type == .mouseMoved ? 0 : 1,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			if let event { NSApp.sendEvent(event) }
		}
		settle()
	}

	/// The titles of the menu a right click opens on the row this far below the top, or nil when
	/// nothing there offers one.
	internal func menuTitles(atTop offset: CGFloat) -> [String]? {
		window.orderFrontRegardless()
		settle()
		let point = CGPoint(x: 80, y: host.frame.height - offset)
		guard
			let event = NSEvent.mouseEvent(
				with: .rightMouseDown,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			),
			let menu = host.hitTest(point)?.menu(for: event) ?? host.menu(for: event)
		else { return nil }

		menu.update()
		return menu.items.map(\.title)
	}

	private func render() {
		let inputs = inputs
		host.rootView = AnyView(
			BrowserSidebar(
				spaceName: "Space",
				savedItems: inputs.savedItems,
				unpinnedTabs: inputs.unpinnedTabs,
				selectedID: inputs.selectedID,
				onAction: { inputs.onAction($0) }
			)

			// New closures on every pass, as the window passes them.
			.environment(\.sidebarTabHoverChanged) { _ in _ = inputs }
			.environment(\.sidebarTabDragChanged) { _ in _ = inputs }
			.environment(\.sidebarHoverPreviews, inputs.previewsOff ? nil : .init(tabs: { _ in _ = inputs; return [:] }))
		)
	}

	private func settle() {
		for _ in 0..<3 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.02))
		}
	}
}
#endif
