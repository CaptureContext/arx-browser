import AppKit
import SwiftUI

/// The raised glass that controls floating over a page or a list are drawn in (DEV-1275,
/// DEV-1272): an ``ArxGlassTile`` on its own piece of the chrome's background, plain rather than
/// textured, with a soft shadow, so it reads the same over any page, light or dark, and a theme's
/// texture stays on the window behind it. The hover previews and the find bar float in it.
public enum ArxFloatingGlass {
	/// A floating search field's and its Close button's height.
	public static let controlHeight: CGFloat = 36

	/// Between a field and the Close beside it.
	public static let controlSpacing: CGFloat = 6
	public static let shadow: BrowserShadow = .init(opacity: 0.16, radius: 10, y: 3)

	/// The field's text and its magnifier, as the command bar's raised search field (DEV-1277).
	public static let fontSize: CGFloat = 13
	internal static let iconSpacing: CGFloat = 7
	internal static let leadingPadding: CGFloat = 13
	internal static let trailingPadding: CGFloat = 10

	/// Between what follows the field's text, such as a match count, and its first control.
	internal static let accessorySpacing: CGFloat = 4

	/// A control's corners at `controlHeight`, as a raised control's.
	public static var controlCornerRadius: CGFloat {
		ArxRaisedShape.cornerRadius(forSide: controlHeight)
	}
}

extension View {
	/// Puts this on floating raised glass over its own piece of the chrome background, with a
	/// soft shadow.
	public func arxFloatingGlass(cornerRadius: CGFloat) -> some View {
		background {
			let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
			ZStack {
				shape
					.fill(.black)
					.browserShadow(ArxFloatingGlass.shadow)
				BrowserChromeBackground(textured: false)
					.clipShape(shape)
				ArxGlassTile(cornerRadius: cornerRadius)
			}
		}
	}
}

/// A search field on floating glass: a magnifier, the field, what follows it, such as a match
/// count, and controls at its end, such as Previous and Next. The prompt is drawn by hand, in the
/// secondary color, because a plain text field colors its prompt like its text. A folder's hover
/// preview (DEV-1275) and the find bar (DEV-1272) search with it.
public struct ArxGlassSearchField<Field: View, Trailing: View, Accessories: View>: View {
	private let placeholder: String
	private let isEmpty: Bool
	private let onEscape: (() -> Void)?
	private let hasAccessories: Bool
	private let field: Field
	private let trailing: Trailing
	private let accessories: Accessories

	/// - Parameters:
	///   - placeholder: Shown while the field is empty.
	///   - isEmpty: Whether the field's text is empty.
	///   - onEscape: Escape while the field is being edited (DEV-1297). It's answered before the
	///     window dispatches the key, so nothing else in the window can take it first.
	///   - field: The text field, plain, with an empty prompt; its focus and its other keys are
	///     the caller's.
	///   - trailing: After the field, such as a match count. It keeps its width; the field gives
	///     way.
	///   - accessories: Controls at the field's end, `.arxRaised(.item)` buttons as tall as the
	///     field, which sit touching, as a raised group's items do, its inset in from its end.
	public init(
		placeholder: String,
		isEmpty: Bool,
		onEscape: (() -> Void)? = nil,
		@ViewBuilder field: () -> Field,
		@ViewBuilder trailing: () -> Trailing,
		@ViewBuilder accessories: () -> Accessories
	) {
		self.init(
			placeholder: placeholder,
			isEmpty: isEmpty,
			onEscape: onEscape,
			hasAccessories: true,
			field: field(),
			trailing: trailing(),
			accessories: accessories()
		)
	}

	private init(
		placeholder: String,
		isEmpty: Bool,
		onEscape: (() -> Void)?,
		hasAccessories: Bool,
		field: Field,
		trailing: Trailing,
		accessories: Accessories
	) {
		self.placeholder = placeholder
		self.isEmpty = isEmpty
		self.onEscape = onEscape
		self.hasAccessories = hasAccessories
		self.field = field
		self.trailing = trailing
		self.accessories = accessories
	}

	public var body: some View {
		let height = ArxFloatingGlass.controlHeight
		HStack(spacing: 0) {
			HStack(spacing: ArxFloatingGlass.iconSpacing) {
				Image(systemName: "magnifyingglass")
					.font(.system(size: ArxFloatingGlass.fontSize, weight: .medium))
					.foregroundStyle(BrowserTheme.secondary)
					.accessibilityHidden(true)
				ZStack(alignment: .leading) {
					if isEmpty {
						Text(verbatim: placeholder)
							.foregroundStyle(BrowserTheme.secondary)
							.lineLimit(1)
							.allowsHitTesting(false)
							.accessibilityHidden(true)
					}
					field
						.textFieldStyle(.plain)
						.foregroundStyle(BrowserTheme.text)
				}
				.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
				trailing
					.fixedSize()
					.layoutPriority(1)
			}
			.padding(.leading, ArxFloatingGlass.leadingPadding)
			.padding(.trailing, hasAccessories ? ArxFloatingGlass.accessorySpacing : ArxFloatingGlass.trailingPadding)
			if hasAccessories {
				// Touching, as a raised group's items, and its inset from the end, so each one's
				// squircle sits concentric with the field's corners (DESIGN.md).
				HStack(spacing: 0) { accessories }
					.arxRaisedControlHeight(height)
					.fixedSize()
					.layoutPriority(1)
					.padding(.trailing, ArxRaisedPalette.inset)
			}
		}
		.font(.system(size: ArxFloatingGlass.fontSize))
		.frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
		.background {
			if let onEscape {
				ArxFieldEscapeWatcher(onEscape: onEscape)
			}
		}
		.arxFloatingGlass(cornerRadius: ArxFloatingGlass.controlCornerRadius)
	}
}

