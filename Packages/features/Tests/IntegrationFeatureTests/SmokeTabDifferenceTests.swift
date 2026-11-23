#if DEBUG
@testable import AppFeature
import BrowserCore
import Foundation
import Testing

/// Engine batch 8's app smoke: after an MCP folder move, the pinned tab counts as unchanged with
/// only its restoration moved, and a failure names the tab's own fields without page text.
@MainActor
internal struct SmokeTabDifferenceTests {
	private let original = BrowserCore.Tab(
		id: .init(rawValue: UUID(1)),
		profileID: .init(rawValue: UUID(2)),
		savedDestination: .init(title: "Arx MCP excluded", url: URL(string: "http://127.0.0.1:48123/mcp-excluded.html")!),
		restoration: .init(title: "Arx MCP excluded", url: URL(string: "http://127.0.0.1:48123/mcp-excluded.html")!),
		automationClientID: UUID(3)
	)

	@Test
	internal func anUnchangedTabIsNone() {
		#expect(SmokeTabDifference.between(original, original) == .none)
		#expect(SmokeTabDifference.between(nil, nil) == .none)
		#expect(SmokeTabDifference.between(original, original).isUnchanged(check: "test"))
	}

	/// The title or address a page reports late is browsing, as moves and Undo treat it.
	@Test
	internal func aRestorationAloneIsSetAside() {
		var current = original
		current.restoration.title = "Arx MCP excluded, later"
		let difference = SmokeTabDifference.between(original, current)
		#expect(difference == .restoration("title"))
		#expect(difference.isUnchanged(check: "test"))
	}

	@Test
	internal func anythingElseIsAChangeNamedDownToTheSavedDestination() {
		var current = original
		current.savedDestination?.iconURL = URL(string: "http://127.0.0.1:48123/favicon.ico")
		current.restoration.title = "Other"
		let difference = SmokeTabDifference.between(original, current)
		#expect(difference == .changed("savedDestination(iconURL),restoration(title)"))
		#expect(!difference.isUnchanged(check: "test"))

		current = original
		current.customTitle = "Renamed"
		current.automationClientID = nil
		#expect(SmokeTabDifference.between(original, current) == .changed("customTitle,automationClientID"))

		current = original
		current.savedDestination = nil
		#expect(SmokeTabDifference.between(original, current) == .changed("savedDestination(presence some->none)"))

		#expect(SmokeTabDifference.between(original, nil) == .changed("tab some->none"))
	}
}
#endif
