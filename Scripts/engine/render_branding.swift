// DEV-1100. Renders Arx's engine branding into Packages/engine/Branding, which the engine
// overlay puts in place of Helium's (Scripts/engine/branding_overlay.py). Run it again only
// when Arx's icon or mark changes:
//
//   swift Scripts/engine/render_branding.swift
//
// The product logo in color is Arx's app icon (AppUI's appIcon.dark, 1024 px: a white mark on a black tile). The white and
// mono logos, the SVG and Chromium's vector icon are the Arx mark (AppUI's ArxLogo), from the
// same path.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let output = root.appending(path: "Packages/engine/Branding")
let icon = root.appending(
	path: "Packages/design-system/Sources/AppUI/Resources/Images.xcassets/appIcon.dark.imageset/appIcon-dark@2x.png"
)

// ArxLogo's path in its 700 × 674 design space (the vector of the Figma AppIcon page, the same
// as the app icon's 02-Vector.svg): three blades, each a move, then cubic curves (control 1,
// control 2, end), closed.
let designSize = CGSize(width: 700, height: 674)
typealias Point = (Double, Double)
let subpaths: [(Point, [(Point, Point, Point)])] = [
	((2.14561, 457.026), [
		((14.8507, 424.478), (44.9696, 515.158), (215.188, 526.049)),
		((385.406, 536.94), (489.548, 448.56), (531.94, 528.968)),
		((561.466, 584.972), (529.836, 621.231), (484.128, 642.715)),
		((418.169, 673.717), (326.878, 687.28), (204.017, 659.201)),
		((81.1555, 631.122), (-13.2362, 496.475), (2.14561, 457.026)),
	]),
	((615.727, 638.6), [
		((581.177, 643.875), (644.68, 572.462), (569.006, 419.663)),
		((493.333, 266.864), (364.692, 220.901), (413.159, 144)),
		((446.917, 90.438), (494.147, 99.6899), (535.614, 128.516)),
		((595.452, 170.114), (652.849, 242.36), (689.952, 362.758)),
		((727.055, 483.155), (657.596, 632.191), (615.727, 638.6)),
	]),
	((466.248, 16.6514), [
		((488.094, 43.9236), (394.472, 24.657), (299.927, 166.565)),
		((205.382, 308.473), (229.881, 442.816), (139.022, 439.309)),
		((75.7384, 436.867), (60.1391, 391.356), (64.3802, 341.046)),
		((70.5002, 268.447), (104.394, 182.636), (190.152, 90.3182)),
		((275.91, -1.9998), (439.761, -16.3887), (466.248, 16.6514)),
	]),
]

/// The mark fitted in a square canvas of `side`, centered, with `inset` on each side.
func fitted(_ side: Double, inset: Double) -> (Point) -> Point {
	let scale = (side - 2 * inset) / max(designSize.width, designSize.height)
	let dx = (side - designSize.width * scale) / 2
	let dy = (side - designSize.height * scale) / 2
	return { point in (point.0 * scale + dx, point.1 * scale + dy) }
}

func png(_ side: Int, draw: (CGContext) -> Void) -> Data {
	let rep = NSBitmapImageRep(
		bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
		hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
	)!
	rep.size = NSSize(width: side, height: side)
	let context = NSGraphicsContext(bitmapImageRep: rep)!
	NSGraphicsContext.saveGraphicsState()
	NSGraphicsContext.current = context
	context.imageInterpolation = .high
	draw(context.cgContext)
	NSGraphicsContext.restoreGraphicsState()
	return rep.representation(using: .png, properties: [:])!
}

func mark(_ side: Int, color: NSColor) -> Data {
	png(side) { context in
		let place = fitted(Double(side), inset: Double(side) * 0.06)
		let path = CGMutablePath()
		for (start, curves) in subpaths {
			// Core Graphics' y grows upward; the design's grows downward.
			func flip(_ p: Point) -> CGPoint { let q = place(p); return CGPoint(x: q.0, y: Double(side) - q.1) }
			path.move(to: flip(start))
			for (c1, c2, end) in curves { path.addCurve(to: flip(end), control1: flip(c1), control2: flip(c2)) }
			path.closeSubpath()
		}
		context.addPath(path)
		context.setFillColor(color.cgColor)
		context.fillPath()
	}
}

