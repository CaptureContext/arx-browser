import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Page PiP's header is Little Arx's (DEV-1105): the same height, background, URL bar with the
/// profile, and Back, with Return to Tab for the window's buttons and no "Open in". With
/// `ARX_DESIGN_SNAPSHOTS` naming a directory, writes both, one above the other, in light and dark,
/// and Little Arx's with reading mode and Translation Available under the address.
@MainActor
@Suite(.renderTurn)
internal struct LittleWindowHeaderSnapshotTests {
	private static let url: URL = .init(string: "https://www.example.com/watch/live")!
	private static let width: CGFloat = 560

	@Test
	internal func pagePictureInPicturesHeaderIsAsTallAsLittleArxs() async throws {
		let little = NSHostingView(rootView: Self.littleArx.frame(width: Self.width))
		let picture = NSHostingView(rootView: Self.pagePicture.frame(width: Self.width))
		#expect(little.fittingSize.height == BrowserMetrics.LittleArx.toolbarHeight)
		#expect(picture.fittingSize.height == little.fittingSize.height)
	}

	/// Page PiP's narrowest window, 300 points, holds every control of its header.
	@Test
	internal func pagePictureInPicturesHeaderFitsItsNarrowestWindow() async throws {
		// Proposed almost no width, the header takes the least it can.
		let narrowest = NSHostingController(rootView: Self.pagePicture)
			.sizeThatFits(in: .init(width: 1, height: BrowserMetrics.LittleArx.toolbarHeight))
		#expect(narrowest.width > 200)
		#expect(narrowest.width <= 300)
	}

	/// Everything in the URL bar fits its narrowest width, a long profile name included
	/// (DEV-1153): the picker shows only its face there. The header's own size can't show this,
	/// since the URL bar's minimum width hides what overflows inside it.
	@Test(arguments: [Self.longName, "Personal"])
	internal func theURLBarsContentFitsItsNarrowestWidth(profile: String) async throws {
		let bar = URLBar(
			url: Self.url,
			height: BrowserMetrics.LittleArx.addressHeight,
			centersAddress: true,
			prominentActions: true,
			leading: AnyView(Self.picker(named: profile)),
			onActivate: nil,
			onCopy: {}
		)
		let narrowest = NSHostingController(rootView: bar)
			.sizeThatFits(in: .init(width: 1, height: BrowserMetrics.LittleArx.addressHeight))
		#expect(narrowest.width <= BrowserMetrics.LittleArx.addressMinimumWidth)
	}

