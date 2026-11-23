import AppKit
import ImageIO
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The capture overlay, drawn above a page's surface. Pages can't read or style it:
/// it's native views in the window, never content injected into the page.
public struct PageCaptureOverlay: View {
	public let store: StoreOf<PageCaptureFeature>

	@Environment(\.colorScheme)
	private var colorScheme

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// The last block or area in focus, which the cut-out shrinks into when focus clears.
	@SwiftUI.State
	private var lastFocus: PageCaptureRegion?

	public init(store: StoreOf<PageCaptureFeature>) {
		self.store = store
	}

	public var body: some View {
		ZStack(alignment: .topLeading) {
			PageCaptureDimming(
				cutout: PageCaptureGeometry.cutout(for: focus, previous: lastFocus, viewport: store.viewport),
				isCaptured: store.phase == .captured,
				isDark: colorScheme == .dark
			)
			.allowsHitTesting(false)

			PageCaptureInteraction(
				isSelecting: store.phase == .selecting || store.phase == .preparing,
				holdsScrollWhileDragging: store.capturesBeyondViewport,
				isDrawing: store.drawing != nil,
				accessibilityValue: accessibilityValue,
				send: { store.send(.ui($0)) }
			)

			if store.phase != .captured {
				PageCapturePill(text: pillText, isWorking: store.phase == .capturing)
					.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
					.padding(.bottom, PageCaptureMetrics.pillInset)
					.allowsHitTesting(false)
			}

			if
				store.phase == .captured,
				!store.isFullPage || store.capturesBeyondViewport,
				let selection = store.selection,
				let image = store.image
			{
				// The frozen pixels, so what the frame shows is what Copy and Save export. A whole page
				// or an area larger than the viewport is scaled down to fit it (DEV-1208).
				PageCaptureFrozenImage(image: image, displaySize: .init(width: selection.width, height: selection.height))
					.frame(width: selection.width, height: selection.height)
					.clipShape(.rect(cornerRadius: PageCaptureMetrics.frameCornerRadius, style: .continuous))
					.offset(x: selection.x, y: selection.y)
					.allowsHitTesting(false)
					.accessibilityHidden(true)
				PageCaptureDimming(cutout: selection, isCaptured: true, isDark: colorScheme == .dark, dimsPage: false)
					.allowsHitTesting(false)
			}

			if store.phase == .captured, let selection = store.selection {
				menu(beside: selection)
			}
		}
		.onGeometryChange(for: CGSize.self) { $0.size } action: { store.send(.ui(.viewportChanged($0))) }
		.onChange(of: focus) { _, focus in
			if let focus { lastFocus = focus }
		}
		.animation(cutoutAnimation, value: focus)
		.animation(.easeOut(duration: 0.16), value: store.phase)
	}

	/// A short, critically damped spring between blocks; a quicker one while dragging so
	/// the cut-out keeps up with the pointer. Reduce Motion moves it without animating.
	private var cutoutAnimation: Animation? {
		if reduceMotion { return nil }
		return store.drag == nil ? PageCaptureMetrics.snapAnimation : PageCaptureMetrics.dragAnimation
	}

	/// The rectangle the overlay leaves clear and outlines.
	private var focus: PageCaptureRegion? {
		switch store.phase {
		case .captured, .capturing: store.selection
		case .selecting, .preparing: store.drag ?? store.highlighted?.bounds
		}
	}

	private var pillText: String {
		if let message = store.message { return message }
		if store.phase == .capturing {
			return store.isFullPage
			? String.localized(.appUI.capture.capturingPage)
			: String.localized(.appUI.capture.capturing)
		}
		return String.localized(.appUI.capture.instructions)
	}

	private var accessibilityValue: String {
		if let target = store.highlighted {
			return String.localized(.appUI.capture.highlighted(target.role))
		}
		return pillText
	}

