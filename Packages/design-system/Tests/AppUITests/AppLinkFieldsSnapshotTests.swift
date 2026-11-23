import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of an App Links handler's fields (DEV-862), one with an app picked and
/// its example, one empty with its prompts and the plus, and one with a scheme that breaks the
/// rule, and of a Run script route empty, filled, and with a long failure on its own line, in
/// light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct AppLinkFieldsSnapshotTests {
	@Test(arguments: [false, true])
	internal func rows(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = VStack(alignment: .leading, spacing: 20) {
			row(
				name: "Claude",
				scheme: "claude",
				host: "login",
				path: "/callback",
				label: AppLinkAppLabel(name: "Claude", icon: NSImage(named: NSImage.applicationIconName))
			)
			row(name: "", scheme: "", host: "", path: "", label: AppLinkAppLabel(name: nil, icon: nil))
			row(name: "Web", scheme: "https", host: "", path: "", label: AppLinkAppLabel(name: nil, icon: nil))
		}
		.padding(16)
		.frame(width: 620)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize(horizontal: false, vertical: true)

		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "app-link-fields-\(dark ? "dark" : "light").png"))
		window.close()
	}

	@Test(arguments: [false, true])
	internal func scriptRoutes(dark: Bool) throws {
		let view = VStack(alignment: .leading, spacing: 20) {
			script("", error: nil, removable: true)
			script(#"fxclaude open-url work "$1""#, error: nil, removable: false)
			script(
				#"fxclaude open-url personal "$1""#,
				error: "The script exited with 2. error: unexpected argument 'open-url' found. Usage: fxclaude <COMMAND>. For more information, try '--help'.",
				removable: true
			)
		}
		.padding(16)
		.frame(width: 560)
		.background(Color(nsColor: .windowBackgroundColor))
		.fixedSize(horizontal: false, vertical: true)
		try render(view, dark: dark, name: "app-link-script-routes")
	}

	private func script(
		_ text: String,
		error: String?,
		removable: Bool
	) -> some View {
		AppLinkScriptField(
			script: .constant(text),
			example: #"fxclaude open-url work "$1""#,
			error: error,
			isTestDisabled: false,
			onUseExample: {},
			onCommit: {},
			onTest: {},
			onRemove: removable ? {} : nil,
			status: { EmptyView() }
		)
	}

	private func render(
		_ view: some View,
		dark: Bool,
		name: String
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	private func row(
		name: String,
		scheme: String,
		host: String,
		path: String,
		label: AppLinkAppLabel
	) -> some View {
		AppLinkFields(
			name: .constant(name),
			scheme: .constant(scheme),
			host: .constant(host),
			path: .constant(path),
			picker: { label },
			accessory: {
				Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
			}
		)
	}
}
