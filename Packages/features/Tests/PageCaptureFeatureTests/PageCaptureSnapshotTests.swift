import AppKit
import BrowserCore
import Foundation
import PageCaptureFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// Renders the capture overlay offscreen in light and dark over a stand-in page.
/// Writes the PNGs for visual review when `ARX_DESIGN_SNAPSHOTS` names a directory.
@Suite(.dependencies)
@MainActor
internal struct PageCaptureSnapshotTests {
	internal enum Scene: String, CaseIterable, Sendable {
		case idle
		case hover
		case drag
		case menu
		case protectedMedia

		/// DEV-1208: Capture Page's frame holds the whole 2400-point page, scaled to fit.
		case wholePage

		/// DEV-1208: an area drawn while the page scrolled 600 points; the cut-out shows its
		/// visible part, up to the viewport's top.
		case drawingBeyond
	}

	private static let size = CGSize(width: 720, height: 460)
	private static let heading = PageCaptureRegion(x: 48, y: 40, width: 420, height: 44)
	private static let paragraph = PageCaptureRegion(x: 48, y: 104, width: 520, height: 96)
	private static let video = PageCaptureRegion(x: 48, y: 224, width: 320, height: 180)

	@Test(arguments: Scene.allCases)
	internal func overlay(_ scene: Scene) throws {
		let light = try render(scene, dark: false)
		let dark = try render(scene, dark: true)

		#expect(light.pixelsWide >= Int(Self.size.width) && light.pixelsHigh >= Int(Self.size.height))
		// The page dims more in dark mode, so the two never match.
		#expect(light.colorAt(x: 4, y: 4) != dark.colorAt(x: 4, y: 4))
	}

	/// Before anything is picked the whole page is dimmed; a selection is left clear.
	@Test
	internal func dimmingLeavesOnlyTheSelectionClear() throws {
		let idle = try render(.idle, dark: false)
		let hover = try render(.hover, dark: false)

		// A blank spot inside the paragraph, and one on the page away from every block.
		let inside = CGPoint(x: Self.paragraph.x + 260, y: Self.paragraph.y + 48)
		let outside = CGPoint(x: 640, y: 40)

		#expect(brightness(idle, at: outside) < 0.9)
		#expect(brightness(idle, at: inside) < 0.8)
		#expect(abs(brightness(hover, at: outside) - brightness(idle, at: outside)) < 0.02)
		#expect(brightness(hover, at: inside) > brightness(idle, at: inside) + 0.1)
	}

	/// DEV-1208: the whole page shows scaled in its frame, and the page around it is dimmed.
	@Test
	internal func theWholePageShowsScaledInItsFrame() throws {
		let whole = try render(.wholePage, dark: false)
		let frame = PageCaptureGeometry.capturedFrame(for: Self.page, viewport: Self.viewport)
		let top = color(whole, at: .init(x: frame.x + frame.width / 2, y: frame.y + 20))
		let bottom = color(whole, at: .init(x: frame.x + frame.width / 2, y: frame.y + frame.height - 20))

		#expect(frame.height < Self.size.height && frame.width < 200)
		// The page's red top and blue bottom are both in the frame.
		#expect(top.redComponent > top.blueComponent + 0.3)
		#expect(bottom.blueComponent > bottom.redComponent + 0.3)
		#expect(brightness(whole, at: .init(x: 640, y: 40)) < 0.9)
	}

	private func color(
		_ representation: NSBitmapImageRep,
		at point: CGPoint
	) -> NSColor {
		let scale = CGFloat(representation.pixelsWide) / Self.size.width
		return representation.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
			.usingColorSpace(.deviceRGB) ?? .clear
	}

	private func brightness(
		_ representation: NSBitmapImageRep,
		at point: CGPoint
	) -> CGFloat {
		let scale = CGFloat(representation.pixelsWide) / Self.size.width
		let color = representation.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?
			.usingColorSpace(.deviceRGB)
		return color?.brightnessComponent ?? 0
	}

	private func render(
		_ scene: Scene,
		dark: Bool
	) throws -> NSBitmapImageRep {
		let initialState = try state(scene)
		let store = Store(initialState: initialState) { EmptyReducer<PageCaptureFeature.State, PageCaptureFeature.Action>() }
		let host = NSHostingView(
			rootView: ZStack {
				StandInPage(heading: Self.heading, paragraph: Self.paragraph, video: Self.video)
				PageCaptureOverlay(store: store)
			}
			.frame(width: Self.size.width, height: Self.size.height)
		)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: Self.size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		defer { window.close() }
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}

		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		if let directory = ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] {
			let data = try #require(representation.representation(using: .png, properties: [:]))
			let name = "capture-\(scene.rawValue)-\(dark ? "dark" : "light").png"
			try data.write(to: URL(fileURLWithPath: directory).appending(path: name))
		}
		return representation
	}

	private static let viewport = PageCaptureRegion(x: 0, y: 0, width: size.width, height: size.height)
	private static let page = PageCaptureRegion(x: 0, y: 0, width: size.width, height: 2_400)

	private func state(_ scene: Scene) throws -> PageCaptureFeature.State {
		var state = PageCaptureFixtures.state(phase: .selecting)
		state.viewport = Self.viewport
		switch scene {
		case .idle:
			break

		case .hover:
			state.highlighted = .init(index: 2, role: "paragraph", bounds: Self.paragraph)

		case .drag:
			state.drag = .init(x: 380, y: 150, width: 260, height: 200)

		case .menu:
			state.phase = .captured
			state.selection = Self.paragraph
			state.image = .init(png: Data([1]), width: 1, height: 1)

		case .protectedMedia:
			state.phase = .captured
			state.selection = Self.video
			state.image = .init(png: Data([1]), width: 1, height: 1)
			state.showsProtectedMediaNote = true

		case .wholePage:
			state.mode = .page
			state.phase = .captured
			state.isFullPage = true
			state.capturesBeyondViewport = true
			state.selection = PageCaptureGeometry.capturedFrame(for: Self.page, viewport: Self.viewport)
			state.image = try PageCaptureFixtures.png(width: 72, height: 240) { _, y in
				y < 120 ? [220, 40, 40] : [40, 40, 220]
			}

		case .drawingBeyond:
			state.capturesBeyondViewport = true
			state.autoscrollAvailable = true
			let drawing = PageCaptureDrawing(
				start: .init(x: 120, y: 300),
				pointer: .init(x: 420, y: 455),
				scrolled: .init(x: 0, y: 600)
			)
			state.drawing = drawing
			state.drag = PageCaptureGeometry.region(
				from: drawing.start,
				to: drawing.pointer,
				scrolled: drawing.scrolled,
				viewport: Self.viewport
			)
			.flatMap { PageCaptureGeometry.intersection($0, Self.viewport) }
		}
		return state
	}
}

/// A plain page behind the overlay, in the page's own light colors, as most sites are.
private struct StandInPage: View {
	internal let heading: PageCaptureRegion
	internal let paragraph: PageCaptureRegion
	internal let video: PageCaptureRegion

	internal var body: some View {
		ZStack(alignment: .topLeading) {
			Color.white
			block(heading, color: .gray.opacity(0.55))
			block(paragraph, color: .gray.opacity(0.25))
			block(video, color: .black)
		}
	}

	private func block(
		_ region: PageCaptureRegion,
		color: Color
	) -> some View {
		RoundedRectangle(cornerRadius: 4)
			.fill(color)
			.frame(width: region.width, height: region.height)
			.offset(x: region.x, y: region.y)
	}
}