	private func menu(beside selection: PageCaptureRegion) -> some View {
		let rows = PageCaptureMenu.rows(
			isFullPage: store.isFullPage,
			allowsFullPage: store.mode == .visible && store.fullPageAvailable,
			allowsChat: store.allowsSendingToChat
		)
		let message = store.menuMessage
		let size = PageCaptureMenu.size(rows: rows.count, hasNote: store.showsProtectedMediaNote || message != nil)
		let origin = PageCaptureGeometry.menuOrigin(for: selection, menu: size, viewport: store.viewport)
		return PageCaptureMenu(
			rows: rows,
			note: store.showsProtectedMediaNote ? String.localized(.appUI.capture.protectedMedia) : nil,
			message: message,
			isWorking: store.isWorking,
			perform: { store.send(.ui($0)) }
		)
		.frame(width: size.width)
		.offset(x: origin.x, y: origin.y)
		.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
	}
}

internal enum PageCaptureMetrics {
	internal static let pillInset: CGFloat = 18
	internal static let frameCornerRadius: CGFloat = 8
	internal static let frameLineWidth: CGFloat = 2
	internal static let hoverLineWidth: CGFloat = 1.5
	internal static let snapAnimation: Animation = .spring(duration: 0.24, bounce: 0)
	internal static let dragAnimation: Animation = .spring(duration: 0.1, bounce: 0)
}

// MARK: - Dimming

/// Dims the page except the focused block or area, which gets a rounded accent outline.
/// With nothing in focus the whole page is dimmed. The cut-out is a `Shape` with
/// animatable bounds, so it glides between blocks and drag rects instead of jumping.
internal struct PageCaptureDimming: View {
	internal let cutout: PageCaptureRegion
	internal let isCaptured: Bool
	internal let isDark: Bool

	/// Off to draw only the outline, above the frozen image.
	internal var dimsPage: Bool = true

	internal var body: some View {
		let rect = CGRect(x: cutout.x, y: cutout.y, width: cutout.width, height: cutout.height)
		ZStack {
			if dimsPage {
				PageCaptureCutoutShape(rect: rect, includesPage: true)
					.fill(Color.black.opacity(isDark ? 0.36 : 0.2), style: .init(eoFill: true))
			}
			PageCaptureCutoutShape(rect: rect, includesPage: false)
				.stroke(
					BrowserTheme.accent,
					lineWidth: isCaptured ? PageCaptureMetrics.frameLineWidth : PageCaptureMetrics.hoverLineWidth
				)
		}
	}
}

/// The rounded cut-out, optionally inside a rectangle covering the whole view so an
/// even-odd fill leaves the cut-out clear. An empty rect draws no cut-out.
internal struct PageCaptureCutoutShape: Shape {
	internal var rect: CGRect
	internal let includesPage: Bool

	internal var animatableData: CGRect.AnimatableData {
		get { rect.animatableData }
		set { rect.animatableData = newValue }
	}

	internal func path(in bounds: CGRect) -> Path {
		var path = Path()
		if includesPage { path.addRect(bounds) }
		guard rect.width >= 0.5, rect.height >= 0.5 else { return path }

		let region = PageCaptureRegion(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
		let radius = PageCaptureGeometry.cornerRadius(for: region, preferred: PageCaptureMetrics.frameCornerRadius)
		path.addRoundedRect(in: rect, cornerSize: .init(width: radius, height: radius), style: .continuous)
		return path
	}
}

// MARK: - Frozen image

/// Decodes the captured PNG once per image, at the size it's shown: a whole page scaled into the
/// frame needs a small part of its pixels (DEV-1208).
internal struct PageCaptureFrozenImage: View {
	internal let image: PageCaptureImage

	/// Points, in the frame.
	internal var displaySize: CGSize?

	@Environment(\.displayScale)
	private var displayScale

	@SwiftUI.State
	private var decoded: (key: Key, image: NSImage)?

	private struct Key: Equatable {
		var png: Data
		var maximumPixels: Int?
	}

