import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing

/// Writes offscreen PNGs of the browser chrome for visual self-review.
///
/// Runs only when `ARX_DESIGN_SNAPSHOTS` names an output directory. With `xcodebuild test`,
/// pass it as `TEST_RUNNER_ARX_DESIGN_SNAPSHOTS=<dir>`.
@MainActor
@Suite(.enabled(if: DesignSnapshotOutput.directory != nil))
internal struct DesignSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func window(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			DesignSnapshotWindow(showsCommandBar: false),
			size: .init(width: 1100, height: 720),
			appearance: appearance,
			name: "window"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func commandBar(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			DesignSnapshotWindow(showsCommandBar: true),
			// Wide enough for the palette's default width (DEV-803), not the narrow-window cap.
			size: .init(width: 1440, height: 900),
			appearance: appearance,
			name: "command-bar"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func sidebar(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			ZStack {
				BrowserChromeBackground(textured: true)
				DesignSnapshotSidebar()
			},
			size: .init(width: 286, height: 720),
			appearance: appearance,
			name: "sidebar"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func library(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			ZStack {
				BrowserChromeBackground(textured: true)
				DesignSnapshotSidebar(
					library: .init(
						isOpen: true,
						progress: .constant(1),
						sections: [.media, .downloads, .spaces, .archive],
						selection: .downloads,
						setOpen: { _ in },
						select: { _ in }
					)
				)
			},
			size: .init(width: 416, height: 720),
			appearance: appearance,
			name: "library"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func spaceIconPicker(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			SpaceIconPicker(selection: .plane, onSelect: { _ in })
				.background(
					.regularMaterial,
					in: .rect(cornerRadius: BrowserMetrics.FloatingPanel.cornerRadius)
				),
			size: .init(width: BrowserMetrics.IconPicker.width, height: 380),
			appearance: appearance,
			name: "space-icon-picker"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func templateField(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			VStack(alignment: .leading, spacing: 12) {
				TemplateField(
					"Template",
					text: .constant("https://kk{host}{path}{query}{unknown}"),
					placeholders: [.host, .path, .query]
				)
				ArxSuggestionList(
					[TemplatePlaceholder.host, .path, .query, .fragment].map {
						ArxSuggestion(id: $0.id, title: $0.title, symbol: $0.symbol)
					},
					highlighted: TemplatePlaceholder.path.id
				) { _ in }
			}
			.padding(16)
			.background(BrowserChromeBackground(textured: true)),
			size: .init(width: 420, height: 240),
			appearance: appearance,
			name: "template-field"
		)
	}

	@Test(arguments: [NSAppearance.Name.darkAqua])
	func profileCreation(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			ProfileCreationView(name: .constant(""), onCancel: {}, onCreate: {})
				.background(BrowserTheme.commandBackground),
			size: .init(width: 450, height: 480),
			appearance: appearance,
			name: "profile-creation"
		)
	}

	/// Half way through a swipe, to compare with the same moment in Arc.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func libraryMidway(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			ZStack {
				BrowserChromeBackground(textured: true)
				DesignSnapshotSidebar(
					library: .init(
						isOpen: false,
						progress: .constant(0.5),
						sections: [.media, .downloads, .spaces, .archive],
						selection: .downloads,
						setOpen: { _ in },
						select: { _ in }
					)
				)
			},
			size: .init(width: 416, height: 720),
			appearance: appearance,
			name: "library-midway"
		)
	}

	/// The welcome page after its entrance has played.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func onboardingWelcome(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			OnboardingWelcomeSnapshot(hasAppeared: true),
			size: OnboardingWelcomeSnapshot.size,
			appearance: appearance,
			name: "onboarding-welcome"
		)
	}

	/// "Links from other apps" after its illustration has played, before and after Arx is the default.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func onboardingDefaultBrowser(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			OnboardingDefaultBrowserSnapshot(note: .otherBrowser("Safari")),
			size: OnboardingWelcomeSnapshot.size,
			appearance: appearance,
			name: "onboarding-default-browser"
		)
		try snapshot(
			OnboardingDefaultBrowserSnapshot(note: .isDefault),
			size: OnboardingWelcomeSnapshot.size,
			appearance: appearance,
			name: "onboarding-default-browser-done"
		)
	}

	/// "Make it yours" choosing what to bring from Arc, while importing, and after a partial import.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func onboardingImportSummary(_ appearance: NSAppearance.Name) throws {
		for (name, content) in OnboardingImportSummarySnapshot.contents {
			try snapshot(
				OnboardingImportSummarySnapshot(content: content),
				size: OnboardingWelcomeSnapshot.size,
				appearance: appearance,
				name: "onboarding-import-\(name)"
			)
		}
	}

	/// Each tour page at its demo's key frame: the frame Reduce Motion shows.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func onboardingTour(_ appearance: NSAppearance.Name) throws {
		for demo in TourDemo.allCases {
			try snapshot(
				OnboardingTourSnapshot(demo: demo),
				size: OnboardingWelcomeSnapshot.size,
				appearance: appearance,
				name: "onboarding-tour-\(demo.fileName)"
			)
		}
	}

	/// The chats demo before a suggestion is chosen, beside its key frame's streamed answer.
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	func onboardingTourChatsSuggestions(_ appearance: NSAppearance.Name) throws {
		try snapshot(
			OnboardingTourSnapshot(demo: .chats, time: 2),
			size: OnboardingWelcomeSnapshot.size,
			appearance: appearance,
			name: "onboarding-tour-chats-suggestions"
		)
	}

	/// Rendered with `ImageRenderer`, which keeps SwiftUI's blurs and blend modes that a
	/// cached AppKit display drops; the liquid glass depends on them.
	@Test(arguments: [ColorScheme.light, .dark])
	func identityCards(_ colorScheme: ColorScheme) throws {
		let directory = try #require(DesignSnapshotOutput.directory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let styles = IdentityCardStyle.allCases
		let rows = stride(from: 0, to: styles.count, by: 6).map { Array(styles[$0..<min($0 + 6, styles.count)]) }
		let renderer = ImageRenderer(content: VStack(alignment: .leading, spacing: 24) {
			ForEach(rows, id: \.self) { row in
				HStack(alignment: .top, spacing: 24) {
					ForEach(row, id: \.self) { style in
						ArxIdentityCard(style: style, stats: .init(profiles: 2, spaces: 5, tabs: 38), cycle: {})
					}
				}
			}
		}
		.padding(24)
		.background(colorScheme == .dark ? Color(white: 0.12) : Color(white: 0.96))
		.environment(\.colorScheme, colorScheme))
		renderer.scale = 2
		let image = try #require(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
		let data = try #require(image.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "identity-cards-\(colorScheme == .dark ? "dark" : "light").png"))
	}

	private func snapshot(
		_ view: some View,
		size: CGSize,
		appearance name: NSAppearance.Name,
		name fileName: String
	) throws {
		let directory = try #require(DesignSnapshotOutput.directory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let representation = try render(view, size: size, appearance: name)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		let suffix = name == .darkAqua ? "dark" : "light"
		try data.write(to: directory.appending(path: "\(fileName)-\(suffix).png"))
	}
}

