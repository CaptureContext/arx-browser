import AppKit
import BrowserCore
import SwiftUI
import _Dependencies

/// MainActor-only presentation adapter, separate from engine commands and reducer state.
public struct BrowserSurfaceClient: Sendable {
	public var attach: @MainActor @Sendable (BrowserCore.Tab.ID, NSView) -> Void
	public var release: @MainActor @Sendable (BrowserCore.Tab.ID) -> Void
	public var focus: @MainActor @Sendable (BrowserCore.Tab.ID) -> Void
	public var detach: @MainActor @Sendable (NSView) -> Void

	/// Keeps a page that's likely to be shown next drawing in the window, out of sight in the
	/// given view, so showing it is immediate. `nil` lets the last one go.
	public var stage: @MainActor @Sendable (BrowserCore.Tab.ID?, NSView) -> Void
	public var bindUnhandledEscape: @MainActor @Sendable (
		BrowserCore.Tab.ID,
		NSView,
		BrowserUnhandledEscapeHandler?
	) -> Void

	public init(
		attach: @escaping @MainActor @Sendable (BrowserCore.Tab.ID, NSView) -> Void,
		detach: @escaping @MainActor @Sendable (NSView) -> Void,
		stage: @escaping @MainActor @Sendable (BrowserCore.Tab.ID?, NSView) -> Void = { _, _ in },
		release: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> Void = { _ in },
		focus: @escaping @MainActor @Sendable (BrowserCore.Tab.ID) -> Void = { _ in },
		bindUnhandledEscape: @escaping @MainActor @Sendable (
			BrowserCore.Tab.ID,
			NSView,
			BrowserUnhandledEscapeHandler?
		) -> Void = { _, _, _ in }
	) {
		self.attach = attach
		self.detach = detach
		self.stage = stage
		self.focus = focus
		self.release = release
		self.bindUnhandledEscape = bindUnhandledEscape
	}
}

extension BrowserSurfaceClient: DependencyKey {
	public static var liveValue: Self {
		.init(
			attach: { _, _ in },
			detach: { _ in }
		)
	}
}

extension DependencyValues {
	public var browserSurface: BrowserSurfaceClient {
		get { self[BrowserSurfaceClient.self] }
		set { self[BrowserSurfaceClient.self] = newValue }
	}
}

public struct BrowserSurface: NSViewRepresentable {
	public let tabID: BrowserCore.Tab.ID
	private let client: BrowserSurfaceClient
	private let onFocus: @MainActor () -> Void
	private let isFocused: Bool

	@Environment(\.suppressedBrowserTabs)
	private var suppressedTabs

	@Environment(\.browserSurfaceIsInteractive)
	private var isInteractive

	@Environment(\.browserUnhandledEscape)
	private var unhandledEscape

	@Environment(\.browserSurfaceVisibilityObserver)
	private var visibilityObserver

	public init(
		tabID: BrowserCore.Tab.ID,
		client: BrowserSurfaceClient,
		onFocus: @escaping @MainActor () -> Void = {},
		isFocused: Bool = true
	) {
		self.tabID = tabID
		self.client = client
		self.onFocus = onFocus
		self.isFocused = isFocused
	}

	public func makeCoordinator() -> Coordinator { Coordinator(client: client) }

	public func makeNSView(context: Context) -> NSView {
		context.coordinator.makeHost()
	}

	public func updateNSView(
		_ view: NSView,
		context: Context
	) {
		let isSuppressed = suppressedTabs.contains(tabID)
		context.coordinator.onVisibility = { visibilityObserver?($0) }
		if isInteractive && !isSuppressed {
			context.coordinator.onFocus = onFocus

		} else {
			context.coordinator.onFocus = {}
		}

		context.coordinator.onUnhandledEscape = isInteractive ? unhandledEscape : nil

		context.coordinator.update(
			tabID: tabID,
			isFocused: isFocused && isInteractive,
			isSuppressed: isSuppressed,
			in: view
		)
	}