	/// The longest side the decoded image needs, or nil for all of it.
	private var maximumPixels: Int? {
		guard let displaySize else { return nil }

		let side = Int((max(displaySize.width, displaySize.height) * max(displayScale, 1)).rounded(.up))
		return side > 0 && side < max(image.width, image.height) ? side : nil
	}

	internal var body: some View {
		let key = Key(png: image.png, maximumPixels: maximumPixels)
		Group {
			if let decoded, decoded.key == key {
				// A device capture's frame changes the shape, so it fits inside the selection
				// (DEV-757); an ordinary capture has the selection's own shape and fills it.
				Image(nsImage: decoded.image)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fit)
			} else {
				Color.clear
			}
		}
		.task(id: key) {
			guard let nsImage = Self.decode(key.png, maximumPixels: key.maximumPixels) else { return }
			decoded = (key, nsImage)
		}
	}

	private static func decode(
		_ png: Data,
		maximumPixels: Int?
	) -> NSImage? {
		guard let maximumPixels else { return NSImage(data: png) }
		guard
			let source = CGImageSourceCreateWithData(png as CFData, nil),
			let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
				kCGImageSourceCreateThumbnailFromImageAlways: true,
				kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
				kCGImageSourceCreateThumbnailWithTransform: true,
			] as CFDictionary)
		else { return NSImage(data: png) }

		return NSImage(cgImage: thumbnail, size: .init(width: thumbnail.width, height: thumbnail.height))
	}
}

// MARK: - Pill

internal struct PageCapturePill: View {
	internal let text: String
	internal let isWorking: Bool

	internal var body: some View {
		HStack(spacing: 8) {
			if isWorking {
				ProgressView().controlSize(.small)
			} else {
				Image(systemName: "camera.viewfinder")
			}
			Text(text)
				.lineLimit(2)
				.multilineTextAlignment(.center)
		}
		.font(.system(size: 13, weight: .medium))
		.foregroundStyle(BrowserTheme.text)
		.padding(.horizontal, 16)
		.padding(.vertical, 9)
		.background(.regularMaterial, in: .capsule)
		.overlay(Capsule().strokeBorder(BrowserTheme.border, lineWidth: 0.5))
		.shadow(color: .black.opacity(0.18), radius: 12, y: 4)
		.accessibilityHidden(true)
	}
}

// MARK: - Menu

internal struct PageCaptureMenu: View {
	internal enum Row: Hashable {
		case copy
		case save
		case edit

		/// Attaches the capture to the window's chat (DEV-798).
		case sendToChat
		case retake
		case fullPage

		internal var title: String {
			switch self {
			case .copy: String.localized(.appUI.capture.copy)
			case .save: String.localized(.appUI.capture.save)
			case .edit: String.localized(.appUI.capture.edit)
			case .sendToChat: String.localized(.appUI.capture.sendToChat)
			case .retake: String.localized(.appUI.capture.retake)
			case .fullPage: String.localized(.appUI.capture.fullPage)
			}
		}

		internal var symbol: String {
			switch self {
			case .copy: "doc.on.doc"
			case .save: "square.and.arrow.down"
			case .edit: "pencil.tip.crop.circle"
			case .sendToChat: "bubble.left.and.text.bubble.right"
			case .retake: "arrow.counterclockwise"
			case .fullPage: "arrow.up.and.down.text.horizontal"
			}
		}

		internal var shortcut: String? {
			switch self {
			case .copy: "⌘C"
			case .save, .edit, .sendToChat, .retake, .fullPage: nil
			}
		}

		internal var action: PageCaptureFeature.Action.UI {
			switch self {
			case .copy: .copy
			case .save: .save
			case .edit: .edit
			case .sendToChat: .sendToChat
			case .retake: .retake
			case .fullPage: .captureFullPage
			}
		}
	}

	internal static let width: CGFloat = 196
	internal static let rowHeight: CGFloat = 28
	internal static let padding: CGFloat = 5
	internal static let noteHeight: CGFloat = 44

