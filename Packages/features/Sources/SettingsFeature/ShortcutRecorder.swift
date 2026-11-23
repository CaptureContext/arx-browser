import AppKit
import AppUI
import BrowserCore
import SwiftUI

/// First-responder recording avoids installing a monitor that intercepts other windows.
internal struct ShortcutRecorder: NSViewRepresentable {
	internal let record: (BrowserCore.KeyboardShortcut?) -> Void

	internal init(record: @escaping (BrowserCore.KeyboardShortcut?) -> Void) {
		self.record = record
	}

	internal func makeNSView(context: Context) -> RecorderView {
		let view = RecorderView()
		view.record = record
		return view
	}

	internal func updateNSView(
		_ view: RecorderView,
		context: Context
	) {
		view.record = record
	}

	@MainActor
	internal final class RecorderView: NSView {
		internal var record: ((BrowserCore.KeyboardShortcut?) -> Void)?

		internal override var acceptsFirstResponder: Bool { true }

		internal override init(frame frameRect: NSRect) {
			super.init(frame: frameRect)
			setAccessibilityElement(true)
			setAccessibilityRole(.textField)
			setAccessibilityLabel(String.localized(.appUI.settings.shortcutRecording))
		}

		@available(*, unavailable)
		internal required init?(coder: NSCoder) {
			fatalError("init(coder:) has not been implemented")
		}

		internal override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			window?.makeFirstResponder(self)
		}

		internal override func performKeyEquivalent(with event: NSEvent) -> Bool {
			guard window?.firstResponder === self else { return false }
			keyDown(with: event)
			return true
		}

		internal override func keyDown(with event: NSEvent) {
			if event.keyCode == 53 {
				record?(nil)
				return
			}

			let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
			var modifiers: BrowserCore.KeyboardShortcut.Modifiers = []
			if flags.contains(.command) { modifiers.insert(.command) }
			if flags.contains(.option) { modifiers.insert(.option) }
			if flags.contains(.shift) { modifiers.insert(.shift) }
			if flags.contains(.control) { modifiers.insert(.control) }

			// Arrows, Return and F-keys get their names (DEV-920). ⌃ is left out of the characters,
			// which would otherwise be control codes.
			guard
				let characters = event.characters(byApplyingModifiers: flags.subtracting([.option, .shift, .control])),
				let shortcut = BrowserCore.KeyboardShortcut(characters: characters, modifiers: modifiers)
			else { return }

			record?(shortcut)
		}
	}
}
