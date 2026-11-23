@testable import AppUI
import BrowserCore
import Foundation
@testable import SettingsFeature
import Testing
import _ComposableArchitecture

/// The homepage's tips (DEV-1263) that name a Settings row: the row is still in Settings, and the
/// pane a tip sends the person to is the pane it's in. AppUI can't see Settings, so this lives here.
@MainActor
@Suite(.dependencies)
internal struct EmptyPageHintSettingsTests {
	@Test
	internal func everySettingATipNamesIsInSettings() async throws {
		let listed: Set<String> = Set(SettingsCategory.searchIndex.map(\.destination.id))
		let hidden: Set<SettingsAnchor> = SettingsAnchor.hiddenByFeatureFlags
		for hint in EmptyPageHints.all {
			for case let .setting(id) in hint.needs {
				let destination = try #require(SettingsDestination(id: id), "\(hint.key) names \(id)")
				#expect(listed.contains(id), "\(hint.key) names \(id), which Settings doesn't list")
				if let anchor = destination.anchor {
					#expect(!hidden.contains(anchor), "\(hint.key) names \(id), which a feature flag hides")
				}
				if hint.template.contains("Settings ›") {
					let pane: String = "Settings › " + destination.category.title
					#expect(hint.template.contains(pane), "\(hint.key) should say \(pane)")
				}
			}
		}
	}
}
