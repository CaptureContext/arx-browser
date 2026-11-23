import AppKit
import ChromiumBridge
import Foundation

/// ABI19 inspector presentation. Chromium DevTools is bound to its exact page and
/// browsing context. Since ABI42 it docks in the page's area (DEV-733); DevTools'
/// own Dock side menu moves it to a side or into its own window.
public enum ChromiumDeveloperToolsResult: Equatable, Sendable {
	case opened
	case unavailable
	case invalid

	internal init(_ status: ArxDevToolsStatus) {
		switch status {
		case ARX_DEVTOOLS_OPENED: self = .opened
		case ARX_DEVTOOLS_INVALID: self = .invalid
		default: self = .unavailable
		}
	}
}

/// ABI42: where a page's open DevTools is, and the page's place beside it.
public struct ChromiumDeveloperToolsLayout: Equatable {
	public enum Dock: Equatable, Sendable {
		/// Open, and the frontend hasn't said where yet: placed docked meanwhile.
		case pending
		case right
		case left
		case bottom
		case undocked
	}

	public var dock: Dock

	/// The docked frontend's view, which fills the page's area; nil when undocked.
	public var view: NSView?

	/// The page's bounds inside `view`, origin top-left. Empty: the page fills it.
	public var pageBounds: CGRect

	public init(
		dock: Dock,
		view: NSView?,
		pageBounds: CGRect
	) {
		self.dock = dock
		self.view = view
		self.pageBounds = pageBounds
	}

	internal init(_ native: ArxDevToolsLayout) {
		switch native.dock {
		case ARX_DEVTOOLS_DOCK_RIGHT: dock = .right
		case ARX_DEVTOOLS_DOCK_LEFT: dock = .left
		case ARX_DEVTOOLS_DOCK_BOTTOM: dock = .bottom
		case ARX_DEVTOOLS_UNDOCKED: dock = .undocked
		default: dock = .pending
		}
		view = native.view.map { Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue() }
		pageBounds = .init(x: native.x, y: native.y, width: native.width, height: native.height)
	}

	/// The page's frame in a container the size of `bounds`, as Chrome places a page
	/// beside docked DevTools: at the frontend's bounds, clamped to the container.
	public func pageFrame(
		in bounds: CGRect,
		isFlipped: Bool
	) -> CGRect {
		guard view != nil, pageBounds.width > 0, pageBounds.height > 0 else { return bounds }
		let width = min(pageBounds.width, bounds.width)
		let height = min(pageBounds.height, bounds.height)
		let x = min(max(0, pageBounds.minX), bounds.width - width)
		let top = min(max(0, pageBounds.minY), bounds.height - height)
		let y = isFlipped ? top : bounds.height - top - height
		return .init(x: bounds.minX + x, y: bounds.minY + y, width: width, height: height)
	}
}

extension ChromiumRuntime {
	public var supportsDeveloperTools: Bool {
		state == .running && api.devtools_available?() == true && api.open_devtools != nil
	}

	/// Titles are localized by the host. Inspect context adds Inspect Element to
	/// non-link page menus and is the developer-mode switch for the native side.
	public func configureDeveloperTools(
		windowTitle: String,
		inspectTitle: String,
		inspectsContext: Bool
	) {
		guard state == .running, let configure = api.configure_devtools else { return }
		configure(windowTitle, inspectTitle, inspectsContext)
	}

	public func openDeveloperTools(for page: ChromiumPage) -> ChromiumDeveloperToolsResult {
		guard supportsDeveloperTools else { return .unavailable }

		let result = performIfOpen(on: page) { api, id in
			ChromiumDeveloperToolsResult(api.open_devtools(id))
		}
		return result ?? .invalid
	}

	/// Valid only while the exact link menu token is current.
	public func inspectLinkContext(
		_ context: ChromiumLinkContext,
		on page: ChromiumPage
	) -> ChromiumDeveloperToolsResult {
		guard supportsDeveloperTools, let inspect = api.inspect_link_context
		else { return .unavailable }
		guard linkContextIsCurrent(context, on: page) else { return .invalid }

		let result = performIfOpen(on: page) { _, id in
			ChromiumDeveloperToolsResult(inspect(id, context.token))
		}
		return result ?? .invalid
	}

	@discardableResult
	public func closeDeveloperTools(for page: ChromiumPage) -> Bool {
		guard state == .running, let close = api.close_devtools else { return false }
		return performIfOpen(on: page) { _, id in close(id) } ?? false
	}

	public func developerToolsFrontendLoaded(for page: ChromiumPage) -> Bool {
		guard state == .running, let loaded = api.devtools_frontend_loaded else { return false }
		return performIfOpen(on: page) { _, id in loaded(id) } ?? false
	}

	public func developerToolsAreOpen(for page: ChromiumPage) -> Bool {
		guard state == .running, let isOpen = api.devtools_is_open else { return false }
		return performIfOpen(on: page) { _, id in isOpen(id) } ?? false
	}

	/// ABI42: the page's open DevTools and where it is, or nil when it's closed.
	/// Reading it again after placing the docked view lets a pending activation
	/// focus DevTools.
	public func developerToolsLayout(for page: ChromiumPage) -> ChromiumDeveloperToolsLayout? {
		guard state == .running, let read = api.devtools_layout else { return nil }
		let layout = performIfOpen(on: page) { _, id -> ChromiumDeveloperToolsLayout? in
			var native = ArxDevToolsLayout()
			return read(id, &native) ? ChromiumDeveloperToolsLayout(native) : nil
		}
		return layout ?? nil
	}

	/// ABI42: opens DevTools if needed at a panel such as `console` or `network`.
	public func showDeveloperToolsPanel(
		_ panel: String,
		for page: ChromiumPage
	) -> ChromiumDeveloperToolsResult {
		guard supportsDeveloperTools, let show = api.show_devtools_panel else { return .unavailable }
		return performIfOpen(on: page) { _, id in ChromiumDeveloperToolsResult(show(id, panel)) } ?? .invalid
	}

	/// ABI42: opens DevTools if needed and starts Inspect Element's picker in the page.
	public func startDeveloperToolsInspection(for page: ChromiumPage) -> ChromiumDeveloperToolsResult {
		guard supportsDeveloperTools, let start = api.start_devtools_inspect
		else { return .unavailable }
		return performIfOpen(on: page) { _, id in ChromiumDeveloperToolsResult(start(id)) } ?? .invalid
	}
}
