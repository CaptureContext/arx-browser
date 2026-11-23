import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// The picker at the start of Little Arx's and Page PiP's URL bar, the profile's or the space's,
/// sits as far from the bar's start as from its top and bottom. Measured at 2x on what's drawn:
/// the chip is where the bar with it differs from the bar with it hidden. With
/// `ARX_DESIGN_SNAPSHOTS` set, it also writes the bars with their gaps.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to render")
)
internal struct URLBarPickerInsetTests {
	internal enum Chip: String, CaseIterable, CustomTestStringConvertible, Sendable {
		case profile = "profile picker"
		case profileFace = "profile picker, face only"
		case space = "Page PiP's space picker"

		internal var testDescription: String { rawValue }
	}

	internal struct Gaps: Equatable, CustomStringConvertible {
		internal var top: Int
		internal var bottom: Int
		internal var leading: Int

		internal var description: String { "top \(top) px, bottom \(bottom) px, left \(leading) px" }
	}

	@Test(arguments: Chip.allCases)
	internal func thePickerSitsAsFarFromTheStartAsFromTheTopAndBottom(_ chip: Chip) throws {
		let gaps = try Self.gaps(chip)
		#expect(gaps.top == gaps.bottom, "\(chip.rawValue): \(gaps)")
		#expect(gaps.leading == gaps.top, "\(chip.rawValue): \(gaps)")
	}

	@Test
	internal func snapshot() throws {
		guard let directory = ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] else { return }

		var rows: [AnyView] = []
		for chip in Chip.allCases {
			let gaps = try Self.gaps(chip)
			let isEven = gaps.leading == gaps.top && gaps.top == gaps.bottom
			rows.append(AnyView(
				VStack(alignment: .leading, spacing: 4) {
					Self.bar(chip, showsChip: true)
					Text(verbatim: "\(chip.rawValue): \(gaps.description) at 2x")
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
		let image = try Self.render(view)
		let data = try #require(image.representation(using: .png, properties: [:]))
		try data.write(to: URL(fileURLWithPath: directory).appending(path: "url-bar-picker-insets.png"))
	}

	private static func bar(
		_ chip: Chip,
		showsChip: Bool
	) -> some View {
		URLBar(
			url: URL(string: "https://capturecontext.dev/arx"),
			height: BrowserMetrics.LittleArx.addressHeight,
			centersAddress: true,
			prominentActions: true,
			leading: AnyView(Self.chip(chip).opacity(showsChip ? 1 : 0)),
			onActivate: {},
			onCopy: {}
		)
		.frame(width: chip == .profileFace ? 150 : 340)
		.environment(\.colorScheme, .light)
	}

	@ViewBuilder
	private static func chip(_ chip: Chip) -> some View {
		switch chip {
		case .profile, .profileFace:
			let id = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
			LittleWindowProfilePicker(
				options: [.init(id: id, name: "maximkrouk", isEnabled: true)],
				currentID: id,
				onSelect: { _ in }
			)
		case .space:
			let id = Space.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
			PagePictureInPictureSpacePicker(
				options: [.init(id: id, name: "Work", shortcut: "⌃4")],
				currentID: id,
				onSelect: { _ in }
			)
		}
	}

	private static func gaps(_ chip: Chip) throws -> Gaps {
		let shown = try pixels(of: bar(chip, showsChip: true))
		let hidden = try pixels(of: bar(chip, showsChip: false))
		try #require(shown.width == hidden.width && shown.height == hidden.height)

		var barMinX = Int.max
		var barMinY = Int.max
		var barMaxY = -1
		var chipMinX = Int.max
		var chipMinY = Int.max
		var chipMaxY = -1
		for y in 0..<hidden.height {
			for x in 0..<hidden.width {
				if hidden.alpha(x, y) > 8 {
					barMinX = min(barMinX, x)
					barMinY = min(barMinY, y)
					barMaxY = max(barMaxY, y)
				}
				if shown.differs(from: hidden, x, y) {
					chipMinX = min(chipMinX, x)
					chipMinY = min(chipMinY, y)
					chipMaxY = max(chipMaxY, y)
				}
			}
		}
		try #require(chipMaxY >= 0, "No picker drawn")
		return .init(top: chipMinY - barMinY, bottom: barMaxY - chipMaxY, leading: chipMinX - barMinX)
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

	/// A menu's label is an AppKit view, which `ImageRenderer` doesn't draw, so this hosts the
	/// view in a window off every screen and caches its display at 2x.
	private static func render(_ view: some View) throws -> NSBitmapImageRep {
		let host = NSHostingView(rootView: view.fixedSize())
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = NSAppearance(named: .aqua)
		window.contentView = host
		defer { window.close() }
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(NSBitmapImageRep(
			bitmapDataPlanes: nil,
			pixelsWide: Int(host.bounds.width * 2),
			pixelsHigh: Int(host.bounds.height * 2),
			bitsPerSample: 8,
			samplesPerPixel: 4,
			hasAlpha: true,
			isPlanar: false,
			colorSpaceName: .deviceRGB,
			bytesPerRow: 0,
			bitsPerPixel: 0
		))
		representation.size = host.bounds.size
		host.cacheDisplay(in: host.bounds, to: representation)
		return representation
	}

	private static func pixels(of view: some View) throws -> Pixels {
		let representation = try render(view)
		let image = try #require(representation.cgImage)
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