	public static func dismantleNSView(
		_ view: NSView,
		coordinator: Coordinator
	) {
		coordinator.stop()
		coordinator.client.detach(view)
	}

	@MainActor
	public final class Coordinator {
		fileprivate let client: BrowserSurfaceClient
		fileprivate var onFocus: @MainActor () -> Void = {}
		internal var onVisibility: @MainActor (BrowserSurfaceVisibility) -> Void = { _ in }
		internal var onUnhandledEscape: BrowserUnhandledEscapeHandler?
		private weak var host: NSView?
		private let hostID: UUID = UUID()
		private var lastVisibility: BrowserSurfaceVisibility?
		private var windowObservers: [any NSObjectProtocol] = []
		private var monitor: Any?
		private var tabID: BrowserCore.Tab.ID?
		private var isFocused: Bool = false
		private var isSuppressed: Bool = false
		private var pendingFocus: Bool = false

		internal init(client: BrowserSurfaceClient) { self.client = client }

		internal func makeHost() -> NSView {
			let view = SurfaceHost()
			self.host = view
			observe(view)
			view.onWindowChanged = { [weak self, weak view] in
				guard let self, let view else { return }
				self.attachIfReady(in: view)
				self.reportVisibility(in: view)
			}
			view.onAttachmentChanged = { [weak self, weak view] in
				guard let self, let view else { return }
				self.focusIfReady(in: view)
				self.reportVisibility(in: view)
			}
			return view
		}

		internal func update(
			tabID: BrowserCore.Tab.ID,
			isFocused: Bool,
			isSuppressed: Bool,
			in view: NSView
		) {
			let escapeBindingChanged = self.tabID != tabID || self.isSuppressed != isSuppressed
			let shouldFocus = isFocused && !isSuppressed
			if self.tabID != tabID || self.isFocused != shouldFocus {
				pendingFocus = shouldFocus
			}
			self.tabID = tabID
			self.isFocused = shouldFocus
			self.isSuppressed = isSuppressed

			if isSuppressed {
				client.detach(view)

			} else {
				client.attach(tabID, view)
				focusIfReady(in: view)
			}
			if escapeBindingChanged {
				let handler: BrowserUnhandledEscapeHandler = { [weak self] sourceIsCurrent in
					guard
						let self,
						self.tabID == tabID,
						!self.isSuppressed
					else { return false }

					return self.onUnhandledEscape?(sourceIsCurrent) ?? false
				}
				client.bindUnhandledEscape(tabID, view, isSuppressed ? nil : handler)
			}
			reportVisibility(in: view)
		}

		private func reportVisibility(in view: NSView) {
			guard let tabID else { return }
			let visible: Bool?
			let window: NSWindow? = view.window

			// Docked DevTools shares the host with its page (DEV-733); only the page counts.
			let pages = view.subviews.filter { $0.identifier?.rawValue != "ArxDockedDeveloperTools" }
			let nativeView: NSView? = pages.count == 1 ? pages.first : nil
			if let window, !isSuppressed, let nativeView, nativeView.window === window {
				visible = window.isVisible
				&& !window.isMiniaturized
				&& window.occlusionState.contains(.visible)
				&& !nativeView.isHiddenOrHasHiddenAncestor
				&& nativeView.visibleRect.width > 0
				&& nativeView.visibleRect.height > 0

			} else {
				visible = nil
			}
			let report = BrowserSurfaceVisibility(
				hostID: hostID,
				tabID: tabID,
				isVisible: visible
			)
			guard lastVisibility != report else { return }
			lastVisibility = report

			// Defer out of SwiftUI/AppKit updates. A newer binding supersedes queued reports.
			Task { @MainActor [weak self] in
				guard let self, self.lastVisibility == report else { return }
				self.onVisibility(report)
			}
		}

		private func attachIfReady(in view: NSView) {
			guard
				!isSuppressed,
				let tabID,
				view.window != nil
			else { return }

			// SwiftUI can replace a host before its old view is dismantled. Retry
			// the mount when this replacement acquires its actual window identity.
			client.attach(tabID, view)
			focusIfReady(in: view)
		}

