import AppKit
import SwiftUI

public struct BrowserToolbarButtonStyle: ButtonStyle {
	@SwiftUI.State
	private var hovered: Bool

	@Environment(\.isEnabled)
	private var isEnabled

	public init(hovered: Bool = false) {
		self._hovered = .init(initialValue: hovered)
	}

	public func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.frame(width: BrowserMetrics.Toolbar.buttonSize, height: BrowserMetrics.Toolbar.buttonSize)
			.contentShape(.rect)
			.background(
				isEnabled && (hovered || configuration.isPressed) ? BrowserTheme.hover : .clear,
				in: ArxControlShape()
			)
			.opacity(opacity(isPressed: configuration.isPressed))
			.onHover { hovered = $0 }
	}

	private func opacity(isPressed: Bool) -> Double {
		guard isEnabled else { return BrowserMetrics.State.disabledOpacity }
		return isPressed ? BrowserMetrics.State.pressedOpacity : 1
	}
}

public struct BrowserWindowControls: NSViewRepresentable {
	public init() {}

	public func makeNSView(context: Context) -> WindowControlsView {
		WindowControlsView()
	}

	public func updateNSView(
		_ view: WindowControlsView,
		context: Context
	) {
		view.attachButtons()
	}

	public static func dismantleNSView(
		_ view: WindowControlsView,
		coordinator: Void
	) {
		view.restoreButtons()
	}
}

public final class WindowControlsView: NSView {
	private var attachments: [Attachment] = []
	private var isUpdatingButtons: Bool = false

	public override var mouseDownCanMoveWindow: Bool { true }

	public override func viewWillMove(toWindow newWindow: NSWindow?) {
		if newWindow !== self.window {
			NotificationCenter.default.removeObserver(self)
			self.restoreButtons()
		}
		super.viewWillMove(toWindow: newWindow)
	}

	public override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		if let window = self.window {
			for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification] {
				NotificationCenter.default.addObserver(
					self,
					selector: #selector(windowDidUpdate),
					name: name,
					object: window
				)
			}
		}
		self.attachButtons()
	}

	public override func viewDidEndLiveResize() {
		super.viewDidEndLiveResize()
		self.attachButtons()
	}

	public override func layout() {
		super.layout()
		self.attachButtons()
	}

	@objc
	private func windowDidUpdate(_ notification: Notification) {
		attachButtons()

		if notification.name == NSWindow.didResizeNotification {
			// AppKit can restore the title-bar parent after posting didResize.
			Task { @MainActor [weak self] in
				self?.attachButtons()
			}
		}
	}

	fileprivate func attachButtons() {
		guard let window, !isUpdatingButtons else { return }

		isUpdatingButtons = true
		defer { isUpdatingButtons = false }

		if attachments.isEmpty {
			for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
				guard
					let button = window.standardWindowButton(type),
					let parent = button.superview
				else { continue }
				let attachment: Attachment = .init(
					button: button,
					parent: parent,
					frame: button.frame,
					autoresizingMask: button.autoresizingMask,
					postsFrameChangedNotifications: button.postsFrameChangedNotifications
				)
				attachments.append(attachment)
				button.postsFrameChangedNotifications = true
				NotificationCenter.default.addObserver(
					self,
					selector: #selector(windowDidUpdate),
					name: NSView.frameDidChangeNotification,
					object: button
				)
			}
		}

		// AppKit lays out traffic lights again when its title bar changes. Keep the
		// original controls aligned with this host after that native layout pass.
		for (index, attachment) in attachments.enumerated() {
			let button = attachment.button
			button.autoresizingMask = []
			if button.superview !== self { addSubview(button) }
			let origin = origin(at: index, of: button)
			if button.frame.origin != origin { button.setFrameOrigin(origin) }
		}

		// When the title, appearance or collection behavior changes, AppKit's title-bar layout sets the
		// zoom button back each time it is moved and has the last word. This view's own layout pass runs
		// before the window draws and settles it, so the button never shows in its title-bar spot.
		let isDisplaced: Bool = attachments.enumerated().contains { index, attachment in
			attachment.button.superview !== self
			|| attachment.button.frame.origin != origin(at: index, of: attachment.button)
		}
		if isDisplaced { needsLayout = true }
	}

	private func origin(
		at index: Int,
		of button: NSButton
	) -> NSPoint {
		NSPoint(
			x: CGFloat(index) * 22,
			y: (bounds.height - button.frame.height) / 2
		)
	}

	fileprivate func restoreButtons() {
		NotificationCenter.default.removeObserver(self)
		for attachment in attachments {
			attachment.button.autoresizingMask = attachment.autoresizingMask
			attachment.button.postsFrameChangedNotifications = attachment.postsFrameChangedNotifications
			if attachment.button.superview === self {
				attachment.parent?.addSubview(attachment.button)
				attachment.button.frame = attachment.frame
			}
		}
		attachments.removeAll()
	}

	private struct Attachment {
		fileprivate let button: NSButton
		fileprivate weak var parent: NSView?
		fileprivate let frame: NSRect
		fileprivate let autoresizingMask: NSView.AutoresizingMask
		fileprivate let postsFrameChangedNotifications: Bool

		fileprivate init(
			button: NSButton,
			parent: NSView,
			frame: NSRect,
			autoresizingMask: NSView.AutoresizingMask,
			postsFrameChangedNotifications: Bool
		) {
			self.button = button
			self.parent = parent
			self.frame = frame
			self.autoresizingMask = autoresizingMask
			self.postsFrameChangedNotifications = postsFrameChangedNotifications
		}
	}
}
