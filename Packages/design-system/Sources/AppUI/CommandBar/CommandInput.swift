import AppKit
import SwiftUI

/// Leaves marked-text commands with the input method before handling result navigation.
///
/// The field shows only what was typed: there's no inline completion (DEV-1223). The page the
/// text leads toward is the highlighted result instead, so Return still opens it.
internal struct CommandInput: NSViewRepresentable {
	@Binding
	internal var text: String

	internal var focusRequest: Int

	/// Takes focus back with the caret after the text, as when ⌘K's panel closes (DEV-810).
	internal var refocusRequest: Int
	internal var onFocusChanged: (Bool) -> Void
	internal var placeholder: String?
	internal var fontSize: CGFloat
	internal var onTab: () -> Bool

	/// ⌫ in a field that was already empty, outside text composition and key repeat.
	internal var onDeleteWhenEmpty: (() -> Void)?
	internal var onMove: (Int) -> Void

	/// A key with ⌘, ⌥ or ⌃, or ⇧↩, as the bar names it (such as "⌥⌘↩" or "⌃X"). Returns
	/// whether it ran something; other keys go on as usual (DEV-810).
	internal var onShortcut: ((String) -> Bool)?
	internal var onSubmit: () -> Void
	internal var onDismiss: () -> Void

	internal init(
		text: Binding<String>,
		focusRequest: Int,
		refocusRequest: Int = 0,
		onFocusChanged: @escaping (Bool) -> Void,
		placeholder: String? = nil,
		fontSize: CGFloat = BrowserMetrics.CommandBar.inputFontSize,
		onTab: @escaping () -> Bool = { false },
		onDeleteWhenEmpty: (() -> Void)? = nil,
		onMove: @escaping (Int) -> Void,
		onShortcut: ((String) -> Bool)? = nil,
		onSubmit: @escaping () -> Void,
		onDismiss: @escaping () -> Void
	) {
		self._text = text
		self.focusRequest = focusRequest
		self.refocusRequest = refocusRequest
		self.onFocusChanged = onFocusChanged
		self.placeholder = placeholder
		self.fontSize = fontSize
		self.onTab = onTab
		self.onDeleteWhenEmpty = onDeleteWhenEmpty
		self.onMove = onMove
		self.onShortcut = onShortcut
		self.onSubmit = onSubmit
		self.onDismiss = onDismiss
	}

	internal func makeCoordinator() -> Coordinator {
		Coordinator(self)
	}

	internal func makeNSView(context: Context) -> Field {
		let field = Field()
		field.delegate = context.coordinator
		field.isBordered = false
		field.drawsBackground = false
		field.focusRingType = .none

		// Always one line: long addresses scroll, and pasted line breaks can't add rows.
		field.usesSingleLineMode = true
		field.maximumNumberOfLines = 1
		field.lineBreakMode = .byClipping
		field.cell?.wraps = false
		field.cell?.isScrollable = true
		field.font = .systemFont(ofSize: fontSize, weight: .medium)
		field.textColor = .labelColor
		field.placeholderString = String.localized(.appUI.url.search)
		field.setAccessibilityIdentifier("command-bar-input")
		field.setAccessibilityLabel(String.localized(.appUI.url.search))
		return field
	}

	internal func updateNSView(
		_ field: Field,
		context: Context
	) {
		context.coordinator.parent = self
		field.onShortcut = onShortcut
		field.placeholderString = placeholder ?? String.localized(.appUI.url.search)
		if context.coordinator.focusRequest != focusRequest {
			context.coordinator.focusRequest = focusRequest
			field.requestFocus()
		}
		if context.coordinator.refocusRequest != refocusRequest {
			context.coordinator.refocusRequest = refocusRequest

			// The caret goes back after the text.
			field.requestFocus(selecting: NSRange(location: (text as NSString).length, length: 0))
		}
		let editor = field.currentEditor() as? NSTextView
		guard editor?.hasMarkedText() != true else { return }

		guard field.stringValue != text else { return }

		guard let editor else {
			field.stringValue = text
			return
		}
		editor.string = text
		editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
	}

	internal final class Field: NSTextField {
		private var requestedFocus: Bool = false

		/// Runs a result action's key; see `CommandInput.onShortcut`.
		internal var onShortcut: ((String) -> Bool)?
		private var keyMonitor: Any?

		internal override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			updateKeyMonitor()
			guard self.window != nil, !self.requestedFocus else { return }

			self.requestedFocus = true
			self.requestFocus()
		}

