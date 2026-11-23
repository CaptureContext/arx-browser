import AppKit
import AppUI
import BrowserCore
import Foundation
import MigrationAssistantFeature
import SwiftUI
import Testing

/// Writes offscreen PNGs of the import's extension review (DEV-1300) over a dimmed onboarding
/// window, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory: the second of three
/// extensions, with Install All offered, to compare with the Figma frame "extension review
/// sheet, proposed".
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ExtensionImportReviewSnapshotTests {
	private static let size: CGSize = .init(width: 760, height: 540)

	private var prompt: BrowserExtensionInstallPrompt {
		.init(
			id: UUID(),
			profileID: .init(rawValue: UUID()),
			inventoryID: UUID(),
			revision: 1,
			candidate: .init(
				extensionID: "ddkjiahejlhfcafbddmgiahcphecmpfh",
				name: "uBlock Origin Lite",
				version: "2025.1116.1",
				packageSHA256: "9f2c1e…",
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(),
				optionalPermissions: .init(),
				warnings: [
					.init(message: "Read and change your data on all websites", details: []),
					.init(message: "Block content on any page", details: []),
				],
				publisher: "Raymond Hill"
			)
		)
	}

	@Test(arguments: [false, true])
	internal func secondOfThree(dark: Bool) throws {
		let review = ExtensionImportReview(
			prompt: prompt,
			detail: ExtensionImportReview.detail(
				publisher: "Raymond Hill",
				position: (2, 3),
				sourceName: "Chrome",
				profileName: "Personal"
			),
			acceptAllCount: 2,
			skipAll: {},
			acceptAll: {},
			respond: { _ in }
		)
		try write(review, name: "extension-import-review", dark: dark)
	}

	/// An extension asking for a dozen permissions: what it can do scrolls, and the buttons
	/// stay in the sheet.
	@Test(arguments: [false, true])
	internal func manyPermissions(dark: Bool) throws {
		let base = prompt
		let many: BrowserExtensionInstallPrompt = .init(
			id: base.id,
			profileID: base.profileID,
			inventoryID: base.inventoryID,
			revision: base.revision,
			candidate: .init(
				extensionID: base.candidate.extensionID,
				name: "Everything Helper",
				version: "1.0",
				packageSHA256: "hash",
				sourceBasename: "Chrome Web Store",
				isUpdate: false,
				requiredPermissions: .init(),
				optionalPermissions: .init(),
				warnings: (1...12).map { index in
					.init(message: "Permission number \(index), with a line long enough to wrap in the sheet", details: [])
				}
			)
		)
		let review = ExtensionImportReview(
			prompt: many,
			detail: ExtensionImportReview.detail(publisher: nil, position: (1, 3), sourceName: "Arc", profileName: "Work"),
			acceptAllCount: 3,
			skipAll: {},
			acceptAll: {},
			respond: { _ in }
		)
		try write(review, name: "extension-import-review-many", dark: dark)
	}

	/// The review as a sheet over the window: dimmed behind, the sheet at the top.
	private func write(
		_ review: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = ZStack(alignment: .top) {
			Color(nsColor: .windowBackgroundColor)
			Color.black.opacity(dark ? 0.35 : 0.15)
			review
				.fixedSize()
				.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 16))
				.shadow(color: .black.opacity(0.25), radius: 20, y: 8)
				.padding(.top, 28)
		}
		.frame(width: Self.size.width, height: Self.size.height)
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: Self.size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
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
}