	internal static func rows(
		isFullPage: Bool,
		allowsFullPage: Bool,
		allowsChat: Bool = false
	) -> [Row] {
		var rows: [Row] = [.copy, .save, .edit]
		if allowsChat { rows.append(.sendToChat) }
		rows.append(.retake)
		if allowsFullPage, !isFullPage { rows.append(.fullPage) }
		return rows
	}

	internal static func size(rows: Int, hasNote: Bool) -> CGSize {
		.init(
			width: width,
			height: CGFloat(rows) * rowHeight + padding * 2 + (hasNote ? noteHeight : 0)
		)
	}

	internal let rows: [Row]
	internal let note: String?
	internal let message: String?
	internal let isWorking: Bool
	internal let perform: (PageCaptureFeature.Action.UI) -> Void

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ForEach(rows, id: \.self) { row in
				Button { perform(row.action) } label: {
					HStack(spacing: 8) {
						Image(systemName: row.symbol)
							.frame(width: 18)
						Text(row.title)
						Spacer(minLength: 8)
						if let shortcut = row.shortcut {
							Text(shortcut).foregroundStyle(BrowserTheme.secondary)
						}
					}
					.frame(height: Self.rowHeight)
					.padding(.horizontal, 8)
					.contentShape(.rect)
				}
				.buttonStyle(PageCaptureMenuButtonStyle())
				.disabled(isWorking)
			}
			if let text = note ?? message {
				Label(text, systemImage: "exclamationmark.triangle")
					.font(.system(size: 11))
					.foregroundStyle(BrowserTheme.secondary)
					.lineLimit(2)
					.padding(.horizontal, 8)
					.frame(height: Self.noteHeight, alignment: .leading)
			}
		}
		.font(.system(size: 13))
		.foregroundStyle(BrowserTheme.text)
		.padding(Self.padding)
		.background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.strokeBorder(BrowserTheme.border, lineWidth: 0.5)
		)
		.shadow(color: .black.opacity(0.2), radius: 16, y: 6)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.capture.menu))
	}
}

private struct PageCaptureMenuButtonStyle: ButtonStyle {
	@SwiftUI.State
	private var isHovered: Bool = false

	fileprivate func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.fill(isHovered || configuration.isPressed ? BrowserTheme.hover : .clear)
			)
			.onHover { isHovered = $0 }
	}
}

// MARK: - Interaction

/// The AppKit layer that takes the pointer and keyboard while capturing. It sits in the
/// window above the page's surface, so the page never sees these events.
internal struct PageCaptureInteraction: NSViewRepresentable {
	internal let isSelecting: Bool

	/// DEV-1208: a drawn area follows only the scrolls it asks for, so the wheel waits for the drag.
	internal let holdsScrollWhileDragging: Bool

	/// An area is being drawn, or waits on its last scroll after the pointer went up.
	internal let isDrawing: Bool
	internal let accessibilityValue: String
	internal let send: (PageCaptureFeature.Action.UI) -> Void

	internal func makeNSView(context: Context) -> PageCaptureInteractionView {
		let view = PageCaptureInteractionView()
		update(view)
		return view
	}

	internal func updateNSView(_ view: PageCaptureInteractionView, context: Context) {
		update(view)
	}

	private func update(_ view: PageCaptureInteractionView) {
		view.send = send
		view.isSelecting = isSelecting
		view.holdsScrollWhileDragging = holdsScrollWhileDragging
		view.isDrawing = isDrawing
		view.setAccessibilityValue(accessibilityValue)
	}
}

internal final class PageCaptureInteractionView: NSView {
	internal var send: (PageCaptureFeature.Action.UI) -> Void = { _ in }
	internal var isSelecting: Bool = true {
		didSet {
			guard isSelecting != oldValue else { return }
			window?.invalidateCursorRects(for: self)
		}
	}