	/// The picker shows the profile's name while there's room, cut short past its widest, and
	/// only its face where there isn't.
	@Test
	internal func theProfilePickerFallsBackToItsFace() async throws {
		func width(_ name: String, proposed: CGFloat?) -> CGFloat {
			NSHostingController(rootView: Self.picker(named: name))
				.sizeThatFits(in: .init(width: proposed ?? 10_000, height: BrowserMetrics.LittleArx.addressHeight))
				.width
		}

		let face = width(Self.longName, proposed: 1)
		#expect(face < 40)
		#expect(width("Personal", proposed: 1) == face)
		#expect(width("Personal", proposed: nil) > face)
		#expect(width(Self.longName, proposed: nil) <= LittleWindowProfilePicker.maximumWidth)
		// Between the two, a long name is cut shorter rather than dropped.
		let compact = width(Self.longName, proposed: LittleWindowProfilePicker.compactWidth)
		#expect(compact > face)
		#expect(compact <= LittleWindowProfilePicker.compactWidth)
	}

	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func narrowHeaders(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"
		let headers = VStack(alignment: .leading, spacing: 12) {
			Text(verbatim: "Page PiP, 300 pt, a long profile name").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.pagePicture(profile: Self.longName), width: 300)
			Text(verbatim: "Page PiP, 300 pt").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.pagePicture(profile: "Personal"), width: 300)
			Text(verbatim: "Page PiP, 420 pt, a long profile name").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.pagePicture(profile: Self.longName), width: 420)
			Text(verbatim: "Little Arx, a long profile name").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.littleArx(profile: Self.longName))
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(headers, dark: dark, to: directory.appending(path: "page-pip-header-narrow-\(appearance).png"))
	}

	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func headers(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"
		let headers = VStack(alignment: .leading, spacing: 12) {
			Text(verbatim: "Little Arx").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.littleArx)
			Text(verbatim: "Page PiP").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.pagePicture)
			Text(verbatim: "Little Arx, reading, with a translation").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.littleArxReadingWithTranslation)
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(headers, dark: dark, to: directory.appending(path: "page-pip-header-\(appearance).png"))
	}

	/// Little Arx's header as its window builds it: the window's buttons (which a test window
	/// doesn't have), the profile picker and "Open in".
	private static var littleArx: some View { littleArx(profile: "Personal") }

	private static func littleArx(profile: String) -> some View {
		LittleWindowHeader(
			leading: .windowControls,
			url: url,
			isLoading: false,
			history: .back({}),
			onActivate: {},
			onCopy: {},
			profilePicker: { picker(named: profile) },
			accessory: {
				ChromeSplitButton(
					height: BrowserMetrics.LittleArx.addressHeight,
					moreHelp: "",
					action: {},
					onMore: {}
				) {
					Text(localized: .appUI.littleArx.openIn("Home"))
					ChromeKeyHint("⌘O")
				}
			}
		)
	}

	/// Little Arx's header in reading mode on a page that can be translated: the filled reading
	/// mode button, and Translation Available under the centred address (DEV-1028, DEV-996).
	private static var littleArxReadingWithTranslation: some View {
		LittleWindowHeader(
			leading: .windowControls,
			url: url,
			isLoading: false,
			history: .back({}),
			onActivate: {},
			onCopy: {},
			readingMode: .init(isReading: true) {},
			translation: .init(offer: .init(source: "fr", target: "en", phase: .available)) { _ in },
			profilePicker: { picker },
			accessory: { EmptyView() }
		)
	}

	private static var pagePicture: some View { pagePicture(profile: "Personal") }

	private static func pagePicture(profile: String) -> some View {
		// Back can go; Forward has nowhere to go, so it's disabled.
		PagePictureInPictureHeader(
			url: url,
			isLoading: false,
			onReturnToTab: {},
			onBack: {},
			onForward: nil,
			onCopy: {},
			profilePicker: { picker(named: profile) },
			dragArea: { Color.clear }
		)
	}

	private static var picker: some View { picker(named: "Personal") }

	/// A profile name longer than the widest badge.
	nonisolated private static let longName = "Engineering Research and Development"

	/// Little Arx's profile picker, the same control in both headers.
	private static func picker(named name: String) -> some View {
		let personal = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
		return LittleWindowProfilePicker(
			options: [
				.init(id: personal, name: name, isEnabled: true),
				.init(id: .init(rawValue: UUID()), name: "Work", isEnabled: true),
			],
			currentID: personal,
			onSelect: { _ in }
		)
	}

	/// The header over the page card, as in the window.
	private static func window(
		_ header: some View,
		width: CGFloat = Self.width
	) -> some View {
		ZStack {
			BrowserChromeBackground(textured: true)
			VStack(spacing: 0) {
				header
				Color.white
					.frame(height: 60)
					.browserPageCard(cornerRadius: BrowserMetrics.LittleArx.pageCornerRadius)
					.padding([.horizontal, .bottom], BrowserMetrics.LittleArx.pageInset)
			}
		}
		.frame(width: width)
		.clipShape(.rect(cornerRadius: BrowserMetrics.LittleArx.cornerRadius, style: .continuous))
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to file: URL
	) throws {
		let host = NSHostingView(rootView: view.fixedSize())
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
		try data.write(to: file)
		window.close()
	}
}
