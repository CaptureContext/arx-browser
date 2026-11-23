import BrowserCore
import CommandBarFeature
import CustomDump
import Foundation
import Observation
import Testing
import _ComposableArchitecture

@testable import CommandBarFeature

/// The bar filters a full history once per query, however often one keystroke reads the results
/// (DEV-946).
@Suite(.dependencies)
@MainActor
internal struct CommandBarFilteringTests {
	@Test(arguments: [CommandBarFeature.Mode.newTab, .history])
	internal func aKeystrokeFiltersTheCandidatesOnce(mode: CommandBarFeature.Mode) async throws {
		let store = Store(initialState: CommandBarFeature.State()) { CommandBarFeature() }
		store.send(.present(mode, "", (0 ..< 2_000).map { history($0) }))

		let counts = WorkProbe.Counts()
		WorkProbe.$counts.withValue(counts) {
			store.send(.ui(.queryChanged("PAGE 19")))

			// What the view and the highlighted result's actions read for the same keystroke.
			_ = store.entries
			_ = store.state.selectedEntry
			_ = store.state.primaryActionTitle
		}
		expectNoDifference(counts[.commandBarFilter], 1)

		// The matching page leads the matches, after the typed text's own rows (DEV-978).
		expectNoDifference(Self.firstMatch(store.entries)?.presentation.title, "Page 19")

		WorkProbe.$counts.withValue(counts) {
			// An arrow key moves the highlight without changing the query.
			store.send(.ui(.highlighted(store.entries[1].presentation.id)))
			_ = store.entries
			_ = store.state.selectedEntry
		}
		expectNoDifference(counts[.commandBarFilter], 1)

		WorkProbe.$counts.withValue(counts) {
			store.send(.ui(.queryChanged("PAGE 199")))
			_ = store.entries
		}
		expectNoDifference(counts[.commandBarFilter], 2)
		expectNoDifference(Self.firstMatch(store.entries)?.presentation.title, "Page 199")
	}

	/// The first result that isn't opening or searching for the typed text.
	private static func firstMatch(_ entries: [CommandBarFeature.Entry]) -> CommandBarFeature.Entry? {
		entries.first { !["destination", "search-typed"].contains($0.presentation.id) }
	}

	/// Titles where case folding done ahead of time and `localizedCaseInsensitiveContains` differ.
	private static let titles: [String] = [
		"👩‍💻 notes",
		"👨‍👩‍👧 family photos",
		"Cafe\u{301} menu",
		"Café menu",
		"İstanbul guide",
		"ıslak kum",
		"Straße map",
		"STRASSE map",
		"Résumé tips",
		"ﬁnance (ligature)",
	]

	@Test(arguments: [
		"👩", "👩‍💻", "👨‍👩‍👧", "e", "é", "cafe", "café", "CAFÉ", "i", "İ", "istanbul", "İSTANBUL",
		"ı", "ISLAK", "ß", "ss", "STRASSE", "straße", "resume", "RÉSUMÉ", "fi", "ﬁ",
	])
	internal func matchingIsLocalizedCaseInsensitiveContains(query: String) async throws {
		let candidates = Self.titles.enumerated().map { index, title in
			history(index, title: title, subtitle: "")
		}
		let expected = candidates
			.filter { $0.presentation.title.localizedCaseInsensitiveContains(query) }
			.map(\.presentation.id)

		for mode in [CommandBarFeature.Mode.history, .newTab] {
			let store = Store(initialState: CommandBarFeature.State()) { CommandBarFeature() }
			store.send(.present(mode, "", candidates))
			store.send(.ui(.queryChanged(query)))

			expectNoDifference(
				store.entries.map(\.presentation.id).filter { $0.hasPrefix("history-") },
				expected,
				"\(mode)"
			)
		}
	}

	@Test
	internal func aCachedAnswerStillFollowsTheCandidates() async throws {
		for mode in [CommandBarFeature.Mode.history, .newTab] {
			var state = CommandBarFeature.State(mode: mode, candidates: (0 ..< 10).map { history($0) })
			state.query = "page"

			// Warms the cache, so the observed read below is answered from it.
			_ = state.entries

			let changed = LockIsolated(false)
			withObservationTracking {
				_ = state.entries
			} onChange: {
				changed.setValue(true)
			}
			state.candidates.removeLast()

			#expect(changed.value, "\(mode)")
			expectNoDifference(state.entries.filter { $0.presentation.id.hasPrefix("history-") }.count, 9)
		}
	}

	private func history(
		_ index: Int,
		title: String? = nil,
		subtitle: String? = nil
	) -> CommandBarFeature.Entry {
		let url = URL(string: "https://pages.example/\(index)")!
		return .init(
			presentation: .init(
				id: "history-\(index)",
				title: title ?? "Page \(index)",
				subtitle: subtitle ?? url.absoluteString,
				actionTitle: "Open",
				symbol: "globe"
			),
			intent: .open(url)
		)
	}
}