	internal var holdsScrollWhileDragging: Bool = false
	internal var isDrawing: Bool = false

	private var dragStart: CGPoint?
	private var isDragging: Bool = false
	private var passesThrough: Bool = false

	internal override init(frame: NSRect) {
		super.init(frame: frame)
		setAccessibilityElement(true)
		setAccessibilityRole(.group)
		setAccessibilityLabel(String.localized(.appUI.capture.overlay))
		setAccessibilityHelp(String.localized(.appUI.capture.overlayHint))
	}

	internal required init?(coder: NSCoder) { nil }

	internal override var isFlipped: Bool { true }
	internal override var acceptsFirstResponder: Bool { true }
	internal override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

	internal override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard let window else { return }

		// Take the keyboard from the page so Escape, Return and the arrows reach the overlay.
		DispatchQueue.main.async { [weak self] in
			guard let self, self.window === window else { return }
			window.makeFirstResponder(self)
		}
	}

	internal override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(.init(
			rect: .zero,
			options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
			owner: self
		))
	}

	internal override func hitTest(_ point: NSPoint) -> NSView? {
		passesThrough ? nil : super.hitTest(point)
	}

	internal override func resetCursorRects() {
		addCursorRect(bounds, cursor: isSelecting ? .pageCapture : .arrow)
	}

	internal override func cursorUpdate(with event: NSEvent) {
		(isSelecting ? NSCursor.pageCapture : NSCursor.arrow).set()
	}

	internal override func mouseMoved(with event: NSEvent) {
		send(.pointerMoved(point(event)))
	}

	internal override func mouseDown(with event: NSEvent) {
		window?.makeFirstResponder(self)
		dragStart = point(event)
		isDragging = false
	}

	internal override func mouseDragged(with event: NSEvent) {
		guard let dragStart, isSelecting else { return }

		let current = point(event)
		if !isDragging { isDragging = PageCaptureGeometry.isDrag(from: dragStart, to: current) }
		if isDragging { send(.dragChanged(from: dragStart, to: current)) }
	}

	internal override func mouseUp(with event: NSEvent) {
		defer {
			dragStart = nil
			isDragging = false
		}
		guard let dragStart else { return }

		let current = point(event)
		if isDragging {
			send(.dragEnded(from: dragStart, to: current))
		} else {
			send(.clicked(current))
		}
	}

	/// Scrolling reaches the page underneath; the overlay reads bounds again once it settles. While
	/// the pointer is down, or an area waits on its last scroll, it doesn't (DEV-1208): an area being
	/// drawn counts only the scrolls it made itself, and a wheel scroll would move the page under it
	/// unseen.
	internal override func scrollWheel(with event: NSEvent) {
		guard !holdsScrollWhileDragging || (dragStart == nil && !isDrawing) else { return }

		passesThrough = true
		defer { passesThrough = false }
		if
			let root = window?.contentView,
			let target = root.hitTest(root.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow),
			target !== self
		{
			target.scrollWheel(with: event)
		}
		send(.scrolled)
	}

	internal override func keyDown(with event: NSEvent) {
		let command = event.modifierFlags.contains(.command)
		switch (event.keyCode, command) {
		case (53, _): send(.cancel)
		case (36, false), (76, false): send(.commit)
		case (123, false): send(.move(.previous))
		case (124, false): send(.move(.next))
		case (126, false): send(.move(.parent))
		case (125, false): send(.move(.child))
		default: super.keyDown(with: event)
		}
	}

	/// ⌘C and Edit → Copy reach the overlay through the responder chain while it has focus.
	@objc
	internal func copy(_ sender: Any?) {
		send(.copy)
	}

	internal override func cancelOperation(_ sender: Any?) {
		send(.cancel)
	}

	internal override func accessibilityPerformPress() -> Bool {
		send(.commit)
		return true
	}

	private func point(_ event: NSEvent) -> CGPoint {
		convert(event.locationInWindow, from: nil)
	}
}
