import AppKit
@testable import AppUI
import Foundation
import Observation
import SwiftUI
import Testing

/// DEV-1311: listing or highlighting bangs asks only for what's stored. Only a bang's scoped
/// search lets the field fetch its site's icon, and leaving the scope lets go of it.
@MainActor
@Suite(
	.serialized,
	.renderTurn,
	.enabled(if: !NSScreen.screens.isEmpty, "Needs a window server to lay out views")
)
internal struct CommandBarSiteIconFetchTests {
	@Test
	internal func listingBangsFetchesNothing() async throws {
		let bar = HostedCommandBar(selectedID: "visited")
		defer { bar.close() }
		bar.settle(for: .milliseconds(300))

		// The page the person visited may fetch as any row on screen does; no bang's site does.
		#expect(bar.loader.fetched == [Page.visited])
		#expect(bar.loader.cached.isSuperset(of: [Page.github, Page.youtube, Page.wikipedia]))
	}

	@Test
	internal func highlightingABangFetchesNothing() async throws {
		let bar = HostedCommandBar(selectedID: "visited")
		defer { bar.close() }
		bar.settle()

		for id in ["bang-gh", "bang-yt", "bang-w"] {
			bar.inputs.selectedID = id
			bar.settle(for: .milliseconds(300))
		}
		#expect(bar.loader.fetched == [Page.visited])
		// The field shows the highlighted bang's stored icon, if any, from the same key.
		#expect(bar.loader.cachedRequests[Page.wikipedia, default: 0] >= 2)
	}

	@Test
	internal func aScopedSearchFetchesItsSiteAndLetsGoWhenItEnds() async throws {
		let bar = HostedCommandBar(selectedID: "bang-yt")
		bar.settle()
		#expect(!bar.loader.fetched.contains(Page.youtube))

		bar.inputs.scope = Page.youtube
		bar.settle(for: .milliseconds(300))
		#expect(bar.loader.fetched == [Page.visited, Page.youtube])
		#expect(bar.loader.fetchRequests[Page.youtube] == 1)

		// Leaving the scope, the field shows the highlighted bang's stored icon again and asks
		// for no fetch. (An offscreen window never ends a replaced view task, so the cache's tests
		// prove the fetch stops: `aFetchStopsWhenTheLastViewThatAllowedItGoes`.)
		let cachedRequests = bar.loader.cachedRequests[Page.youtube, default: 0]
		bar.inputs.scope = nil
		bar.settle(for: .milliseconds(300))
		#expect(bar.loader.fetchRequests[Page.youtube] == 1)
		#expect(bar.loader.cachedRequests[Page.youtube, default: 0] == cachedRequests + 1)
		bar.close()
	}
}

private enum Page {
	internal static let profile: UUID = .init(uuidString: "00000000-0000-0000-0000-000000001311")!
	internal static let visited: SidebarItem.SiteIcon = icon("https://visited.fixture.invalid/page")
	internal static let github: SidebarItem.SiteIcon = icon("https://github.com/")
	internal static let youtube: SidebarItem.SiteIcon = icon("https://www.youtube.com/")
	internal static let wikipedia: SidebarItem.SiteIcon = icon("https://en.wikipedia.org/")

	private static func icon(_ address: String) -> SidebarItem.SiteIcon {
		.init(profileID: profile, pageURL: URL(string: address)!)
	}
}

/// Records which icons views asked for, how often, and whether they may fetch them. Every stream
/// stays open with nothing, as for a site with no stored icon.
@MainActor
private final class RecordingSiteIcons {
	private(set) var fetched: Set<SidebarItem.SiteIcon> = []
	private(set) var cached: Set<SidebarItem.SiteIcon> = []
	private(set) var fetchRequests: [SidebarItem.SiteIcon: Int] = [:]
	private(set) var cachedRequests: [SidebarItem.SiteIcon: Int] = [:]

	internal var loader: BrowserSiteIconLoader {
		.init(
			icons: { [self] key in
				fetched.insert(key)
				fetchRequests[key, default: 0] += 1
				return .init { $0.yield(nil) }
			},
			cachedIcons: { [self] key in
				cached.insert(key)
				cachedRequests[key, default: 0] += 1
				return .init { $0.yield(nil) }
			}
		)
	}
}

@MainActor
@Observable
private final class CommandBarInputs {
	internal var selectedID: String?
	internal var scope: SidebarItem.SiteIcon?

	internal init(selectedID: String?) {
		self.selectedID = selectedID
	}

	internal let results: [CommandBarResult] = [
		.init(
			id: "visited",
			title: "A visited page",
			actionTitle: "Open",
			symbol: "clock.arrow.circlepath",
			siteIcon: Page.visited
		),
		bang("gh", "GitHub", Page.github),
		bang("yt", "YouTube", Page.youtube),
		bang("w", "Wikipedia", Page.wikipedia),
	]

	private static func bang(
		_ keyword: String,
		_ name: String,
		_ icon: SidebarItem.SiteIcon
	) -> CommandBarResult {
		.init(
			id: "bang-" + keyword,
			title: "!" + keyword + " · " + name,
			actionTitle: "Search site",
			symbol: "magnifyingglass",
			siteIcon: icon,
			siteIconFetch: .storedOnly
		)
	}
}

private struct CommandBarRoot: View {
	internal let inputs: CommandBarInputs
	internal let loader: BrowserSiteIconLoader

	internal var body: some View {
		CommandBar(
			query: .constant("!"),
			selectedID: Binding(get: { inputs.selectedID }, set: { inputs.selectedID = $0 }),
			results: inputs.results,
			scopeIcon: inputs.scope,
			onSelect: { _ in },
			onDismiss: {}
		)
		.frame(width: 640)
		.environment(\.commandBarIsStatic, true)
		.environment(\.browserSiteIcons, loader)
	}
}

@MainActor
private final class HostedCommandBar {
	internal static let size: CGSize = .init(width: 700, height: 500)

	internal let loader: RecordingSiteIcons
	internal let inputs: CommandBarInputs
	private let window: NSWindow
	private let host: NSHostingView<CommandBarRoot>

	internal init(selectedID: String?) {
		self.loader = .init()
		self.inputs = .init(selectedID: selectedID)
		self.host = NSHostingView(rootView: CommandBarRoot(inputs: inputs, loader: loader.loader))
		host.frame = CGRect(origin: .zero, size: Self.size)

		// Never shown: the window only gives the hosting view somewhere to lay out.
		self.window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		settle()
	}

	/// Lets SwiftUI lay out and run the icons' tasks for a while.
	internal func settle(for duration: Duration = .milliseconds(50)) {
		let end = ContinuousClock.now + duration
		repeat {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.01))
		} while ContinuousClock.now < end
	}

	internal func close() {
		window.close()
	}
}
