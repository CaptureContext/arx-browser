#if DEBUG
@testable import AppFeature
import BrowserCore
import Foundation
import Testing

/// Engine batch 7's app smoke: a page counts as unchanged with only its reported colors changed,
/// after Capture Page beyond the viewport its revision aside too, and a failure names the
/// navigation's own fields. The MCP smokes' inventory lookups say why an item was missing.
@MainActor
internal struct SmokeSnapshotDifferenceTests {
	private let original = BrowserSessionSnapshot(
		navigation: .init(
			url: URL(string: "http://127.0.0.1:48123/capture/document.html"),
			title: "0,0,1200,800,2",
			history: [.init(id: 1, url: URL(string: "http://127.0.0.1:48123/capture/document.html")!, title: "", isCurrent: true)]
		),
		revision: 24,
		documentRevision: 3
	)

	@Test
	internal func aMovedRevisionIsNoChangeOnlyAfterAResize() {
		var current = original
		current.revision = 27
		#expect(SmokeSnapshotDifference.between(original, current, ignoringRevision: true) == .none)
		// A folder move keeps the page's session, revision included.
		#expect(SmokeSnapshotDifference.between(original, current) == .changed("revision 24->27"))
	}

	/// Chromium reports the frames' colors again after the capture's resize; that alone passes.
	@Test
	internal func reportedColorsAloneAreColors() {
		var current = original
		current.revision = 26
		current.navigation.colors = .init(themeARGB: nil, backgroundARGB: 0xFF11_2233)
		guard case let .colors(fields) = SmokeSnapshotDifference.between(original, current, ignoringRevision: true) else {
			Issue.record("expected only colors to differ")
			return
		}

		// A color isn't page text, but a value appearing from nil is named, not printed.
		#expect(fields == "background")
		#expect(SmokeSnapshotDifference.colors(fields).isUnchanged(check: "test"))
		#expect(!SmokeSnapshotDifference.changed("navigation(title)").isUnchanged(check: "test"))
	}

	@Test
	internal func anythingElseIsAChangeNamedDownToTheNavigation() {
		var current = original
		current.navigation.colors = .init(themeARGB: nil, backgroundARGB: 0xFF11_2233)
		current.navigation.title = "0,0,1200,6000,2"
		#expect(SmokeSnapshotDifference.between(original, current) == .changed("navigation(title,colors)"))

		current = original
		current.documentRevision = 4
		current.navigation.isLoading = true
		#expect(SmokeSnapshotDifference.between(original, current)
			== .changed("navigation(isLoading false->true),documentRevision Optional(3)->Optional(4)"))

		#expect(SmokeSnapshotDifference.between(original, nil) == .changed("snapshot some->none"))
		#expect(SmokeSnapshotDifference.between(nil, original) == .changed("snapshot none->some"))
		#expect(SmokeSnapshotDifference.between(nil, nil) == .none)
	}

	@Test
	internal func snapshotChangesLeaveOtherFieldsAsBefore() {
		var current = original
		current.isVisibleForCapture.toggle()
		#expect(SmokeDiagnostics.snapshotChanges(from: original, to: current)
			== SmokeDiagnostics.changes(from: original, to: current))
	}

	@Test
	internal func inventoryLookUpSaysWhyAnItemIsMissing() {
		let id = UUID()
		let item = AutomationInventoryItem(
			id: id,
			kind: .tab,
			title: "Fixture",
			profileID: UUID(),
			url: "http://127.0.0.1:48123/mcp-excluded.html",
			sessionState: .ready,
			revision: String(repeating: "a", count: 64)
		)
		#expect(AutomationHostSmoke.lookUp(id, in: .inventory(.init(items: [item]))) == .success(item))
		#expect(AutomationHostSmoke.lookUp(UUID(), in: .inventory(.init(items: [item])))
			== .failure(.missing(kinds: ["tab": 1])))
		#expect(AutomationHostSmoke.lookUp(id, in: .inventory(.init(items: [item], nextCursor: "next")))
			== .failure(.paged(items: 1)))
		#expect(AutomationHostSmoke.lookUp(id, in: .failure(.denied)) == .failure(.failed("denied")))

		#expect(AutomationHostSmoke.InventoryMiss.missing(kinds: ["tab": 2, "space": 3]).description
			== "missing items=space:3,tab:2")
	}
}
#endif