guard let appIcon = NSImage(contentsOf: icon) else { fatalError("No app icon at \(icon.path)") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for side in [16, 24, 32, 48, 64, 128, 140, 256, 280] {
	let data = png(side) { _ in
		appIcon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
	}
	try data.write(to: output.appending(path: "product_logo_\(side).png"))
}
for side in [140, 280] {
	try mark(side, color: .white).write(to: output.appending(path: "product_logo_white_\(side).png"))
}
try mark(22, color: .black).write(to: output.appending(path: "product_logo_22_mono.png"))

// The mark as SVG, in its design space.
func number(_ value: Double) -> String { String(format: "%.6g", value) }
var svgPath = ""
for (start, curves) in subpaths {
	svgPath += "M\(number(start.0)) \(number(start.1))"
	for (c1, c2, end) in curves {
		svgPath += "C\(number(c1.0)) \(number(c1.1)) \(number(c2.0)) \(number(c2.1)) \(number(end.0)) \(number(end.1))"
	}
	svgPath += "Z"
}
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(number(designSize.width)) \(number(designSize.height))">\
<path fill="#1C1C1E" d="\(svgPath)"/></svg>

"""
try svg.write(to: output.appending(path: "product_logo.svg"), atomically: true, encoding: .utf8)

// Chromium's vector icon format, on a 56-point canvas like the icons it replaces.
let canvas = 56.0
let placeIcon = fitted(canvas, inset: 2)
func iconNumber(_ value: Double) -> String {
	let rounded = (value * 100).rounded() / 100
	return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.2ff", rounded)
		.replacingOccurrences(of: "0f", with: "f")
}
var lines = ["// Arx's mark (DEV-1100), from Scripts/engine/render_branding.swift.", "", "CANVAS_DIMENSIONS, 56,"]
for (start, curves) in subpaths {
	let s = placeIcon(start)
	lines.append("MOVE_TO, \(iconNumber(s.0)), \(iconNumber(s.1)),")
	for (c1, c2, end) in curves {
		let a = placeIcon(c1), b = placeIcon(c2), e = placeIcon(end)
		lines.append("CUBIC_TO, \(iconNumber(a.0)), \(iconNumber(a.1)), \(iconNumber(b.0)), \(iconNumber(b.1)), \(iconNumber(e.0)), \(iconNumber(e.1)),")
	}
	lines.append("CLOSE,")
}
try (lines.joined(separator: "\n") + "\n").write(to: output.appending(path: "arx_mark.icon"), atomically: true, encoding: .utf8)

// The helpers' icon (the Alerts helpers show it), compiled from Arx's Icon Composer icon for
// Chromium's deployment target, as Helium's assets/app.icns and Assets.car were.
let compiled = FileManager.default.temporaryDirectory.appending(path: "arx-engine-branding-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
let actool = Process()
actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
actool.arguments = [
	"actool", root.appending(path: "Containers/macOS/AppIcon.icon").path, "--compile", compiled.path,
	"--platform", "macosx", "--minimum-deployment-target", "13.0", "--app-icon", "AppIcon",
	"--output-partial-info-plist", compiled.appending(path: "partial.plist").path,
]
actool.standardOutput = FileHandle.nullDevice
try actool.run()
actool.waitUntilExit()
guard actool.terminationStatus == 0 else { fatalError("actool failed") }
for (name, destination) in [("AppIcon.icns", "app.icns"), ("Assets.car", "Assets.car")] {
	let target = output.appending(path: destination)
	try? FileManager.default.removeItem(at: target)
	try FileManager.default.copyItem(at: compiled.appending(path: name), to: target)
}
try? FileManager.default.removeItem(at: compiled)
print("Rendered Arx's engine branding into \(output.path)")
