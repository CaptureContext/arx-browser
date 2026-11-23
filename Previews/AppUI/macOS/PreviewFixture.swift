import AppUI
import BrowserCore
import Foundation

internal enum PreviewFixture {
	internal static func id<Entity>(_ value: UInt8) -> BrowserID<Entity> {
		.init(rawValue: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, value)))
	}

	internal static var organization: BrowserOrganization {
		let pages: [(String, String)] = [
			("Gmail", "https://mail.google.com"),
			("Slack", "https://slack.com"),
			("Home", "https://capturecontext.dev"),
			("Figma", "https://figma.com"),
			("Linear", "https://linear.app"),
			("GitHub", "https://github.com"),
			("Readwise", "https://readwise.io"),
			("Raindrop", "https://raindrop.io"),
			("OpenAI API", "https://platform.openai.com"),
			("Claude", "https://claude.ai"),
			("Pull Requests - Review", "https://github.com/pulls/review-requested"),
			("Pull Requests - Mine", "https://github.com/pulls"),
			("Pull Requests", "https://github.com/capturecontext"),
			("PR Flow - How a PR Gets Reviewed and Merged", "https://capturecontext.dev/blog"),
			("Amplitude", "https://amplitude.com"),
			("4 · Free: finished a pack → Study more", "https://capturecontext.dev/study"),
			("Swift documentation", "https://swift.org/documentation"),
		]
		let tabs: [BrowserCore.Tab] = pages.enumerated().map { index, page in
			let url = URL(string: page.1)!
			let savedDestination: BrowserCore.Tab.SavedDestination? = index < 14
			? .init(title: page.0, url: url)
			: nil

			return .init(
				id: id(UInt8(index + 1)),
				profileID: id(1),
				savedDestination: savedDestination,
				restoration: .init(title: page.0, url: url)
			)
		}
		return .init(
			profiles: [
				.init(
					id: id(1),
					name: "Personal",
					favorites: (1 ... 8).map { id(UInt8($0)) }
				),
			],
			spaces: [
				.init(
					id: id(1),
					profileID: id(1),
					name: "Work",
					savedItems: [
						.folder(id(1)),
						.folder(id(2)),
						.folder(id(3)),
						.folder(id(4)),
						.folder(id(5)),
						.folder(id(6)),
						.tab(id(14))
					],
					unpinnedTabs: [id(15), id(16)],
					selectedTabID: id(12)
				),
				.init(
					id: id(2),
					profileID: id(1),
					name: "Personal",
					unpinnedTabs: [id(17)],
					selectedTabID: id(17)
				),
			],
			folders: [
				.init(
					id: id(1),
					spaceID: id(1),
					name: "Other",
					isExpanded: false
				),
				.init(
					id: id(2),
					spaceID: id(1),
					name: "AI",
					children: [.tab(id(9)), .tab(id(10)), .folder(id(7))]
				),
				.init(
					id: id(3),
					spaceID: id(1),
					name: "Automations",
					isExpanded: false
				),
				.init(
					id: id(4),
					spaceID: id(1),
					name: "Analytics",
					isExpanded: false
				),
				.init(
					id: id(5),
					spaceID: id(1),
					name: "Coding",
					isExpanded: false
				),
				.init(
					id: id(6),
					spaceID: id(1),
					name: "My Pull Requests",
					children: [.tab(id(11)), .tab(id(12)), .tab(id(13))]
				),
				.init(
					id: id(7),
					spaceID: id(1),
					name: "Research",
					isExpanded: false
				),
			],
			tabs: tabs
		)
	}

	internal static func icon(for tab: BrowserCore.Tab) -> (String, SidebarTint) {
		let host = tab.restoration.url.host() ?? ""
		if host.contains("google") { return ("envelope.fill", .orange) }
		if host.contains("slack") { return ("number", .pink) }
		if host.contains("figma") { return ("circle.hexagongrid.fill", .pink) }
		if host.contains("github") { return ("chevron.left.forwardslash.chevron.right", .white) }
		if host.contains("openai") { return ("sparkle", .blue) }
		if host.contains("claude") { return ("sun.max.fill", .orange) }
		if host.contains("readwise") { return ("leaf.fill", .yellow) }
		if host.contains("raindrop") { return ("drop.fill", .green) }
		if host.contains("amplitude") || host.contains("example") { return ("waveform.path", .blue) }
		if host.contains("linear") { return ("line.3.horizontal.decrease.circle.fill", .white) }
		return ("house", .lavender)
	}
}
