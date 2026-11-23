#if DEBUG
import AppKit
import BrowserCore
import Foundation
import LittleArxFeature
import _ComposableArchitecture

/// Little Arx on the macOS desktop Space where the link was clicked (DEV-931). Run by
/// `make little-arx-space-smoke`: a separate fixture app sends two links through LaunchServices,
/// as Slack or Mail would. The first comes from the desktop Space with Arx's main window, the
/// second from the fixture's own full-screen Space, which has no Arx window. The second link
/// must open a new Little Arx on that Space without switching Spaces, and leave the first where
/// it is.
@MainActor
internal final class LittleArxSpaceSmoke {
	internal enum Failure: String, Error {
		case notReady, firstElsewhere, secondElsewhere, firstMoved, mainWindowFollowed
		case spaceSwitched, reused, wrongFocus, unreported, timedOut
	}

	internal static let variable: String = "ARX_LITTLE_ARX_SPACE_SMOKE"

	/// A file the fixture app creates once it has checked the windows from outside.
	internal static let doneVariable: String = "ARX_LITTLE_ARX_SPACE_SMOKE_DONE"

	private var received: [URL] = []

	/// Active Space changes seen so far, and how many there were when each link arrived.
	private var spaceChanges: Int = 0
	private var spaceChangesAtReceipt: [Int] = []
	private var observer: (any NSObjectProtocol)?
	private let done: URL?

	internal init(environment: [String: String]) {
		self.done = environment[Self.doneVariable].map { URL(fileURLWithPath: $0) }
	}

	internal static func isRequested(environment: [String: String]) -> Bool {
		environment[variable] == "1" && environment["ARX_ENGINE_PROFILE"] != nil
	}

	/// Called for every link Arx receives from outside, before it is routed.
	internal func received(_ url: URL) {
		received.append(url)
		spaceChangesAtReceipt.append(spaceChanges)
	}

	internal func run(
		store: StoreOf<AppFeature>,
		mainWindow: @escaping () -> NSWindow?,
		panel: @escaping (UUID) -> NSWindow?,
		render: @escaping () -> Void
	) async throws {
		observer = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.activeSpaceDidChangeNotification,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.spaceChanges += 1 }
		}
		defer {
			if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
		}

		try await wait(.notReady) {
			store.routingInbox.isReady && mainWindow()?.isVisible == true
		}
		guard store.littleWindows.isEmpty else { throw Failure.notReady }

		// The runner starts the fixture app on this line, so it can't wait in a buffer.
		print("ARX_LITTLE_ARX_SPACE_SMOKE_READY")
		fflush(stdout)

		// The first link, clicked on the desktop Space where Arx's main window is.
		let first = try await opened(count: 1, store: store, panel: panel, render: render)
		guard
			let firstPanel = panel(first.id),
			firstPanel.isOnActiveSpace,
			mainWindow()?.isOnActiveSpace == true
		else { throw Failure.firstElsewhere }
		print("ARX_LITTLE_ARX_SPACE_PHASE_DESKTOP")

		// The second link, clicked in a full-screen app on a Space without any Arx window.
		let second = try await opened(count: 2, store: store, panel: panel, render: render)
		try await Task.sleep(for: .seconds(1))
		render()
		guard let secondPanel = panel(second.id), secondPanel.isOnActiveSpace
		else { throw Failure.secondElsewhere }
		guard !firstPanel.isOnActiveSpace else { throw Failure.firstMoved }
		guard mainWindow()?.isOnActiveSpace == false else { throw Failure.mainWindowFollowed }
		guard
			received.count == 2,
			spaceChangesAtReceipt.count == 2,
			spaceChanges == spaceChangesAtReceipt[1]
		else { throw Failure.spaceSwitched }
		guard
			store.littleWindows.ids.elements == [first.id, second.id],
			store.littleWindows[id: first.id]?.tab.id == first.tab.id,
			store.littleWindows[id: first.id]?.spaceID == first.spaceID,
			second.tab.restoration.url == received[1]
		else { throw Failure.reused }
		guard store.focusedWindowID == second.id, secondPanel.isKeyWindow
		else { throw Failure.wrongFocus }
		guard store.littleWindowsOnOtherDesktopSpaces == [first.id]
		else { throw Failure.unreported }
		print("ARX_LITTLE_ARX_SPACE_PHASE_FULL_SCREEN")

		// The fixture checks the same windows from outside; they stay until it's done.
		if let done {
			try await wait(.timedOut, seconds: 120) { FileManager.default.fileExists(atPath: done.path) }
		}
		for id in [second.id, first.id] {
			store.send(.littleWindows(.element(id: id, action: .ui(.close))))
		}
		try await wait(.timedOut) {
			render()
			return store.littleWindows.isEmpty
		}
		print("ARX_LITTLE_ARX_SPACE_SMOKE_SUCCESS")
	}

	/// Waits for the Little Arx the `count`th link opens, shown and holding the keyboard.
	private func opened(
		count: Int,
		store: StoreOf<AppFeature>,
		panel: (UUID) -> NSWindow?,
		render: () -> Void
	) async throws -> LittleArxFeature.State {
		var little: LittleArxFeature.State?
		try await wait(.timedOut, seconds: 90) {
			render()
			guard
				received.count >= count,
				store.littleWindows.count == count,
				let last = store.littleWindows.last,
				last.tab.restoration.url == received[count - 1],
				let window = panel(last.id),
				window.isVisible,
				window.isKeyWindow
			else { return false }

			little = last
			return true
		}
		guard let little else { throw Failure.timedOut }

		return little
	}

	private func wait(
		_ failure: Failure,
		seconds: Int = 60,
		until condition: () -> Bool
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard clock.now < deadline else { throw failure }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
