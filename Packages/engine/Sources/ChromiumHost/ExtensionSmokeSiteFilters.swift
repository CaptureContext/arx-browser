import ChromiumEngine
import Foundation

/// uBlock Origin's site-specific hiding (`host##selector`) and scriptlets (`host##+js(…)`) reach
/// an ordinary page (DEV-1019). uBlock puts both into a page with `tabs.insertCSS` and
/// `tabs.executeScript`, as its element picker, so they apply only on an engine whose tabs API
/// takes Arx's pages for those. The smoke adds one filter of each to My filters for the fixture
/// page's site, then reloads the page until both apply.
@MainActor
internal enum ExtensionSmokeSiteFilters {
	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		url: URL,
		phase: (String) -> Void,
		diagnostic: (String) -> Void
	) async throws {
		phase("site-filters")
		guard
			let host = url.host(),
			runtime.supportsDeveloperTier
		else { throw Failure.unsupported }

		let filters = [
			"\(host)##.arx-hide-target",
			"\(host)##+js(remove-class, arx-scriptlet-probe, #arx-scriptlet)",
		]
		guard runtime.addFixtureFiltersForTesting(filters, on: page)
		else { throw Failure.refused }

		let fixture = url.deletingLastPathComponent().appending(path: "blocking.html")
		var last = Applied()

		// uBlock reloads its filters after saving them; a page loaded before that has neither.
		for _ in 0..<attempts {
			try page.navigate(to: fixture)
			try await waitForLoad(page, path: fixture.path())

			for _ in 0..<pollsPerLoad {
				last = try await applied(runtime: runtime, page: page)
				if last.hidden && last.scriptlet {
					diagnostic("ARX_EXTENSION_SMOKE_SITE_HIDING")
					diagnostic("ARX_EXTENSION_SMOKE_SCRIPTLET")
					return
				}
				try await Task.sleep(for: .milliseconds(100))
			}
		}

		throw Failure.notApplied(hidden: last.hidden, scriptlet: last.scriptlet)
	}

	private struct Applied: Decodable {
		var hidden: Bool = false
		var scriptlet: Bool = false
	}

	/// Whether the hiding filter hid its element and the scriptlet took its class away.
	private static func applied(
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws -> Applied {
		let value = try await runtime.evaluateScript(
			page,
			source: """
			const hidden = document.getElementById('arx-hidden');
			const probe = document.getElementById('arx-scriptlet');
			return {
				hidden: hidden !== null && getComputedStyle(hidden).display === 'none',
				scriptlet: probe !== null && !probe.classList.contains('arx-scriptlet-probe'),
			};
			""",
			maximumBytes: 1024,
			timeoutMilliseconds: 2000
		)
		guard
			case let .json(text) = value,
			let applied = try? JSONDecoder().decode(Applied.self, from: Data(text.utf8))
		else { return .init() }

		return applied
	}

	private static func waitForLoad(
		_ page: ChromiumPage,
		path: String
	) async throws {
		for _ in 0..<100 {
			try Task.checkCancellation()
			if page.navigation.url?.path() == path, !page.navigation.isLoading { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.navigation
	}

	private static let attempts: Int = 6
	private static let pollsPerLoad: Int = 20

	private enum Failure: Error, CustomStringConvertible {
		case unsupported
		case refused
		case navigation
		case notApplied(hidden: Bool, scriptlet: Bool)

		var description: String {
			switch self {
			case .unsupported: "site filters: unsupported by this engine"
			case .refused: "site filters: the engine refused the fixture's filters"
			case .navigation: "site filters: the fixture page didn't load"
			case let .notApplied(hidden, scriptlet): "site filters: hidingApplied=\(hidden) scriptletApplied=\(scriptlet)"
			}
		}
	}
}