		/// Action keys such as ⌥⌘↩ never reach the field editor's commands, and ⌘ and ⌃ keys go to
		/// the menu first, so the field watches key presses while it's being edited (DEV-810).
		private func updateKeyMonitor() {
			if let keyMonitor {
				NSEvent.removeMonitor(keyMonitor)
				self.keyMonitor = nil
			}
			guard window != nil else { return }

			keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				guard let self else { return event }
				return MainActor.assumeIsolated { self.handleShortcut(event) } ? nil : event
			}
		}

		/// Runs `event` as a result action's key when this field is being edited in the key window.
		internal func handleShortcut(_ event: NSEvent) -> Bool {
			guard
				let onShortcut,
				let window,
				event.window === window,
				let editor = currentEditor() as? NSTextView,
				window.firstResponder === editor,
				!editor.hasMarkedText(),
				let key = Coordinator.shortcut(
					modifiers: event.modifierFlags,
					keyCode: event.keyCode,
					characters: event.charactersIgnoringModifiers
				)
			else { return false }

			return onShortcut(key)
		}

		/// The field narrows while it's being edited when the "Ask an agent ⇥" hint comes in beside
		/// it, and widens when the hint goes. AppKit then lays the field editor out again scrolled
		/// back to the start, so the caret at the end of a long address would end up out of view,
		/// as if under the hint. This keeps the selection in view instead (DEV-954).
		internal override func setFrameSize(_ newSize: NSSize) {
			let resized = newSize.width != frame.width
			super.setFrameSize(newSize)
			guard
				resized,
				let editor = currentEditor() as? NSTextView,
				!editor.hasMarkedText()
			else { return }

			// The editor can come back as wide as the field, so it's sized to its line again first.
			if let layout = editor.textLayoutManager {
				layout.ensureLayout(for: layout.documentRange)
			}
			editor.sizeToFit()
			editor.scrollRangeToVisible(editor.selectedRange())
		}

		/// Takes focus and selects all the text, or `range` when one is given.
		internal func requestFocus(selecting range: NSRange? = nil) {
			DispatchQueue.main.async { [weak self] in
				guard let self, let window = self.window else { return }
				window.makeFirstResponder(self)
				guard let range, let editor = self.currentEditor() else {
					self.selectText(nil)
					return
				}
				let length = (editor.string as NSString).length
				let location = min(range.location, length)
				editor.selectedRange = NSRange(location: location, length: min(range.length, length - location))
			}
		}
	}

	internal final class Coordinator: NSObject, NSTextFieldDelegate {
		internal var focusRequest: Int?
		internal var refocusRequest: Int
		internal var parent: CommandInput

		internal init(_ parent: CommandInput) {
			self.parent = parent
			self.refocusRequest = parent.refocusRequest
		}

		internal func controlTextDidBeginEditing(_ notification: Notification) {
			parent.onFocusChanged(true)
		}

		internal func controlTextDidEndEditing(_ notification: Notification) {
			parent.onFocusChanged(false)
		}

		internal func controlTextDidChange(_ notification: Notification) {
			guard let field = notification.object as? NSTextField else { return }

			parent.text = field.stringValue
		}

		internal func control(
			_ control: NSControl,
			textView: NSTextView,
			doCommandBy selector: Selector
		) -> Bool {
			guard !textView.hasMarkedText() else { return false }

			if
				Self.backwardDeletions.contains(selector),
				textView.string.isEmpty,
				let onDeleteWhenEmpty = parent.onDeleteWhenEmpty
			{
				// Holding ⌫ to clear the text must not close the bar once the text is gone:
				// only a fresh press counts.
				if !Self.isKeyRepeat { onDeleteWhenEmpty() }
				return true
			}
			switch selector {
			case #selector(NSResponder.insertTab(_:)): return parent.onTab()
			case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
			case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
			case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
			case #selector(NSResponder.cancelOperation(_:)): parent.onDismiss()
			default: return false
			}
			return true
		}

		/// Deletions toward the start of the field: ⌫, ⌥⌫ and ⌘⌫.
		private static let backwardDeletions: Set<Selector> = [
			#selector(NSResponder.deleteBackward(_:)),
			#selector(NSResponder.deleteBackwardByDecomposingPreviousCharacter(_:)),
			#selector(NSResponder.deleteWordBackward(_:)),
			#selector(NSResponder.deleteToBeginningOfLine(_:)),
			#selector(NSResponder.deleteToBeginningOfParagraph(_:)),
		]

		/// A key as the bar names shortcuts, when it carries ⌘, ⌥ or ⌃, or is ⇧↩: modifiers in the
		/// order ⌃⌥⇧⌘, then ↩ or the uppercased key.
		internal static func shortcut(
			modifiers: NSEvent.ModifierFlags,
			keyCode: UInt16,
			characters: String?
		) -> String? {
			let isReturn = keyCode == 36 || keyCode == 76
			let flags = modifiers.intersection([.control, .option, .shift, .command])
			guard
				!flags.intersection([.control, .option, .command]).isEmpty || (isReturn && flags == .shift)
			else { return nil }

			let key: String
			if isReturn {
				key = "↩"
			} else {
				guard let characters, characters.count == 1 else { return nil }
				key = characters.uppercased()
			}
			var name = ""
			if flags.contains(.control) { name += "⌃" }
			if flags.contains(.option) { name += "⌥" }
			if flags.contains(.shift) { name += "⇧" }
			if flags.contains(.command) { name += "⌘" }
			return name + key
		}

		@MainActor
		private static var isKeyRepeat: Bool {
			// `NSApp` is nil until an application exists, as in unit tests.
			guard let event = NSApp?.currentEvent, event.type == .keyDown else { return false }
			return event.isARepeat
		}
	}
}
