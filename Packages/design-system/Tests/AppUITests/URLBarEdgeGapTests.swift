import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// The URL bar's last button, pressed, sits as far from the bar's end as from its top and bottom
/// (DEV-1252): in the sidebar and Little Arx, whichever button is last, with and without the
/// reading mode button. Measured at 2x on what's drawn: the pressed fill against the bar's
/// surface. With `ARX_DESIGN_SNAPSHOTS` set, it also writes the bars with their gaps.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to render")
)
internal struct URLBarEdgeGapTests {
	internal struct Case: CustomTestStringConvertible, Sendable {
		internal let name: String
		internal let height: CGFloat
		internal let prominentActions: Bool
		internal let readingMode: Bool

		internal var testDescription: String { name }

		internal static let all: [Case] = [
			.init(name: "sidebar", height: BrowserMetrics.URLBar.height, prominentActions: false, readingMode: false),
			.init(name: "sidebar with reading mode", height: BrowserMetrics.URLBar.height, prominentActions: false, readingMode: true),
			.init(name: "Little Arx", height: BrowserMetrics.LittleArx.addressHeight, prominentActions: true, readingMode: false),
			.init(name: "Little Arx with reading mode", height: BrowserMetrics.LittleArx.addressHeight, prominentActions: true, readingMode: true),
		]
	}

	internal struct Gaps: Equatable, CustomStringConvertible {
		internal var top: Int
		internal var bottom: Int
		internal var trailing: Int

		internal var description: String { "top \(top) px, bottom \(bottom) px, right \(trailing) px" }
	}

	@Test(arguments: Case.all)
	internal func theLastButtonSitsAsFarFromTheEndAsFromTheTopAndBottom(_ testCase: Case) throws {
		let gaps = try Self.gaps(testCase)
		#expect(gaps.top == gaps.bottom, "\(testCase.name): \(gaps)")
		#expect(gaps.trailing == gaps.top, "\(testCase.name): \(gaps)")
	}

	@Test
	internal func snapshot() throws {
		guard let directory = ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] else { return }
		let wasEnabled = ChromeInlineButtons.isEnabled
		defer { ChromeInlineButtons.isEnabled = wasEnabled }
		ChromeInlineButtons.isEnabled = true

		var rows: [AnyView] = []
		for testCase in Case.all {
			let gaps = try Self.gaps(testCase)
			let isEven = gaps.trailing == gaps.top && gaps.top == gaps.bottom
			rows.append(AnyView(
				VStack(alignment: .leading, spacing: 4) {
					Self.bar(testCase, pressed: true)
					Text(verbatim: "\(testCase.name): \(gaps.description) at 2x")
						.font(.system(size: 11, design: .monospaced))
						.foregroundStyle(isEven ? Color.green : Color.red)
				}
			))
		}
		let view = VStack(alignment: .leading, spacing: 14) {
			ForEach(rows.indices, id: \.self) { rows[$0] }
		}
		.padding(16)
		.background(Color(white: 0.93))
		.environment(\.colorScheme, .light)
		let renderer = ImageRenderer(content: view)
		renderer.scale = 2
		let image = try #require(renderer.cgImage)
		let representation = NSBitmapImageRep(cgImage: image)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: URL(fileURLWithPath: directory).appending(path: "url-bar-edge-gaps.png"))
	}

	private static func bar(
		_ testCase: Case,
		pressed: Bool
	) -> some View {
		URLBar(
			url: URL(string: "https://capturecontext.dev/arx"),
			height: testCase.height,
			prominentActions: testCase.prominentActions,
			onActivate: {},
			onCopy: {}
		)
		.environment(\.readingModeIndicator, testCase.readingMode ? .init(isReading: false, toggle: {}) : nil)
		.environment(\.arxControlStateOverride, pressed ? .init(isPressed: true) : .init())
		.frame(width: 300)
		.environment(\.colorScheme, .light)
	}

	/// The pressed fill is where the pressed render differs from the one at rest; the bar is
	/// what's drawn at all.
	private static func gaps(_ testCase: Case) throws -> Gaps {
		// The inline buttons, whatever the run's `ARX_INLINE_BUTTONS` says.
		let wasEnabled = ChromeInlineButtons.isEnabled
		defer { ChromeInlineButtons.isEnabled = wasEnabled }
		ChromeInlineButtons.isEnabled = true

		let rest = try pixels(of: bar(testCase, pressed: false))
		let pressed = try pixels(of: bar(testCase, pressed: true))
		#expect(rest.width == pressed.width && rest.height == pressed.height)

		var barMinY = Int.max
		var barMaxY = -1
		var barMaxX = -1
		var fillMaxX = -1
		for y in 0..<rest.height {
			for x in 0..<rest.width {
				if rest.alpha(x, y) > 8 {
					barMinY = min(barMinY, y)
					barMaxY = max(barMaxY, y)
					barMaxX = max(barMaxX, x)
				}
				if rest.differs(from: pressed, x, y) { fillMaxX = max(fillMaxX, x) }
			}
		}
		try #require(fillMaxX >= 0, "No pressed fill drawn")

		// The last button's fill: the run of columns with pressed pixels that ends at its end,
		// whole, so its rounded corners don't shorten it.
		let columnHasFill = { (x: Int) in (0..<rest.height).contains { rest.differs(from: pressed, x, $0) } }
		var fillMinX = fillMaxX
		while fillMinX > 0, columnHasFill(fillMinX - 1) { fillMinX -= 1 }
		var fillMinY = Int.max
		var fillMaxY = -1
		for y in 0..<rest.height {
			for x in fillMinX...fillMaxX where rest.differs(from: pressed, x, y) {
				fillMinY = min(fillMinY, y)
				fillMaxY = max(fillMaxY, y)
			}
		}
		return .init(top: fillMinY - barMinY, bottom: barMaxY - fillMaxY, trailing: barMaxX - fillMaxX)
	}

	private struct Pixels {
		internal let width: Int
		internal let height: Int
		internal let bytes: [UInt8]

		internal func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

		internal func differs(from other: Pixels, _ x: Int, _ y: Int) -> Bool {
			let index = (y * width + x) * 4
			return (0..<4).contains { abs(Int(bytes[index + $0]) - Int(other.bytes[index + $0])) > 2 }
		}
	}

	private static func pixels(of view: some View) throws -> Pixels {
		let renderer = ImageRenderer(content: view)
		renderer.scale = 2
		let image = try #require(renderer.cgImage)
		var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
		let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
			guard let context = CGContext(
				data: buffer.baseAddress,
				width: image.width,
				height: image.height,
				bitsPerComponent: 8,
				bytesPerRow: image.width * 4,
				space: CGColorSpaceCreateDeviceRGB(),
				bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
			) else { return false }
			context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
			return true
		}
		try #require(drawn)
		return .init(width: image.width, height: image.height, bytes: bytes)
	}
}