@MainActor
@Suite
internal struct IdentityCardRenderingTests {
	/// Every style draws its own card at the same footprint, with the cycle control beneath.
	@Test
	func everyStyleRendersDistinctly() throws {
		let size = CGSize(width: 278, height: 380)
		var images: [IdentityCardStyle: Data] = [:]
		for style in IdentityCardStyle.allCases {
			let card = ArxIdentityCard(style: style, stats: .init(profiles: 1, spaces: 3, tabs: 12), cycle: {})
				.padding(24)
			images[style] = try render(card, size: size, appearance: .aqua).tiffRepresentation
		}
		#expect(Set(images.values).count == IdentityCardStyle.allCases.count)
	}
}

@MainActor
@Suite
internal struct SidebarLayoutRenderingTests {
	/// The Library stays mounted while closed, and must not disturb the sidebar it hides behind.
	@Test
	func closedLibraryLeavesTheSidebarUntouched() throws {
		let size = CGSize(width: 286, height: 720)
		let plain = try render(DesignSnapshotSidebar(), size: size, appearance: .aqua)
		let withLibrary = try render(
			DesignSnapshotSidebar(
				library: .init(
					isOpen: false,
					progress: .constant(0),
					sections: [.media, .downloads, .spaces, .archive],
					selection: .downloads,
					setOpen: { _ in },
					select: { _ in }
				)
			),
			size: size,
			appearance: .aqua
		)
		#expect(plain.tiffRepresentation == withLibrary.tiffRepresentation)
	}
}