		fileprivate func focusIfReady(in view: NSView) {
			guard
				pendingFocus,
				isFocused,
				let tabID,
				let window = view.window,
				!view.subviews.isEmpty,
				view.subviews.allSatisfy({ $0.window === window })
			else { return }

			pendingFocus = false
			client.focus(tabID)
		}

		fileprivate func observe(_ view: NSView) {
			let names: [Notification.Name] = [
				NSWindow.didChangeOcclusionStateNotification,
				NSWindow.didMiniaturizeNotification,
				NSWindow.didDeminiaturizeNotification,
				NSWindow.didResizeNotification,
				NSApplication.didHideNotification,
				NSApplication.didUnhideNotification,
			]
			for name in names {
				let observer = NotificationCenter.default.addObserver(
					forName: name,
					object: nil,
					queue: .main
				) { [weak self, weak view] _ in
					MainActor.assumeIsolated {
						guard let view else { return }
						self?.reportVisibility(in: view)
					}
				}
				windowObservers.append(observer)
			}

			let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
			monitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self, weak view] event in
				MainActor.assumeIsolated {
					guard
						let self,
						let view,
						let window = view.window,
						event.window === window
					else { return }

					if event.type == .keyDown {
						let responder: NSView? = window.firstResponder as? NSView
						let isInsideHost: Bool = responder.map { $0 === view || $0.isDescendant(of: view) } ?? false
						if isInsideHost { self.onFocus() }

					} else if view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
						self.onFocus()
					}
				}
				return event
			}
		}

		internal func stop() {
			if let tabID, let host {
				client.bindUnhandledEscape(tabID, host, nil)
			}
			onUnhandledEscape = nil
			windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
			windowObservers = []
			lastVisibility = nil
			if let tabID {
				let report = BrowserSurfaceVisibility(
					hostID: hostID,
					tabID: tabID,
					isVisible: nil
				)
				let callback = onVisibility
				Task { @MainActor in callback(report) }
			}
			if let monitor { NSEvent.removeMonitor(monitor) }
			monitor = nil
			tabID = nil
			pendingFocus = false
			isFocused = false
			onFocus = {}
		}
	}
}

/// Drives a `BrowserSurfaceStage` directly, so getting a page ready never re-renders the views
/// around it: a swipe frame that did so lost several frames to layout.
@MainActor
public final class BrowserSurfaceStageController {
	private let client: BrowserSurfaceClient
	fileprivate weak var view: StageView? {
		didSet { apply() }
	}
	private var tabID: BrowserCore.Tab.ID?
	private var isPresented: Bool

	public init(client: BrowserSurfaceClient) {
		self.client = client
		self.tabID = nil
		self.isPresented = false
	}

	/// The window the stage is in, so its owner can tell its own window's events apart.
	public var window: NSWindow? { view?.window }

	/// Keeps a page drawing out of sight, or, presented, shows it until a host takes it.
	public func stage(
		_ tabID: BrowserCore.Tab.ID?,
		isPresented: Bool
	) {
		let changed = self.tabID != tabID
		self.tabID = tabID
		self.isPresented = isPresented
		view?.isPresented = isPresented
		if changed, let view { client.stage(tabID, view) }
	}

	fileprivate func apply() {
		guard let view, view.window != nil else { return }
		view.isPresented = isPresented
		client.stage(tabID, view)
	}
}

/// Where a page waits, drawing but out of sight, until a host shows it.
///
/// Place it over the page it may replace, at the same size, so the page moves across without
/// a resize. It stays transparent unless presented: a hidden view would hide the page too.
/// Presented, it shows its page until a host takes the page. A stage that leaves its window
/// takes its page out with it, which hides the page again.
public struct BrowserSurfaceStage: NSViewRepresentable {
	private let controller: BrowserSurfaceStageController

	public init(controller: BrowserSurfaceStageController) {
		self.controller = controller
	}

