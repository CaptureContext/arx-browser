import AppKit
import SwiftUI

/// A pop-up choice drawn as an Arx button that opens Arx's suggestion dropdown under it, for
/// places where a system pop-up menu looks out of place, such as inside a rule's row. Plain
/// choices among a few fixed options can stay system pickers.
///
/// Click or press Space to open it. While it's open, ↑ and ↓ move the highlight, Return chooses,
/// and Esc, any other key, a click elsewhere, scrolling or leaving the window closes it. VoiceOver reads the title and the current choice, and
/// can step through the choices with increment and decrement without opening the list.
///
/// ```swift
/// ArxDropdown(
///     "Open in",
///     selection: $mode,
///     options: [
///         .init(id: .window, title: "Window", symbol: "macwindow"),
///         .init(id: .littleArx, title: "Little Arx", symbol: "rectangle.inset.topright.filled"),
///     ]
/// )
/// ```
public struct ArxDropdown<ID: Hashable>: View {
	private let title: String

	@Binding
	private var selection: ID

	private let options: [ArxSuggestion<ID>]
	private let size: ArxControlSize?

	@SwiftUI.State
	private var controller: ArxDropdownController<ID> = .init()

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	/// `title` names the choice for VoiceOver; the button shows the chosen option.
	public init(
		_ title: String,
		selection: Binding<ID>,
		options: [ArxSuggestion<ID>],
		size: ArxControlSize? = nil
	) {
		self.title = title
		self._selection = selection
		self.options = options
		self.size = size
	}

	private var selected: ArxSuggestion<ID>? {
		options.first { $0.id == selection }
	}

	public var body: some View {
		Button {
			controller.toggle(options: options, selection: selection) { selection = $0 }
		} label: {
			HStack(spacing: 6) {
				if let symbol = selected?.symbol {
					Image(systemName: symbol)
						.accessibilityHidden(true)
				}
				Text(selected?.title ?? "")
				Image(systemName: "chevron.up.chevron.down")
					.font(.system(size: 9, weight: .bold))
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
			}
		}
		.buttonStyle(.arx(.secondary, size: size))
		.background { ArxDropdownAnchor(controller: controller) }
		.accessibilityLabel(title)
		.accessibilityValue(selected?.title ?? "")
		.accessibilityAddTraits(.isButton)
		.accessibilityAdjustableAction { direction in
			step(direction == .increment ? 1 : -1)
		}
		.onChange(of: isEnabled) { _, isEnabled in
			if !isEnabled { controller.close() }
		}
		.onDisappear { controller.close() }
	}

	private func step(_ offset: Int) {
		guard let index = options.firstIndex(where: { $0.id == selection }) else { return }
		let next = index + offset
		guard options.indices.contains(next) else { return }
		selection = options[next].id
	}
}

/// Owns the open list: its panel, the highlight, and the key and click monitors while open.
@MainActor
internal final class ArxDropdownController<ID: Hashable> {
	internal weak var anchor: NSView?

	private var panel: ArxSuggestionPanel?

	private var monitors: [Any] = []

	private var observers: [NSObjectProtocol] = []

	private var options: [ArxSuggestion<ID>] = []

	private var checked: ID?

	private var highlighted: ID?

	private var choose: (ID) -> Void = { _ in }

	internal init() {}

	internal var isOpen: Bool {
		panel != nil
	}

	internal func toggle(
		options: [ArxSuggestion<ID>],
		selection: ID,
		choose: @escaping (ID) -> Void
	) {
		if isOpen {
			close()
			return
		}
		self.options = options
		self.checked = selection
		self.highlighted = selection
		self.choose = choose
		open()
	}

	private func open() {
		guard let anchor, let window = anchor.window, !options.isEmpty else { return }
		panel = ArxSuggestionPanel(parent: window)
		render()
		monitors.append(
			NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in

				// Only keys meant for the dropdown's own window; others pass on untouched.
				guard event.window === window else { return event }
				return self?.handle(event) == true ? nil : event
			} as Any
		)

		// Scrolling its window moves the button away from the list, so the list closes.
		monitors.append(
			NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self, weak window] event in
				if event.window === window { self?.close() }
				return event
			} as Any
		)

		// So does moving the window, or switching to another one, such as with ⌘`.
		observers.append(
			NotificationCenter.default.addObserver(
				forName: NSWindow.didMoveNotification,
				object: window,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.close() }
			}
		)
		observers.append(
			NotificationCenter.default.addObserver(
				forName: NSWindow.didResignKeyNotification,
				object: window,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.close() }
			}
		)
		monitors.append(
			NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
				guard let self, let panel = self.panel else { return event }
				let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? NSEvent.mouseLocation

				// A click on the button itself toggles it closed through its action.
				if !panel.contains(point), !self.anchorContains(point) {
					self.close()
				}
				return event
			} as Any
		)
	}

	private func render() {
		guard let anchor, let window = anchor.window, let panel else { return }
		let frame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
		let list = ArxSuggestionList(
			options,
			highlighted: highlighted,
			checked: checked,
			minWidth: frame.width
		) { [weak self] suggestion in
			self?.commit(suggestion.id)
		}
		panel.show(list, below: frame)
	}

	private func anchorContains(_ point: CGPoint) -> Bool {
		guard let anchor, let window = anchor.window else { return false }
		return window.convertToScreen(anchor.convert(anchor.bounds, to: nil)).contains(point)
	}

	/// Arrow keys move the highlight, Return chooses it, Esc closes. Any other key, such as Tab
	/// moving focus on, closes the list and passes on, so the list never outlives the focus.
	private func handle(_ event: NSEvent) -> Bool {
		switch event.keyCode {
		case 125: moveHighlight(1)
		case 126: moveHighlight(-1)
		case 36, 76:
			if let highlighted { commit(highlighted) }
		case 53: close()
		default:
			close()
			return false
		}
		return true
	}

	private func moveHighlight(_ offset: Int) {
		let index = options.firstIndex { $0.id == highlighted } ?? (offset > 0 ? -1 : options.count)
		let next = min(max(index + offset, 0), options.count - 1)
		highlighted = options[next].id
		render()
	}

	private func commit(_ id: ID) {
		let choose = self.choose
		close()
		choose(id)
	}

	internal func close() {
		monitors.forEach(NSEvent.removeMonitor)
		monitors = []
		observers.forEach(NotificationCenter.default.removeObserver)
		observers = []

		// Nothing outlives the open list: not the choice callback, which holds the binding.
		choose = { _ in }
		options = []
		panel?.close()
		panel = nil
	}
}

/// Hands the dropdown the AppKit view its button sits on, to anchor the list in screen space.
private struct ArxDropdownAnchor<ID: Hashable>: NSViewRepresentable {
	internal let controller: ArxDropdownController<ID>

	internal func makeNSView(context: Context) -> NSView {
		let view = NSView()
		controller.anchor = view
		return view
	}

	internal func updateNSView(
		_ view: NSView,
		context: Context
	) {
		controller.anchor = view
	}
}