extension ArxGlassSearchField where Accessories == EmptyView {
	public init(
		placeholder: String,
		isEmpty: Bool,
		onEscape: (() -> Void)? = nil,
		@ViewBuilder field: () -> Field,
		@ViewBuilder trailing: () -> Trailing
	) {
		self.init(
			placeholder: placeholder,
			isEmpty: isEmpty,
			onEscape: onEscape,
			hasAccessories: false,
			field: field(),
			trailing: trailing(),
			accessories: EmptyView()
		)
	}
}

extension ArxGlassSearchField where Trailing == EmptyView, Accessories == EmptyView {
	public init(
		placeholder: String,
		isEmpty: Bool,
		onEscape: (() -> Void)? = nil,
		@ViewBuilder field: () -> Field
	) {
		self.init(placeholder: placeholder, isEmpty: isEmpty, onEscape: onEscape, field: field, trailing: { EmptyView() })
	}
}

extension ArxFloatingGlass {
	/// Whether `field` is a floating search field's text field whose Escape the field answers
	/// (one made with `onEscape`): the hand-check smoke's find phase knows the find field by it,
	/// since its prompt is drawn beside it and the field's own placeholder is empty.
	@MainActor
	public static func isEscapableSearchField(_ field: NSView) -> Bool {
		guard let root = field.window?.contentView?.superview ?? field.window?.contentView else { return false }
		var stack: [NSView] = [root]
		while let view = stack.popLast() {
			if let watcher = view as? ArxFieldEscapeWatcher.WatcherView, watcher.onEscape != nil, watcher.isOver(field) {
				return true
			}
			stack.append(contentsOf: view.subviews)
		}
		return false
	}
}

/// Escape for the text field inside the view it backs, while that field is being edited
/// (DEV-1297). It watches key presses before the window dispatches them, as the command bar's
/// field does (DEV-810): a field's SwiftUI exit command only runs once the window has handed
/// Escape to the field's editor, and in a browser window something can take it on the way.
private struct ArxFieldEscapeWatcher: NSViewRepresentable {
	let onEscape: () -> Void

	func makeNSView(context: Context) -> WatcherView {
		WatcherView()
	}

	func updateNSView(
		_ view: WatcherView,
		context: Context
	) {
		view.onEscape = onEscape
	}

	static func dismantleNSView(
		_ view: WatcherView,
		coordinator: ()
	) {
		view.stop()
	}

	final class WatcherView: NSView {
		var onEscape: (() -> Void)?
		private var monitor: Any?

		override func hitTest(_ point: NSPoint) -> NSView? { nil }

		override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			window == nil ? stop() : start()
		}

		func stop() {
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
		}

		private func start() {
			guard monitor == nil else { return }

			monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
				MainActor.assumeIsolated { self?.handle(event) == true } ? nil : event
			}
		}

		/// Whether `event` is Escape for the field over this view, which then answers it.
		func handle(_ event: NSEvent) -> Bool {
			guard
				let onEscape,
				let window,
				event.window === window,
				event.keyCode == 53,
				event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
				let editor = window.firstResponder as? NSTextView,
				editor.isFieldEditor,
				!editor.hasMarkedText(),
				let field = editor.delegate as? NSView,
				isOver(field)
			else { return false }

			onEscape()
			return true
		}

		/// Whether `field` is the one this view backs: its middle is inside this view.
		func isOver(_ field: NSView) -> Bool {
			let frame = field.convert(field.bounds, to: nil)
			return convert(bounds, to: nil).contains(NSPoint(x: frame.midX, y: frame.midY))
		}
	}
}

/// Close on floating glass, a raised square as tall as the search field beside it.
public struct ArxGlassCloseButton: View {
	private let action: () -> Void

	public init(action: @escaping () -> Void) {
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			Image(systemName: "xmark")
				.font(.system(size: ArxFloatingGlass.fontSize, weight: .medium))
		}
		.buttonStyle(.arxRaised(.square))
		.arxRaisedControlHeight(ArxFloatingGlass.controlHeight)
		.background {
			BrowserChromeBackground(textured: false)
				.clipShape(ArxRaisedShape())
				.background {
					ArxRaisedShape()
						.fill(.black)
						.browserShadow(ArxFloatingGlass.shadow)
				}
		}
		.focusEffectDisabled()
		.help(String.localized(.appUI.common.close))
		.accessibilityLabel(Text(localized: .appUI.common.close))
	}
}
