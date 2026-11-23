import AppKit
import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
@testable import MainFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// A file dragged from Finder onto the page goes to the page (DEV-1309).
///
/// AppKit gives a drag to the front-most view registered for one of its types whose frame holds
/// the pointer. It skips hidden views but not transparent ones, nor ones whose `hitTest` refuses
/// the point, so a view anywhere over the page that takes file drags swallows the drop. These
/// tests ask AppKit's own lookup, with stand-ins registered as Chromium's page view is.
@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct PageFileDropTests {
	/// The main window as it's built: sidebar, pager, drop zones and page stage around the page.
	@Test
	internal func aFileOverThePageGoesToThePageInTheMainWindow() throws {
		let organization = IntegrationFeatureTests().fixture()
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let active = organization.tabs[0]
		state.viewer.item = .init(tab: active, navigation: .init(url: active.restoration.url), generation: 1)
		let store = Store(initialState: state) { MainFeature() } withDependencies: {
			$0.continuousClock = TestClock()
			$0.browserEngine.command = { _, _ in }
		}
		let page = PageStandIn()
		let surface = BrowserSurfaceClient(
			attach: { _, host in page.mount(in: host) },
			detach: { _ in }
		)
		let window = Self.host(MainView(store: store, surface: surface))
		defer { Self.close(window) }

		let frame = page.convert(page.bounds, to: nil)
		try #require(frame.width > 100 && frame.height > 100, "the page is laid out: \(frame)")
		for x in stride(from: frame.minX + 4, to: frame.maxX, by: frame.width / 8) {
			for y in stride(from: frame.minY + 4, to: frame.maxY, by: frame.height / 6) {
				let found = try Self.fileDestination(in: window, at: .init(x: x, y: y))
				#expect(found === page, "(\(Int(x)), \(Int(y))): \(Self.describe(found))")
			}
		}
	}

	/// A page staged out of sight over the page card, as a press on a sidebar row or a space swipe
	/// leaves one, doesn't take the drop; shown, it does, and once it leaves the stage it takes
	/// drags again. On `main` the staged page took every file dropped on the card.
	@Test
	internal func aPageStagedOutOfSightTakesNoFileDrop() throws {
		let shownID = BrowserCore.Tab.ID(rawValue: UUID(10))
		let stagedID = BrowserCore.Tab.ID(rawValue: UUID(11))
		let shown = PageStandIn()
		let staged = PageStandIn()
		let client = BrowserSurfaceClient(
			attach: { _, host in shown.mount(in: host) },
			detach: { _ in },
			stage: { id, stage in
				if id == stagedID {
					staged.mount(in: stage)
				} else {
					staged.removeFromSuperview()
				}
			}
		)
		let controller = BrowserSurfaceStageController(client: client)
		let window = Self.host(
			ZStack {
				BrowserSurface(tabID: shownID, client: client, isFocused: false)
				BrowserSurfaceStage(controller: controller)
			}
		)
		defer { Self.close(window) }
		let center = shown.convert(NSPoint(x: shown.bounds.midX, y: shown.bounds.midY), to: nil)
		#expect(try Self.fileDestination(in: window, at: center) === shown)

		controller.stage(stagedID, isPresented: false)
		Self.settle()
		try #require(staged.window === window, "the staged page is in the window")
		let hidden = try Self.fileDestination(in: window, at: center)
		#expect(hidden === shown, "out of sight: \(Self.describe(hidden))")

		controller.stage(stagedID, isPresented: true)
		Self.settle()
		let presented = try Self.fileDestination(in: window, at: center)
		#expect(presented === staged, "shown: \(Self.describe(presented))")

		controller.stage(stagedID, isPresented: false)
		controller.stage(nil, isPresented: false)
		Self.settle()
		#expect(staged.superview == nil)
		#expect(Set(staged.registeredDraggedTypes) == Set(PageStandIn.dragTypes), "its drag types are back")
	}

	// MARK: - Hosting

	/// The view AppKit gives a file drag at a window point, by AppKit's own lookup.
	private static func fileDestination(
		in window: NSWindow,
		at location: NSPoint
	) throws -> NSView? {
		let root = try #require(window.contentView?.superview)
		let selector = NSSelectorFromString("_hitTest:dragTypes:")
		try #require(root.responds(to: selector), "AppKit's drag destination lookup")
		typealias Lookup = @convention(c) (NSView, Selector, UnsafePointer<NSPoint>, NSSet) -> NSView?
		let lookup = unsafeBitCast(root.method(for: selector), to: Lookup.self)
		var point = root.superview?.convert(location, from: nil) ?? location

		// What Finder puts on the pasteboard for a file.
		let types: NSSet = [NSPasteboard.PasteboardType.fileURL.rawValue, "NSFilenamesPboardType"]
		return withUnsafePointer(to: &point) { lookup(root, selector, $0, types) }
	}

	private static func describe(_ view: NSView?) -> String {
		guard let view else { return "nothing" }
		return sequence(first: view, next: \.superview).map { "\(type(of: $0))" }.joined(separator: " < ")
	}

	/// The view in a window kept off every screen and never made key.
	private static func host(_ view: some View) -> NSWindow {
		let size: CGSize = .init(width: 1000, height: 640)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
		host.frame = .init(origin: .zero, size: size)
		window.contentView = host
		host.layoutSubtreeIfNeeded()
		settle()
		return window
	}

	private static func close(_ window: NSWindow) {
		window.contentView = nil
		window.close()
	}

	private static func settle() {
		for _ in 0..<8 {
			RunLoop.main.run(until: .now.addingTimeInterval(0.025))
		}
	}
}

/// Registers for drags as Chromium's page view, `WebContentsViewCocoa`, does.
private final class PageStandIn: NSView {
	static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL, .html, .rtf, .string, .URL]

	override init(frame: NSRect) {
		super.init(frame: frame)
		registerForDraggedTypes(Self.dragTypes)
	}

	required init?(coder: NSCoder) { nil }

	func mount(in host: NSView) {
		guard superview !== host else { return }
		frame = host.bounds
		autoresizingMask = [.width, .height]
		host.addSubview(self)
	}
}
