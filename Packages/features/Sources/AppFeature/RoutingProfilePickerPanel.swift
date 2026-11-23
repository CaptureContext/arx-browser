import AppKit
import AppUI

/// The borderless panel that holds the profile picker at the pointer (DEV-858). Like Little
/// Arx, it takes the keyboard without activating Arx, so it never raises Arx's other windows
/// or leaves a full-screen app's Space. It has no window controls and closes once it loses focus.
@MainActor
internal final class RoutingProfilePickerPanel: NSPanel {
	internal static let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]

	/// Called when the panel becomes key, so deferred requests to focus another window, such as
	/// Picture in Picture's Return to Tab, give way to it.
	internal var onBecomeKey: (() -> Void)?

	/// Called when the panel stops being key: a click elsewhere, or another window taking the
	/// keyboard. Cleared before the panel closes itself.
	internal var onResignKey: (() -> Void)?

	/// Called for Esc that the picker's view didn't handle itself, such as Esc pressed as the
	/// panel opens, before SwiftUI has seen its search field take the keyboard. Cleared before
	/// the panel closes itself.
	internal var onCancel: (() -> Void)?

	/// Called for ⌘1–⌘9 with the digit, before the menu bar can take the keys.
	internal var onOpenNumber: ((Int) -> Void)?

	/// `size` is the content's, shadow room included: the Runway's fitting size with every
	/// option listed. Filtering only shortens the list inside it.
	internal init(
		size: NSSize,
		anchor: CGPoint = NSEvent.mouseLocation
	) {
		let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
		let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
		super.init(
			contentRect: Self.frame(
				at: anchor,
				size: size,
				visible: visible
			),
			styleMask: Self.style,
			backing: .buffered,
			defer: false
		)

		self.isReleasedWhenClosed = false
		self.isFloatingPanel = true
		self.hidesOnDeactivate = false
		self.becomesKeyOnlyIfNeeded = false
		self.level = .floating
		self.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
		self.isOpaque = false
		self.backgroundColor = .clear
		self.hasShadow = false
	}

	/// The Runway's top-left corner at the pointer, the whole panel inside the screen's usable area.
	internal static func frame(
		at point: CGPoint,
		size: NSSize,
		visible: NSRect
	) -> NSRect {
		let inset = BrowserMetrics.LittleArx.Runway.shadowInset
		let x = min(max(point.x - inset, visible.minX), max(visible.minX, visible.maxX - size.width))
		let top = min(max(point.y + inset, visible.minY + size.height), visible.maxY)
		return .init(x: x, y: top - size.height, width: size.width, height: size.height)
	}

	internal override var canBecomeKey: Bool { true }
	internal override var canBecomeMain: Bool { false }

	internal override func becomeKey() {
		super.becomeKey()
		focusSearchField()
		onBecomeKey?()
	}

	/// Gives the keyboard to the search field unless a field already has it. The view's focus on
	/// appear depends on when SwiftUI first lays the panel out, which isn't tied to it becoming
	/// key, so the panel doesn't rely on it alone.
	internal func focusSearchField() {
		guard !(firstResponder is NSTextView), let contentView else { return }

		// SwiftUI creates the field on its first layout, which may not have happened yet.
		contentView.layoutSubtreeIfNeeded()
		guard let field = Self.firstEditableField(in: contentView) else { return }

		_ = makeFirstResponder(field)
	}

	private static func firstEditableField(in view: NSView) -> NSTextField? {
		if let field = view as? NSTextField, field.isEditable { return field }
		for subview in view.subviews {
			if let field = firstEditableField(in: subview) { return field }
		}
		return nil
	}

	/// SwiftUI shares one field editor between every window's text fields, so a field that
	/// starts editing in another window takes it from the search field, leaving the panel itself
	/// as first responder and the list to draw a focus ring once a row takes focus (DEV-953).
	/// While the panel is on screen the search field takes the keyboard back on the next turn.
	internal override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
		let made = super.makeFirstResponder(responder)
		if responder == nil || responder === self { reclaimSearchField() }
		return made
	}

	/// Whether the search field is already due to take the keyboard back.
	private var isReclaimingSearchField: Bool = false

	private func reclaimSearchField() {
		guard isVisible, contentView != nil, !isReclaimingSearchField else { return }

		isReclaimingSearchField = true
		Task { @MainActor [weak self] in
			guard let self else { return }
			isReclaimingSearchField = false
			guard isVisible else { return }
			focusSearchField()
		}
	}

	/// ⌘1–⌘9 open a profile directly. Taken here, before the main menu's key equivalents, which
	/// use the same keys.
	internal override func performKeyEquivalent(with event: NSEvent) -> Bool {
		if
			event.type == .keyDown,
			event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
			let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
			(1...9).contains(digit),
			let onOpenNumber
		{
			onOpenNumber(digit)
			return true
		}
		return super.performKeyEquivalent(with: event)
	}

	internal override func cancelOperation(_ sender: Any?) {
		onCancel?()
	}

	internal override func resignKey() {
		super.resignKey()
		onResignKey?()
	}
}
