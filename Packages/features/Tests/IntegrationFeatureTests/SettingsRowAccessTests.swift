import BrowserCore
import CustomDump
import Foundation
@testable import SettingsFeature
import Testing

/// DEV-1023: every Settings row says who may change it.
///
/// A new anchor, page or panel doesn't build until `SettingsRowIndex.swift` classifies it: its
/// `access` switches have no default. These tests hold the rest: an agent key no row reaches, or
/// a row whose class doesn't fit what it names, fails.
@MainActor
@Suite(.dependencies)
internal struct SettingsRowAccessTests {
	@Test
	internal func everyAgentPreferenceIsReachedByARow() async throws {
		// With every feature flag on or off: a row a flag replaces still reaches its keys while
		// the flag is off (DEV-1243).
		let reached = Set(SettingsCategory.agentPreferenceKeys(.all)).union(SettingsCategory.agentPreferenceKeys(.init()))
		let unreached = Set(AutomationPreferenceKey.allCases).subtracting(reached)
		#expect(unreached.isEmpty, "No Settings row reaches \(unreached.map(\.rawValue).sorted())")
	}

	@Test
	internal func everyRowsClassFitsWhatItNames() async throws {
		for entry in SettingsCategory.searchIndex {
			let access = entry.access
			switch access.access {
			case .agent:
				// An agent row names what changes it: keys, or a section.
				#expect(access.keys.isEmpty != (access.section == nil), "\(entry.destination.id)")
			case .user, .ui:
				#expect(access.keys.isEmpty && access.section == nil, "\(entry.destination.id)")
			}
			#expect(access.section != .preferences, "\(entry.destination.id) names preferences by key")
		}
	}

	@Test
	internal func theProtectedSettingsStayTheUsers() async throws {
		let index = SettingsCategory.searchIndex
		for destination: SettingsDestination in [
			.row(.developer, .developerMode),
			.row(.advanced, .automation),
			.automation,
			.row(.general, .autofillAuthentication),
			.row(.assistant, .assistantProviders),
			.page(.proxyLinks),
			.page(.appLinks),
			.page(.keptLoadedSites),
			.page(.webKitSites),
			.row(.advanced, .browserData),
		] {
			#expect(destination.access == .user, "\(destination.id)")
		}
		let agentKeys = Set(index.flatMap(\.access.keys).map(\.rawValue))
		#expect(agentKeys.isDisjoint(with: AutomationPreferenceKey.protectedNames))
	}

	@Test
	internal func agentsSeeEveryRowOnceWithItsAccess() async throws {
		let rows = SettingsCategory.automationRows(.all)

		// Every row but the one New tabs open, which `ARX_NEW_TABS_AT_TOP` replaces (DEV-1174).
		expectNoDifference(rows.count, SettingsCategory.searchIndex.filter { $0.isAvailable(.all) }.count)
		expectNoDifference(Set(rows.map(\.id)).count, rows.count)

		let haptics = try #require(rows.first { $0.id == "row/advanced/haptics" })
		expectNoDifference(haptics.access, .agent)
		expectNoDifference(haptics.keys, [.hapticsEnabled])
		let routing = try #require(rows.first { $0.section == .routing })
		expectNoDifference(routing.access, .agent)
		expectNoDifference(routing.keys, nil)
	}

	/// DEV-1141: Dark pages is an agent row of its own key, and a row its feature flag hides
	/// isn't listed, nor are its keys.
	@Test
	internal func aFlaggedRowAndItsKeysHideWithItsFeatureFlag() async throws {
		let darkPages = try #require(SettingsCategory.automationRows(.all).first { $0.id == "row/appearance/darkPages" })
		expectNoDifference(darkPages.access, .agent)
		expectNoDifference(darkPages.keys, [.darkPages])
		expectNoDifference(darkPages.path, SettingsCategory.appearance.title + " › " + String.localized(.appUI.darkPages.setting))

		let off: SettingsFeatureFlags = .init()
		#expect(!SettingsCategory.automationRows(off).contains { $0.id == darkPages.id })
		expectNoDifference(
			Set(SettingsCategory.agentPreferenceKeys(.all)).subtracting(SettingsCategory.agentPreferenceKeys(off)),
			[.darkPages, .matchesSite, .showsLinkStatus, .openedTabPlacement]
		)
		let onlyDarkPages: SettingsFeatureFlags = .init(darkPages: true)
		#expect(SettingsCategory.agentPreferenceKeys(onlyDarkPages).contains(.darkPages))
		#expect(!SettingsCategory.agentPreferenceKeys(onlyDarkPages).contains(.showsLinkStatus))
	}

	/// DEV-1170: Match site's browser default is its own row, an agent's to change, shown with its
	/// feature flag. Profiles and spaces choose theirs through their appearance.
	@Test
	internal func matchSitesBrowserDefaultIsAnAgentRowBehindItsFlag() async throws {
		let matchSite = try #require(SettingsCategory.automationRows(.all).first { $0.id == "row/appearance/matchSite" })
		expectNoDifference(matchSite.access, .agent)
		expectNoDifference(matchSite.keys, [.matchesSite])

		#expect(!SettingsCategory.automationRows(.init(linkStatus: true, darkPages: true)).contains { $0.id == matchSite.id })
		#expect(SettingsCategory.agentPreferenceKeys(.init(matchSite: true)).contains(.matchesSite))
	}
}
