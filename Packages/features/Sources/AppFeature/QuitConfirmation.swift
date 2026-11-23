import AppKit
import SwiftUI
import AppUI
import _ComposableArchitecture

/// Asks before ⌘Q closes every window. Only the user's Quit command asks; the
/// system's quit request (logout, restart) and automation quit directly.
///
/// Quitting stops downloads in progress, which can be resumed next time, and the dialog says so.
/// A download whose server can't resume it would be lost, so the dialog asks then even with its
/// warning off (DEV-966).
public struct QuitConfirmation: Sendable {
	public enum Answer: Equatable, Sendable {
		case cancel
		case quit

		/// Quit, and stop asking from now on.
		case quitAndStopAsking
	}

	/// The downloads quitting would stop, and how many of them it would lose.
	public struct Downloads: Equatable, Sendable {
		public var active: Int
		public var unresumable: Int

		public init(
			active: Int = 0,
			unresumable: Int = 0
		) {
			self.active = active
			self.unresumable = unresumable
		}
	}

	public var confirm: @MainActor @Sendable (Downloads) -> Answer
}

extension QuitConfirmation: DependencyKey {
	public static var liveValue: Self {
		.init { QuitConfirmationPanel.run(downloads: $0) }
	}

	public static var testValue: Self { .init { _ in .quit } }
}

extension DependencyValues {
	public var quitConfirmation: QuitConfirmation {
		get { self[QuitConfirmation.self] }
		set { self[QuitConfirmation.self] = newValue }
	}
}

/// The window that hosts `QuitConfirmationView` as an application-modal dialog.
///
/// Return quits, Esc cancels and ⌘Q pressed again quits.
@MainActor
internal final class QuitConfirmationPanel: NSPanel {
	private var answer: QuitConfirmation.Answer = .cancel

	internal static func run(downloads: QuitConfirmation.Downloads = .init()) -> QuitConfirmation.Answer {
		let panel = make(downloads: downloads)
		panel.center(over: NSApp.keyWindow ?? NSApp.mainWindow)

		panel.makeKeyAndOrderFront(nil)
		NSApp.runModal(for: panel)
		panel.orderOut(nil)
		return panel.answer
	}

	/// The panel sized to its dialog, before it's placed and shown.
	internal static func make(downloads: QuitConfirmation.Downloads = .init()) -> QuitConfirmationPanel {
		let panel = QuitConfirmationPanel(
			contentRect: .zero,
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		panel.isOpaque = false
		panel.backgroundColor = .clear
		panel.hasShadow = true
		panel.level = .modalPanel
		panel.isReleasedWhenClosed = false
		panel.animationBehavior = .alertPanel

		let hosting = NSHostingView(
			rootView: QuitConfirmationView(
				icon: Image(nsImage: NSApp.applicationIconImage),
				downloads: downloads.active,
				unresumableDownloads: downloads.unresumable
			) { [weak panel] choice in
				panel?.finish(Answer(choice))
			}
		)

		// `fittingSize` comes from the intrinsic-size constraints. Without them the panel
		// is 0×0: its modal session runs unseen and blocks every later quit.
		hosting.sizingOptions = [.intrinsicContentSize]
		panel.contentView = hosting
		panel.setContentSize(hosting.fittingSize)
		return panel
	}

	internal override var canBecomeKey: Bool { true }

	internal override func cancelOperation(_ sender: Any?) {
		finish(.cancel)
	}

	internal override func keyDown(with event: NSEvent) {
		switch event.keyCode {
		case 36, 76: finish(.quit) // Return, Enter
		case 53: finish(.cancel) // Esc
		default: super.keyDown(with: event)
		}
	}

	internal override func performKeyEquivalent(with event: NSEvent) -> Bool {
		let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
		if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "q" {
			finish(.quit)
			return true
		}
		return super.performKeyEquivalent(with: event)
	}

	private func finish(_ answer: QuitConfirmation.Answer) {
		self.answer = answer
		NSApp.stopModal()
	}

	private func center(over window: NSWindow?) {
		guard let frame = window?.frame ?? NSScreen.main?.visibleFrame else {
			center()
			return
		}
		setFrameOrigin(
			NSPoint(
				x: frame.midX - self.frame.width / 2,
				y: frame.midY - self.frame.height / 2
			)
		)
	}

	private typealias Answer = QuitConfirmation.Answer
}

extension QuitConfirmation.Answer {
	fileprivate init(_ choice: QuitConfirmationView.Choice) {
		switch choice {
		case .cancel: self = .cancel
		case .quit: self = .quit
		case .quitAndStopAsking: self = .quitAndStopAsking
		}
	}
}