@MainActor
@Suite
internal struct OnboardingWelcomeRenderingTests {
	/// The settled page draws the logo, wordmark, tagline and Get Started in both appearances.
	@Test
	func welcomePageRendersInBothAppearances() throws {
		let size = OnboardingWelcomeSnapshot.size
		let light = try render(OnboardingWelcomeSnapshot(hasAppeared: true), size: size, appearance: .aqua)
		let dark = try render(OnboardingWelcomeSnapshot(hasAppeared: true), size: size, appearance: .darkAqua)
		let background = try render(OnboardingWelcomeSnapshot.background, size: size, appearance: .aqua)

		#expect(light.tiffRepresentation != background.tiffRepresentation)
		#expect(light.tiffRepresentation != dark.tiffRepresentation)
	}

	/// The default-browser page draws its illustration and footer, and its note follows the status.
	@Test
	func importSummaryPageRendersEachState() throws {
		let size = OnboardingWelcomeSnapshot.size
		let images = try OnboardingImportSummarySnapshot.contents.map { _, content in
			try render(OnboardingImportSummarySnapshot(content: content), size: size, appearance: .aqua)
		}
		let background = try render(OnboardingWelcomeSnapshot.background, size: size, appearance: .aqua)

		#expect(images[0].tiffRepresentation != background.tiffRepresentation)
		#expect(images[0].tiffRepresentation != images[1].tiffRepresentation)
		#expect(images[1].tiffRepresentation != images[2].tiffRepresentation)
	}

	/// Each tour page draws its key frame over the background, differently in light and dark,
	/// and differently from the other pages.
	@Test
	func tourPagesRenderInBothAppearances() throws {
		let size = OnboardingWelcomeSnapshot.size
		let background = try render(OnboardingWelcomeSnapshot.background, size: size, appearance: .aqua)
		var pages: [Data?] = []
		for demo in TourDemo.allCases {
			let light = try render(OnboardingTourSnapshot(demo: demo), size: size, appearance: .aqua)
			let dark = try render(OnboardingTourSnapshot(demo: demo), size: size, appearance: .darkAqua)

			#expect(light.tiffRepresentation != background.tiffRepresentation)
			#expect(light.tiffRepresentation != dark.tiffRepresentation)
			pages.append(light.tiffRepresentation)
		}
		#expect(Set(pages).count == TourDemo.allCases.count)
	}

	@Test
	func defaultBrowserPageRendersInBothAppearances() throws {
		let size = OnboardingWelcomeSnapshot.size
		let light = try render(OnboardingDefaultBrowserSnapshot(note: .otherBrowser("Safari")), size: size, appearance: .aqua)
		let dark = try render(OnboardingDefaultBrowserSnapshot(note: .otherBrowser("Safari")), size: size, appearance: .darkAqua)
		let isDefault = try render(OnboardingDefaultBrowserSnapshot(note: .isDefault), size: size, appearance: .aqua)
		let background = try render(OnboardingWelcomeSnapshot.background, size: size, appearance: .aqua)

		#expect(light.tiffRepresentation != background.tiffRepresentation)
		#expect(light.tiffRepresentation != dark.tiffRepresentation)
		#expect(light.tiffRepresentation != isDefault.tiffRepresentation)
	}
}

@MainActor
private func render(
	_ view: some View,
	size: CGSize,
	appearance name: NSAppearance.Name
) throws -> NSBitmapImageRep {
	let window = NSWindow(
		contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
		styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
		backing: .buffered,
		defer: false
	)
	window.titlebarAppearsTransparent = true
	window.titleVisibility = .hidden
	window.isReleasedWhenClosed = false
	window.appearance = NSAppearance(named: name)

	let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
	host.safeAreaRegions = []
	host.frame = .init(origin: .zero, size: size)
	window.contentView = host

	for _ in 0..<6 {
		host.layoutSubtreeIfNeeded()
		RunLoop.main.run(until: .now.addingTimeInterval(0.05))
	}

	let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
	host.cacheDisplay(in: host.bounds, to: representation)
	window.close()
	return representation
}

private enum DesignSnapshotOutput {
	static var directory: URL? {
		ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"].map { path in
			URL(fileURLWithPath: path, isDirectory: true)
		}
	}
}

private struct DesignSnapshotWindow: View {
	let showsCommandBar: Bool

	var body: some View {
		ZStack {
			BrowserChromeBackground(textured: true)
			BrowserSidebarLayout(isPinned: true) {
				DesignSnapshotSidebar()
			} page: {
				DesignSnapshotPage()
					.padding([.top, .bottom, .trailing], BrowserMetrics.PageCard.inset)
			}
		}
		.commandBarPresentation(
			isPresented: showsCommandBar,
			anchoredToURL: false,
			onDismiss: {}
		) { maximumHeight in
			CommandBar(
				query: .constant("swift"),
				selectedID: .constant("search"),
				results: DesignSnapshotFixture.results,
				maximumResultsHeight: maximumHeight,
				onSelect: { _ in },
				onDismiss: {}
			)
		}
		.environment(\.browserFilmGrain, .init())
	}
}

