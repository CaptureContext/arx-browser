import AppKit
@testable import AppUI
import BrowserCore
import Foundation
import SidebarFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-736: a click on a tab highlights it at once, as a click on a favorite does.
///
/// A row's click and double-click actions run inside the click's own `sendEvent`, so each test
/// checks them right after the click instead of after a wall-clock spin of the run loop (DEV-1303).
/// The run loop only settles the window and lets a waiting gesture's timer fire.
@MainActor
@Suite(.renderTurn, .dependencies, .enabled(if: NativeEvents.areAvailable, "Needs a window server to deliver mouse events"))
internal struct SidebarRowClickTests {
	/// A tab row's double-click renames it, and the single click used to wait out the system's
	/// double-click interval, about half a second, before selecting.
	@Test
	internal func aClickSelectsATabWithoutWaitingForADoubleClick() async throws {
		let log = ActionLog()
		let (window, host) = Self.host(SidebarRow(item: SidebarItem(id: .tab(UUID(1)), title: "Tab")) { log.actions.append($0) })
		defer { window.close() }

		try await click(window, count: 1)
		#expect(log.selections == [.tab(UUID(1))], "\(PointerState.current)")
		host.layoutSubtreeIfNeeded()

		// A double-click selects only that same tab.
		try await click(window, count: 2)
		Self.runLoop(for: NSEvent.doubleClickInterval + 0.1)
		#expect(Set(log.selections) == [.tab(UUID(1))])
	}

	@Test
	internal func aDoubleClickStillRenames() async throws {
		let log = ActivationLog()
		let (window, _) = Self.host(
			Color.white.modifier(SidebarActivation(
				isFolder: false,
				activate: { log.events.append("activate") },
				rename: { log.events.append("rename") }
			))
		)
		defer { window.close() }

		try await click(window, count: 1)
		#expect(log.events == ["activate"], "\(PointerState.current)")
		try await click(window, count: 2)
		#expect(log.events.contains("rename"))
	}

	@Test
	internal func aClickOnAFolderStillTogglesIt() async throws {
		let log = ActionLog()
		let (window, _) = Self.host(SidebarRow(item: SidebarItem(id: .folder(UUID(2)), title: "Folder")) { log.actions.append($0) })
		defer { window.close() }

		try await click(window, count: 1)
		#expect(log.toggles == [.folder(UUID(2))], "\(PointerState.current)")
	}

