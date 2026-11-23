import BrowserCore
import BrowserWorkspaceClient
import Foundation
import _ComposableArchitecture

extension SearchShortcut {
	/// Shortcuts of a person's own, for tests that need some: Arx starts with none since its
	/// bundled bangs cover these sites (DEV-1321).
	internal static let fixtures: [Self] = [
		.init(
			name: "GitHub",
			keyword: "gh",
			template: "https://github.com/search?q={query}",
			homepage: URL(string: "https://github.com")
		),
		.init(
			name: "YouTube",
			keyword: "yt",
			template: "https://www.youtube.com/results?search_query={query}",
			homepage: URL(string: "https://www.youtube.com")
		),
		.init(
			name: "Wikipedia",
			keyword: "w",
			template: "https://en.wikipedia.org/w/index.php?search={query}",
			homepage: URL(string: "https://en.wikipedia.org")
		),
	]
}

extension SearchShortcut {
	/// Gives the test's workspace `fixtures` as the person's own shortcuts, for a test about
	/// them: Arx starts with none (DEV-1321).
	internal static func useFixtures() {
		@Shared(.searchShortcuts)
		var shortcuts

		$shortcuts.withLock { $0 = fixtures }
	}
}