private struct DesignSnapshotSidebar: View {
	var library: SidebarLibrary?

	var body: some View {
		SidebarPager(
			spaces: [DesignSnapshotFixture.space],
			selectedSpaceID: DesignSnapshotFixture.space.id,
			navigation: .init(canGoBack: true, isAvailable: true),
			library: library,
			onSelectSpace: { _ in },
			onAction: { _, _ in },
			onCopyURL: {}
		) {
			HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
				Image(systemName: "plus.square")
				Spacer()
				spaceButton("Work", symbol: "briefcase", isSelected: true)
				spaceButton("Home", symbol: "house", isSelected: false)
				spaceButton("Read", symbol: "book", isSelected: false)
				Spacer()
				Image(systemName: "plus")
			}
			.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize - 2, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.padding(.horizontal, 14)
			.frame(height: BrowserMetrics.SpaceSwitcher.height)
		} libraryPanel: {
			DesignSnapshotDownloads()
		}
	}

	private func spaceButton(
		_ name: String,
		symbol: String,
		isSelected: Bool
	) -> some View {
		SidebarSpaceButton(
			name: name,
			symbol: symbol,
			isSelected: isSelected,
			onSelect: {},
			onDropTabs: { _ in }
		)
	}
}

private struct DesignSnapshotDownloads: View {
	var body: some View {
		VStack(spacing: 0) {
			SidebarLibraryHeader(placeholder: "Search Downloads...", query: .constant("")) {
				SidebarLibraryMenu(title: "Filter", symbol: "line.3.horizontal.decrease.circle") { EmptyView() }
			}
			SidebarLibraryGroupHeader(title: "3 days ago")
			row("grok_bot_0.78.1.dmg", "Disk Image from cursor.com")
			SidebarLibraryGroupHeader(title: "1 week ago")
			row("installer-0.38.6.dmg", "Disk Image from vercel-storage.com")
			row("capturecontext-sample-0387e1b4d2f6a9c1e5b7.pdf", "Download")
		}
	}

	private func row(_ title: String, _ subtitle: String) -> some View {
		SidebarLibraryRow(title: title, subtitle: subtitle, action: {}) {
			Image(systemName: "doc")
				.foregroundStyle(BrowserTheme.secondary)
		}
	}
}

private struct DesignSnapshotPage: View {
	var body: some View {
		ZStack {
			BrowserTheme.page
			Text(verbatim: "capturecontext.dev")
				.font(.system(size: 23, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(0.5))
		}
		.browserPageCard()
	}
}

private enum DesignSnapshotFixture {
	static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
	}

	static let selectedID: SidebarItem.ID = .tab(id(20))

	static let space: SidebarSpace = .init(
		id: id(1),
		name: "Work",
		favorites: [
			.init(id: .tab(id(10)), title: "Mail", symbol: "envelope.fill", tint: .blue),
			.init(id: .tab(id(11)), title: "Calendar", symbol: "calendar", tint: .orange),
			.init(id: .tab(id(12)), title: "Notes", symbol: "note.text", tint: .yellow),
			.init(id: .tab(id(13)), title: "Music", symbol: "music.note", tint: .pink),
		],
		savedItems: [
			.init(
				id: .folder(id(30)),
				title: "Projects",
				children: [
					.init(id: .tab(id(31)), title: "Roadmap", symbol: "map", tint: .green),
					.init(id: .tab(id(32)), title: "Design review", symbol: "paintbrush", tint: .lavender),
				],
				isExpanded: true
			),
			.init(id: selectedID, title: "Pull requests", symbol: "arrow.triangle.pull", tint: .lavender),
			.init(id: .tab(id(21)), title: "Documentation", symbol: "book.closed", tint: .blue),
		],
		unpinnedTabs: [
			.init(
				id: .tab(id(40)),
				title: "Swift Forums",
				symbol: "bubble.left.and.bubble.right",
				tint: .orange,
				isPinned: false
			),
			.init(
				id: .tab(id(41)),
				title: "Release notes",
				symbol: "doc.text",
				tint: .green,
				isPinned: false
			),
		],
		selectedID: selectedID,
		url: URL(string: "https://github.com/pulls")
	)

