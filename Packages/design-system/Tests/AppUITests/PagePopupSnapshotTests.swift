import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of the window's bottom pop-ups (DEV-1260, DEV-1233) in a window drawn
/// as the browser lays it out, with the sidebar on the left, on the right and hidden, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory. `before` is the old layout, against the whole window
/// with the old cards; `after` is ``SwiftUI/View/pagePopups(_:)`` with ``PagePopupCard``.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct PagePopupSnapshotTests {
	internal enum Sidebar: String, CaseIterable, Sendable {
		case left
		case right
		case hidden
	}

	private static let size: CGSize = .init(width: 1_100, height: 760)
	private static let sidebarWidth: CGFloat = 260
	private static let inset: CGFloat = BrowserMetrics.PageCard.inset

	@Test(arguments: Sidebar.allCases, [false, true])
	internal func popups(sidebar: Sidebar, fixed: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = Group {
			if fixed {
				window(sidebar: sidebar)
					.pagePopups {
						Self.saveError
						Self.passwordCard(isUpdate: false)
					}
			} else {
				window(sidebar: sidebar)
					.overlay(alignment: .bottom) {
						VStack {
							Self.oldSaveError
							Self.oldPasswordCard
						}
					}
			}
		}
		try Self.write(view, to: directory.appending(path: "page-popups-\(fixed ? "after" : "before")-sidebar-\(sidebar.rawValue).png"))
	}

	@Test(arguments: [false, true])
	internal func passwordCards(dark: Bool) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = HStack(alignment: .bottom, spacing: 24) {
			Self.oldPasswordCard
			Self.passwordCard(isUpdate: false)
			Self.passwordCard(isUpdate: true)
		}
		.padding(24)
		.background(Color.gray.opacity(0.3))
		.fixedSize()
		try Self.write(view, to: directory.appending(path: "password-popup-\(dark ? "dark" : "light").png"), dark: dark)
	}

	/// The window: the chrome, the sidebar's column and the page card beside it.
	private func window(sidebar: Sidebar) -> some View {
		let page: CGRect = switch sidebar {
		case .left:
			CGRect(x: Self.sidebarWidth, y: Self.inset, width: Self.size.width - Self.sidebarWidth - Self.inset, height: Self.size.height - 2 * Self.inset)
		case .right:
			CGRect(x: Self.inset, y: Self.inset, width: Self.size.width - Self.sidebarWidth - Self.inset, height: Self.size.height - 2 * Self.inset)
		case .hidden:
			CGRect(origin: .zero, size: Self.size).insetBy(dx: Self.inset, dy: Self.inset)
		}
		return ZStack(alignment: .topLeading) {
			Color(red: 0.42, green: 0.36, blue: 0.62)
			if sidebar != .hidden {
				VStack(alignment: .leading, spacing: 10) {
					ForEach(0..<8) { index in
						RoundedRectangle(cornerRadius: 6)
							.fill(.white.opacity(index == 2 ? 0.35 : 0.15))
							.frame(height: 28)
					}
				}
				.padding(14)
				.frame(width: Self.sidebarWidth)
				.offset(x: sidebar == .left ? 0 : Self.size.width - Self.sidebarWidth, y: 44)
			}
			RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius)
				.fill(Color.white)
				.overlay(alignment: .top) {
					Text("localhost:8000/login")
						.font(.title2)
						.foregroundStyle(.black.opacity(0.6))
						.padding(.top, 80)
				}
				.pagePopupArea()
				.frame(width: page.width, height: page.height)
				.offset(x: page.minX, y: page.minY)
		}
		.frame(width: Self.size.width, height: Self.size.height)
	}

	private static let errorText: String = "The operation couldn’t be completed. (BrowserCore.BrowserOrganization.ValidationError error 20.)"

	private static var saveError: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(errorText).font(.callout)
			HStack {
				Button("Retry saving") {}
				Button("Export unsaved workspace…") {}
			}
		}
		.padding()
		.frame(maxWidth: 560, alignment: .leading)
		.pagePopupSurface()
	}

	private static func passwordCard(isUpdate: Bool) -> some View {
		PagePopupCard(
			symbol: isUpdate ? "key.horizontal.fill" : "key.fill",
			title: isUpdate ? "Update password for localhost?" : "Save password for localhost?",
			detail: "tester@example.com"
		) {
			Text("Saved only in this profile.")
				.font(.caption)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.frame(maxWidth: .infinity)
		} actions: {
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				AppLinkPromptButton(isUpdate ? "Keep Old" : "Never") {}
				AppLinkPromptButton("Not Now") {}
			}
			AppLinkPromptButton(isUpdate ? "Update" : "Save", prominence: .primary, keyHint: .return) {}
		}
	}

	/// The save error as `main` drew it.
	private static var oldSaveError: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(errorText).font(.callout)
			HStack {
				Button("Retry saving") {}
				Button("Export unsaved workspace…") {}
			}
		}
		.padding()
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
		.padding()
	}

	/// The save-password pop-up as `main` drew it.
	private static var oldPasswordCard: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Save password for localhost?").font(.headline)
			Text("tester@example.com")
			Text("Saved only in this profile.")
				.font(.caption)
				.foregroundStyle(.secondary)
			HStack {
				Button("Never") {}
				Button("Not Now") {}
				Button("Save") {}.keyboardShortcut(.defaultAction)
			}
		}
		.padding()
		.frame(maxWidth: 420, alignment: .leading)
		.background(.regularMaterial, in: .rect(cornerRadius: 16, style: .continuous))
		.padding()
	}

	private static func write(
		_ view: some View,
		to url: URL,
		dark: Bool = true
	) throws {
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
		defer { window.close() }
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: url)
	}
}