	/// The full run on 21 Nov: another test held the pointer while this suite clicked, and the click
	/// never reached the row. A modal session holds it the same way; the click waits for it to end.
	@Test
	internal func aClickSentWhileAModalSessionHoldsThePointerWaitsForIt() async throws {
		let log = ActionLog()
		let (window, _) = Self.host(SidebarRow(item: SidebarItem(id: .tab(UUID(3)), title: "Tab")) { log.actions.append($0) })
		defer { window.close() }
		let panel = NSPanel(
			contentRect: .init(x: -9_000, y: -9_000, width: 10, height: 10),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		panel.isReleasedWhenClosed = false
		defer { panel.close() }
		let session: NSApplication.ModalSession = NSApp.beginModalSession(for: panel)
		#expect(!PointerState.isFree)
		Task { @MainActor in
			try await Task.sleep(for: .milliseconds(50))
			NSApp.endModalSession(session)
		}

		try await click(window, count: 1)
		#expect(log.selections == [.tab(UUID(3))], "\(PointerState.current)")
	}

	/// In the Library's columns, selecting closes the Library before a second click could land,
	/// so a click there waits to see whether it starts a double-click, and that one renames.
	@Test
	internal func aLibraryColumnWaitsForADoubleClickBeforeSelecting() async throws {
		let log = ActivationLog()
		let (window, _) = Self.host(
			Color.white
				.modifier(SidebarActivation(
					isFolder: false,
					activate: { log.events.append("activate") },
					rename: { log.events.append("rename") }
				))
				.environment(\.sidebarSelectsOnFirstClick, false)
		)
		defer { window.close() }

		try await click(window, count: 1)
		#expect(log.events.isEmpty)
		try await click(window, count: 2)
		#expect(log.events == ["rename"], "\(PointerState.current)")
		// The first click's wait ends without selecting.
		Self.runLoop(for: NSEvent.doubleClickInterval + 0.1)
		#expect(log.events == ["rename"])
	}

	/// Runs the main run loop, which fires a gesture's timers, from a test that awaits.
	private static func runLoop(for interval: TimeInterval) {
		RunLoop.main.run(until: .now.addingTimeInterval(interval))
	}

	private static func host(_ row: some View) -> (NSWindow, NSView) {
		let size = CGSize(width: 260, height: 40)
		let host = NSHostingView(rootView: row.frame(width: size.width, height: size.height))
		host.frame = CGRect(origin: .zero, size: size)

		// Far off every screen, and never key: nothing on the Mac changes while it runs.
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		window.orderFrontRegardless()
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.03))
		}
		return (window, host)
	}

	/// Sends a click once the pointer is free: AppKit has one pointer for the whole test process,
	/// and while another test's modal session or event-tracking loop has it (this test can run inside
	/// either, since both drain the main queue), a click on this window is dropped.
	private func click(
		_ window: NSWindow,
		count: Int
	) async throws {
		try await PointerState.waitUntilFree()
		let point = CGPoint(x: 80, y: 20)
		for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
			let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: type == .mouseMoved ? 0 : count,
				pressure: type == .leftMouseDown ? 1 : 0
			)
			if let event { NSApp.sendEvent(event) }
		}
	}
}

/// Whether a synthetic click can reach its window: no modal session and no event-tracking loop
/// (a menu, a drag, a resize) holds the pointer (DEV-1303).
@MainActor
internal enum PointerState {
	internal static var current: String {
		"run loop mode: \(RunLoop.current.currentMode?.rawValue ?? "none"), modal window: \(NSApp.modalWindow.map { "\($0)" } ?? "none")"
	}

	internal static var isFree: Bool {
		NSApp.modalWindow == nil
			&& [nil, .default, .common].contains(RunLoop.current.currentMode)
	}

	/// Returns as soon as the pointer is free, giving the loop that holds it a turn meanwhile.
	internal static func waitUntilFree() async throws {
		let deadline: ContinuousClock.Instant = .now.advanced(by: .seconds(60))
		while !isFree {
			try #require(ContinuousClock.now < deadline, "The pointer stayed taken: \(current)")
			try await Task.sleep(for: .milliseconds(10))
		}
	}
}

@MainActor
private final class ActionLog {
	var actions: [SidebarAction] = []

	var selections: [SidebarItem.ID] {
		actions.compactMap { if case let .select(id) = $0 { id } else { nil } }
	}

	var toggles: [SidebarItem.ID] {
		actions.compactMap { if case let .toggle(id) = $0 { id } else { nil } }
	}
}

@MainActor
private final class ActivationLog {
	var events: [String] = []
}

/// The store side of a click: the tab is selected in the same send.
@Suite(.renderTurn, .dependencies)
@MainActor
internal struct TabSelectionTests {
	@Test
	internal func selectingATabChangesTheSelectionInTheSameSend() async {
		let organization = IntegrationFeatureTests().fixture()
		let second = organization.tabs[1].id
		let store = TestStore(
			initialState: SidebarFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		) {
			SidebarFeature()
		}
		await store.send(.ui(.sidebar(.select(.tab(second.rawValue))))) {
			$0.organization.spaces[0].selectedTabID = second
		}
	}
}

/// Whether this process can put a window on a window server and deliver mouse events to it.
/// A sandboxed or headless runner can't, and the hosted interaction tests skip there.
internal enum NativeEvents {
	internal static var areAvailable: Bool {
		CGSessionCopyCurrentDictionary() != nil && !NSScreen.screens.isEmpty
	}
}