	static let results: [CommandBarResult] = [
		.init(
			id: "search",
			title: "Search for “swift”",
			subtitle: "Search",
			actionTitle: "Search",
			symbol: "magnifyingglass"
		),
		.init(
			id: "tab",
			title: "Swift Forums",
			subtitle: "forums.swift.org",
			actionTitle: "Switch to Tab",
			symbol: "bubble.left.and.bubble.right",
			tint: .orange
		),
		.init(
			id: "docs",
			title: "Swift documentation",
			subtitle: "swift.org/documentation",
			actionTitle: "Open",
			symbol: "book.closed",
			tint: .blue
		),
		.init(id: "command", title: "New Folder", actionTitle: "Run", symbol: "folder.badge.plus"),
	]
}

private struct OnboardingWelcomeSnapshot: View {
	static let size: CGSize = .init(width: 760, height: 540)

	static var background: some View {
		Color(nsColor: .windowBackgroundColor)
	}

	let hasAppeared: Bool

	var body: some View {
		ZStack {
			Self.background
			VStack(spacing: 0) {
				OnboardingWelcomePage(hasAppeared: hasAppeared, getStarted: {})
				OnboardingFooter(
					progress: nil,
					back: nil,
					skipTitle: String.localized(.appUI.onboarding.skipSetup),
					skip: {},
					primaryTitle: nil,
					primary: nil
				)
			}
		}
	}
}

private struct OnboardingImportSummarySnapshot: View {
	static let browsers: [OnboardingImportSummary.Browser] = [
		.init(id: "arc", name: "Arc", status: .defaultBrowser, isSelected: true),
		.init(id: "chrome", name: "Google Chrome", status: .usedMostRecently, isSelected: false),
		.init(id: "safari", name: "Safari", status: .unsupported, isSelected: false),
	]

	static let contents: [(String, OnboardingImportSummary.Content)] = [
		(
			"choosing",
			.choosing(
				.init(
					browserName: "Arc",
					isReading: false,
					rows: [
						.init(category: .favorites, count: 8, isOn: true),
						.init(category: .bookmarks, count: 78, folders: 10, isOn: true),
						.init(category: .openTabs, count: 23, alreadyImported: 4, isOn: false),
					],
					keepsSpaces: true,
					unavailable: [.history, .extensions, .passwords]
				)
			)
		),
		(
			"importing",
			.importing(.init(browserName: "Arc", category: .bookmarks, fraction: 0.5, isCancelling: false))
		),
		(
			"partial",
			.finished(.init(browserName: "Arc", outcome: .partiallyCompleted, importedCount: 86))
		),
	]

	let content: OnboardingImportSummary.Content

	var body: some View {
		ZStack {
			OnboardingWelcomeSnapshot.background
			VStack(spacing: 0) {
				OnboardingImportSummaryPage(
					summary: .init(browsers: Self.browsers, content: content),
					selectBrowser: { _ in },
					toggleCategory: { _ in },
					setKeepsSpaces: { _ in },
					customize: {},
					cancel: {}
				)
				OnboardingFooter(
					progress: (5, 2),
					back: {},
					skipTitle: String.localized(.appUI.onboarding.makeItYours.startFresh),
					skip: {},
					primaryTitle: String.localized(.appUI.onboarding.makeItYours.bring("Arc")),
					primary: {}
				)
			}
		}
	}
}

private struct OnboardingDefaultBrowserSnapshot: View {
	let note: OnboardingDefaultBrowserPage.Note

	var body: some View {
		ZStack {
			OnboardingWelcomeSnapshot.background
			VStack(spacing: 0) {
				OnboardingDefaultBrowserPage(note: note, hasAppeared: true)
				OnboardingFooter(
					progress: (5, 4),
					back: {},
					skipTitle: String.localized(.appUI.onboarding.defaultBrowser.notNow),
					skip: note == .isDefault ? nil : {},
					primaryTitle: note == .isDefault
					? String.localized(.appUI.onboarding.continue)
					: String.localized(.appUI.onboarding.defaultBrowser.makeDefault),
					primary: {}
				)
			}
		}
	}
}

private struct OnboardingTourSnapshot: View {
	let demo: TourDemo
	var time: TimeInterval? = nil

	var body: some View {
		ZStack {
			OnboardingWelcomeSnapshot.background
			VStack(spacing: 0) {
				OnboardingTourPage(demo: demo, frozenTime: time ?? demo.keyFrame)
				OnboardingFooter(
					progress: (9, 1 + (TourDemo.allCases.firstIndex(of: demo) ?? 0)),
					back: {},
					skipTitle: String.localized(.appUI.onboarding.tour.skip),
					skip: {},
					primaryTitle: String.localized(.appUI.onboarding.continue),
					primary: {}
				)
			}
		}
	}
}
