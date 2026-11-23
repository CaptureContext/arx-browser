import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// Writes offscreen PNGs of onboarding's Sync with iCloud and Make it yours pages as the
/// onboarding window draws them, footer included, when `ARX_DESIGN_SNAPSHOTS` names a directory
/// (the onboarding update ticket, DEV-1300): each to compare with its Figma frame, light and dark.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct OnboardingPagesSnapshotTests {
	private static let size: CGSize = .init(width: 760, height: 540)

	// MARK: - Sync with iCloud

	@Test(arguments: [false, true])
	internal func iCloudReady(dark: Bool) throws {
		try write(
			OnboardingICloudPage(status: .none),
			footer: footer(skip: .localized(.appUI.onboarding.iCloud.notNow), primary: .localized(.appUI.onboarding.iCloud.sync)),
			name: "onboarding-icloud-ready",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func iCloudSyncing(dark: Bool) throws {
		try write(
			OnboardingICloudPage(status: .syncing(.organization)),
			footer: footer(primary: .localized(.appUI.onboarding.iCloud.sync), isPrimaryEnabled: false),
			name: "onboarding-icloud-syncing",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func iCloudSlow(dark: Bool) throws {
		try write(
			OnboardingICloudPage(status: .slow(.history)),
			footer: footer(primary: .localized(.appUI.onboarding.iCloud.continueWithoutWaiting)),
			name: "onboarding-icloud-slow",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func iCloudFailed(dark: Bool) throws {
		try write(
			OnboardingICloudPage(status: .failed(nil)),
			footer: footer(
				skip: .localized(.appUI.onboarding.iCloud.continueWithoutWaiting),
				primary: .localized(.appUI.onboarding.iCloud.tryAgain)
			),
			name: "onboarding-icloud-failed",
			dark: dark
		)
	}

	@Test(arguments: [false, true])
	internal func iCloudAdopted(dark: Bool) throws {
		try write(
			OnboardingICloudPage(status: .adopted),
			footer: footer(primary: .localized(.appUI.onboarding.continue)),
			name: "onboarding-icloud-adopted",
			dark: dark
		)
	}

	// MARK: - Make it yours

	@Test(arguments: [false, true])
	internal func makeItYoursChrome(dark: Bool) throws {
		try write(
			importPage(.init(browsers: browsers(selected: "chrome"), content: .choosing(chromeChoosing))),
			footer: footer(skip: .localized(.appUI.onboarding.makeItYours.startFresh), primary: .localized(.appUI.onboarding.makeItYours.bring("Chrome"))),
			name: "onboarding-make-it-yours-chrome",
			dark: dark
		)
	}

	/// Arc's longer card scrolled to its end: content passes under the page's header and the
	/// footer.
	@Test(arguments: [false, true])
	internal func makeItYoursArcScrolled(dark: Bool) throws {
		try write(
			importPage(.init(browsers: browsers(selected: "arc"), content: .choosing(arcChoosing))),
			footer: footer(skip: .localized(.appUI.onboarding.makeItYours.startFresh), primary: .localized(.appUI.onboarding.makeItYours.bring("Arc"))),
			name: "onboarding-make-it-yours-arc-scrolled",
			dark: dark,
			scrollsToEnd: true
		)
	}

	@Test(arguments: [false, true])
	internal func makeItYoursFinished(dark: Bool) throws {
		try write(
			importPage(.init(
				browsers: browsers(selected: "chrome"),
				content: .finished(.init(
					browserName: "Chrome",
					outcome: .completed,
					importedCount: 1_284,
					extensions: .init(total: 5, installed: 3, notInstalled: 2)
				)),
				canChangeBrowser: false
			)),
			footer: footer(primary: .localized(.appUI.onboarding.continue)),
			name: "onboarding-make-it-yours-finished",
			dark: dark
		)
	}

	// MARK: - Sample data

	private func browsers(selected: String) -> [OnboardingImportSummary.Browser] {
		[
			.init(id: "chrome", name: "Chrome", status: .defaultBrowser, isSelected: selected == "chrome", icon: icon("com.google.Chrome")),
			.init(id: "arc", name: "Arc", status: .usedMostRecently, isSelected: selected == "arc", icon: icon("company.thebrowser.Browser")),
			.init(id: "safari", name: "Safari", status: .onThisMac, isSelected: selected == "safari", icon: icon("com.apple.Safari")),
		]
	}

	private var chromeChoosing: OnboardingImportSummary.Choosing {
		.init(
			browserName: "Chrome",
			isReading: false,
			rows: [
				.init(category: .bookmarks, count: 214, folders: 12, isOn: true),
				.init(category: .openTabs, count: 18, isOn: true),
				.init(category: .history, count: 2_870, isOn: true),
				.init(category: .extensions, count: 3, fromStore: 3, isOn: true),
			],
			keepsSpaces: nil,
			offersPasswords: true,
			unavailable: []
		)
	}

	private var arcChoosing: OnboardingImportSummary.Choosing {
		.init(
			browserName: "Arc",
			isReading: false,
			rows: [
				.init(category: .favorites, count: 8, isOn: true),
				.init(category: .bookmarks, count: 46, folders: 5, isOn: true),
				.init(category: .openTabs, count: 31, isOn: true),
				.init(category: .history, count: 2_870, isOn: true),
				.init(category: .extensions, count: 4, fromStore: 4, isOn: true),
			],
			keepsSpaces: true,
			offersPasswords: true,
			unavailable: []
		)
	}

	private func importPage(_ summary: OnboardingImportSummary) -> some View {
		OnboardingImportSummaryPage(
			summary: summary,
			selectBrowser: { _ in },
			toggleCategory: { _ in },
			setKeepsSpaces: { _ in },
			customize: {},
			cancel: {}
		)
	}

	private func icon(_ bundleIdentifier: String) -> NSImage? {
		NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
			NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false))
		}
	}

	private func footer(
		skip: String? = nil,
		primary: String,
		isPrimaryEnabled: Bool = true
	) -> OnboardingFooter {
		OnboardingFooter(
			progress: (count: 11, current: 1),
			back: {},
			skipTitle: skip ?? "",
			skip: skip.map { _ in {} },
			primaryTitle: primary,
			primary: {},
			isPrimaryEnabled: isPrimaryEnabled
		)
	}

	// MARK: - Rendering

	/// The page under the footer, over Arx's soft edge, as `OnboardingView` lays them out.
	private func write(
		_ page: some View,
		footer: OnboardingFooter,
		name: String,
		dark: Bool,
		scrollsToEnd: Bool = false
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = OnboardingSnapshotWindow(page: page, footer: footer)
			.frame(width: Self.size.width, height: Self.size.height)
			.background(Color(nsColor: .windowBackgroundColor))
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
		settle(host)
		if scrollsToEnd {
			for scrollView in scrollViews(in: host) where scrollView.hasVerticalScroller || scrollView.documentView != nil {
				guard let document = scrollView.documentView else { continue }

				let maxY = document.isFlipped
				? document.frame.height - scrollView.contentView.bounds.height + scrollView.contentInsets.bottom
				: -scrollView.contentInsets.top
				scrollView.contentView.scroll(to: .init(x: 0, y: max(-scrollView.contentInsets.top, maxY)))
				scrollView.reflectScrolledClipView(scrollView.contentView)
			}
			settle(host)
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}

	/// Lets layout, scroll geometry and the preferences built on it settle, so the soft edges
	/// that follow scrolling are drawn.
	private func settle(_ host: NSView) {
		for _ in 0..<12 {
			host.layoutSubtreeIfNeeded()
			host.display()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
	}

	private func scrollViews(in view: NSView) -> [NSScrollView] {
		let own: [NSScrollView] = (view as? NSScrollView).map { [$0] } ?? []
		return own + view.subviews.flatMap(scrollViews(in:))
	}
}

/// The onboarding window's layout without its store: the page, with the footer as a bottom
/// safe-area inset over the soft edge its scrolling content reports.
private struct OnboardingSnapshotWindow<Page: View>: View {
	let page: Page
	let footer: OnboardingFooter

	@SwiftUI.State
	private var edge: CGFloat = 0

	var body: some View {
		page
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.safeAreaInset(edge: .bottom, spacing: 0) {
				footer.background(alignment: .bottom) { OnboardingFooterEdge(reveal: edge) }
			}
			.onPreferenceChange(OnboardingFooterEdgeKey.self) { edge = $0 }
			.padding(.top, 28)
			.ignoresSafeArea()
	}
}