	public func makeNSView(context: Context) -> NSView {
		let view = StageView()
		view.onWindowChanged = { [weak controller] in controller?.apply() }
		controller.view = view
		return view
	}

	public func updateNSView(
		_ view: NSView,
		context: Context
	) {
		guard let view = view as? StageView, controller.view !== view else { return }
		controller.view = view
	}
}

/// A page out of sight takes no drags (DEV-1309). AppKit gives a drag to the front-most view
/// registered for its type whatever its opacity or `hitTest`, so a file dropped on the page card
/// went to the transparent page staged over it. The stage takes its page's drag types away while
/// it hides the page and gives them back when it shows the page or lets it go.
@MainActor
private final class StageView: NSView {
	fileprivate var onWindowChanged: (() -> Void)?
	fileprivate var isPresented: Bool = false {
		didSet {
			updateOpacity(pageCount: subviews.count)
			updateDragTypes()
		}
	}

	/// The drag types taken from each staged page while it's out of sight.
	private var takenDragTypes: [ObjectIdentifier: [NSPasteboard.PasteboardType]] = [:]

	internal override init(frame: NSRect) {
		super.init(frame: frame)
		alphaValue = 0
		setAccessibilityElement(false)
	}

	internal required init?(coder: NSCoder) { nil }

	internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

	internal override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		onWindowChanged?()
	}

	internal override func didAddSubview(_ subview: NSView) {
		super.didAddSubview(subview)
		updateOpacity(pageCount: subviews.count)
		updateDragTypes()
	}

	internal override func willRemoveSubview(_ subview: NSView) {
		super.willRemoveSubview(subview)
		updateOpacity(pageCount: subviews.count - 1)
		giveBackDragTypes(subview)
	}

	private func updateOpacity(pageCount: Int) {
		let opacity: CGFloat = isPresented && pageCount > 0 ? 1 : 0
		if alphaValue != opacity { alphaValue = opacity }
	}

	private func updateDragTypes() {
		for page in subviews {
			if isPresented {
				giveBackDragTypes(page)
			} else if takenDragTypes[ObjectIdentifier(page)] == nil, !page.registeredDraggedTypes.isEmpty {
				takenDragTypes[ObjectIdentifier(page)] = page.registeredDraggedTypes
				page.unregisterDraggedTypes()
			}
		}
	}

	private func giveBackDragTypes(_ page: NSView) {
		guard let types = takenDragTypes.removeValue(forKey: ObjectIdentifier(page)) else { return }
		page.registerForDraggedTypes(types)
	}
}

@MainActor
private final class SurfaceHost: NSView {
	fileprivate var onWindowChanged: (() -> Void)?
	fileprivate var onAttachmentChanged: (() -> Void)?

	internal override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		self.onWindowChanged?()
	}

	internal override func didAddSubview(_ subview: NSView) {
		super.didAddSubview(subview)

		// The child acquires its window after this callback unwinds.
		Task { @MainActor [weak self] in self?.onAttachmentChanged?() }
	}

	internal override func willRemoveSubview(_ subview: NSView) {
		super.willRemoveSubview(subview)

		// This hook also runs during deallocation; reuse the existing weak callback.
		let callback = self.onAttachmentChanged
		Task { @MainActor in callback?() }
	}

	internal override func layout() {
		super.layout()
		self.onAttachmentChanged?()
	}

	internal override func viewDidHide() {
		super.viewDidHide()
		self.onAttachmentChanged?()
	}

	internal override func viewDidUnhide() {
		super.viewDidUnhide()
		self.onAttachmentChanged?()
	}
}

extension EnvironmentValues {
	/// Temporarily return a native page to another explicit host without replacing its session.
	@Entry
	public var suppressedBrowserTabs: Set<BrowserCore.Tab.ID> = []

	@Entry
	public var browserSurfaceIsInteractive: Bool = true

	@Entry
	public var browserUnhandledEscape: BrowserUnhandledEscapeHandler? = nil

	@Entry
	public var browserSurfaceVisibilityObserver: BrowserSurfaceVisibilityObserver? = nil
}
