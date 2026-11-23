import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import SettingsFeature
import Testing
import WorkspaceDatabase
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1174: while `ARX_NEW_TABS_AT_TOP` is on, Settings › General › New tabs open places a tab
/// from the New Tab button, ⌘T or ⌘K (at the top by default). Off, the one setting
/// places them. Tabs links open follow their opener either way (DEV-1243).
@Suite(.dependencies)
@MainActor
internal struct NewTabsAtTopTests {
	private let url: URL = .init(string: "https://new.example/")!

	// MARK: - The flag

	@Test
	internal func theFlagIsOnUnlessSomethingTurnsItOff() {
		let defaults = UserDefaults(suiteName: "NewTabsAtTopTests")!
		defaults.removePersistentDomain(forName: "NewTabsAtTopTests")
		defer { defaults.removePersistentDomain(forName: "NewTabsAtTopTests") }

		#expect(NewTabsAtTopFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(!NewTabsAtTopFeatureFlag.isOn(environment: [NewTabsAtTopFeatureFlag.name: "0"], defaults: defaults))
		defaults.set("off", forKey: NewTabsAtTopFeatureFlag.name)
		#expect(!NewTabsAtTopFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(FeatureFlag.newTabsAtTop.isOnByDefault)
		#expect(FeatureFlag.newTabsAtTop.needsRelaunch)
	}

	// MARK: - The saved choice

	/// A choice saved before the split goes on placing tabs links open, and the New Tab button,
	/// ⌘T and ⌘K open at the top.
	@Test(arguments: [nil] + NewTabPlacement.allCases.map(\.rawValue) + ["somewhereNew"])
	internal func theChoiceSavedBeforePlacesLinksAndNewTabsOpenAtTheTop(_ saved: String?) throws {
		let data = try JSONEncoder().encode(BrowserPreferences())
		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["newTabPlacement"] = saved
		values["openedTabPlacement"] = nil

		let decoded = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: values)
		)

		expectNoDifference(decoded.newTabPlacement, saved.flatMap(NewTabPlacement.init(rawValue:)) ?? .bottom)
		expectNoDifference(decoded.openedTabPlacement, .top)
	}

	@Test(arguments: NewTabPlacement.allCases)
	internal func bothChoicesRoundTripAndSyncWithTheLinks(_ placement: NewTabPlacement) throws {
		var preferences = BrowserPreferences()
		preferences.openedTabPlacement = placement
		preferences.newTabPlacement = .belowCurrent

		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded.openedTabPlacement, placement)
		expectNoDifference(decoded.newTabPlacement, .belowCurrent)
		#expect(PreferenceDomain.links.keys.contains("openedTabPlacement"))
		#expect(PreferenceDomain.links.keys.contains("newTabPlacement"))
	}

	// MARK: - The three ways

	@Test
	internal func theSidebarsNewTabButtonOpensItsTabAtTheTop() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = makeStore(organization)

		await store.send(.main(.sidebar(.ui(.sidebar(.newTab))))).finish()
		let tabID = try await openTypedAddress(in: store)

		expectNoDifference(store.main.sidebar.space.unpinnedTabs, [tabID] + organization.spaces[0].unpinnedTabs)
		expectNoDifference(store.main.sidebar.space.selectedTabID, tabID)
	}

	@Test
	internal func commandTOpensItsTabAtTheTop() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = makeStore(organization)

		await store.send(.ui(.command(.newTab, .window(store.main.id)))).finish()
		#expect(store.main.commandBar.mode == .newTab)
		let tabID = try await openTypedAddress(in: store)

		expectNoDifference(store.main.sidebar.space.unpinnedTabs, [tabID] + organization.spaces[0].unpinnedTabs)
		expectNoDifference(store.main.sidebar.space.selectedTabID, tabID)
	}

	@Test
	internal func theCommandBarsOpenInNewTabOpensItsTabAtTheTop() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = makeStore(organization)

		await store.send(.ui(.command(.commandBar, .window(store.main.id)))).finish()
		await store.send(.main(.commandBar(.ui(.queryChanged(url.absoluteString))))).finish()
		let context = try #require(store.main.commandBarContext)
		var entry = try #require(store.main.commandBar.entries.first)
		entry.intent = .openInNewTab(url)
		let execution: CommandBarFeature.Execution = .init(
			entry: entry,
			mode: context.mode,
			presentationID: context.presentationID
		)
		await store.send(.main(.commandBar(.delegate(.execute(execution))))).finish()

		let open = store.main.sidebar.space.unpinnedTabs
		expectNoDifference(Array(open.dropFirst()), organization.spaces[0].unpinnedTabs)
		expectNoDifference(store.main.sidebar.organization.tabs[id: open[0]]?.restoration.url, url)
		expectNoDifference(store.main.sidebar.space.selectedTabID, open[0])
	}

	// MARK: - Pinned tabs, tab groups and the flag off

	@Test
	internal func aNewTabGoesAboveTabGroupsWhilePinnedTabsStayAbove() async throws {
		var organization = IntegrationFeatureTests().fixture()
		let open = organization.spaces[0].unpinnedTabs
		let folder = Folder(id: .init(rawValue: UUID(30)), spaceID: organization.spaces[0].id, name: "Folder")
		organization.folders = [folder]
		organization.spaces[0].savedItems = [.folder(folder.id)]
		organization.tabGroups = [.init(
			id: .init(rawValue: UUID(31)),
			spaceID: organization.spaces[0].id,
			name: "Group",
			tabIDs: open
		)]
		let store = makeStore(organization)

		await store.send(.ui(.command(.newTab, .window(store.main.id)))).finish()
		let tabID = try await openTypedAddress(in: store)

		expectNoDifference(store.main.sidebar.space.unpinnedTabs, [tabID] + open)
		expectNoDifference(store.main.sidebar.space.savedItems, [.folder(folder.id)])
		expectNoDifference(store.main.sidebar.organization.tabGroups.map(\.tabIDs), [open])
	}

	/// Off, the one New tabs open row places it from the choice saved before, and the New Tab
	/// button's own choice (at the top) does nothing.
	@Test(arguments: [NewTabPlacement.bottom, .belowCurrent])
	internal func withTheFlagOffTheOneSettingPlacesTheTab(_ placement: NewTabPlacement) async throws {
		let organization = IntegrationFeatureTests().fixture()
		let open = organization.spaces[0].unpinnedTabs
		let store = makeStore(organization, newTabsAtTop: false, opened: .top, links: placement)

		await store.send(.ui(.command(.newTab, .window(store.main.id)))).finish()
		let tabID = try await openTypedAddress(in: store)

		let expected: [BrowserCore.Tab.ID] = switch placement {
		case .belowCurrent: [open[0], tabID, open[1]]
		default: open + [tabID]
		}
		expectNoDifference(store.main.sidebar.space.unpinnedTabs, expected)
	}

	@Test
	internal func theSettingPlacesNewTabsAndLinksFollowTheirOpener() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let open = organization.spaces[0].unpinnedTabs
		let store = makeStore(organization, opened: .belowCurrent, links: .top)

		await store.send(.ui(.command(.newTab, .window(store.main.id)))).finish()
		let tabID = try await openTypedAddress(in: store)
		expectNoDifference(store.main.sidebar.space.unpinnedTabs, [open[0], tabID, open[1]])

		// A link's tab goes right below the tab that opened it, the new one, whatever Tabs from
		// links open said before (DEV-1243).
		let link = URL(string: "https://link.example/")!
		await store.send(.main(.ui(.openInNewTab(link)))).finish()
		let linked = store.main.sidebar.space.unpinnedTabs[2]
		expectNoDifference(store.main.sidebar.organization.tabs[id: linked]?.restoration.url, link)
		expectNoDifference(store.main.sidebar.space.unpinnedTabs, [open[0], tabID, linked, open[1]])
	}

	// MARK: - Settings and agents

	@Test
	internal func settingsShowsOneRowWithTheFlagOrWithout() {
		let on: SettingsFeatureFlags = .init(newTabsAtTop: true)
		let off: SettingsFeatureFlags = .init()
		let rows: (SettingsFeatureFlags) -> [SettingsAnchor] = { flags in
			SettingsCategory.searchIndex.compactMap { entry in
				guard entry.isAvailable(flags), case let .row(.general, anchor) = entry.destination else { return nil }
				return [.newTabPlacement, .openedTabPlacement].contains(anchor) ? anchor : nil
			}
		}

		// Tabs links open follow their opener, with no row of their own (DEV-1243).
		expectNoDifference(rows(on), [.openedTabPlacement])
		expectNoDifference(rows(off), [.newTabPlacement])
		let agentOn = SettingsCategory.agentPreferenceKeys(on)
		let agentOff = SettingsCategory.agentPreferenceKeys(off)
		#expect(agentOn.contains(.openedTabPlacement) && !agentOn.contains(.newTabPlacement))
		#expect(!agentOff.contains(.openedTabPlacement) && agentOff.contains(.newTabPlacement))
	}

	@Test
	internal func eachRowAndAgentKeyChangesItsOwnChoice() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let store = makeStore(organization, document: document)

		await store.send(.settings(.ui(.openedTabPlacement(.belowCurrent)))).finish()
		expectNoDifference(document.preferences.openedTabPlacement, .belowCurrent)
		expectNoDifference(document.preferences.newTabPlacement, .bottom)
		await store.send(.settings(.ui(.newTabPlacement(.top)))).finish()
		expectNoDifference(document.preferences.openedTabPlacement, .belowCurrent)
		expectNoDifference(document.preferences.newTabPlacement, .top)

		let applied = try BrowserPreferences().applying([
			.init(key: .openedTabPlacement, value: .string("bottom")),
			.init(key: .newTabPlacement, value: .string("belowCurrent")),
		])
		expectNoDifference(applied.openedTabPlacement, .bottom)
		expectNoDifference(applied.newTabPlacement, .belowCurrent)
		expectNoDifference(AutomationPreferenceKey.openedTabPlacement.value(in: applied), .string("bottom"))
	}

	// MARK: - Links from pages

	@Test(arguments: [BrowserNewContents.Disposition.foregroundTab, .backgroundTab])
	internal func aTabALinkOpensKeepsItsPlace(_ disposition: BrowserNewContents.Disposition) {
		let organization = IntegrationFeatureTests().fixture()
		let open = organization.spaces[0].unpinnedTabs
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		#expect(state.main.newTabsAtTop)
		state.main.viewer.item.tab = organization.tabs[0]
		let offer = BrowserNewContents(
			sourceTabID: organization.tabs[0].id,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: .init(rawValue: UUID(90)),
				profileID: organization.tabs[0].profileID,
				restoration: .init(title: "Link", url: URL(string: "https://link.example/")!)
			),
			disposition: disposition
		)
		withDependencies {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				if id == offer.sourceTabID {
					return .init(navigation: .init(), revision: 3, documentRevision: 7)
				}
				return id == offer.tab.id ? .init(navigation: .init(), revision: 1) : nil
			}
		} operation: {
			_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.browserNewContents(offer)))
		}

		// Right below the tab that opened it, in front or behind (DEV-1243), not where New tabs
		// open says (at the top).
		expectNoDifference(state.workspace.spaces[0].unpinnedTabs, [open[0], offer.tab.id, open[1]])
	}

	/// Right below the current tab, as a tab it opened (DEV-1243), whatever either setting says.
	@Test
	internal func openInNewTabFromAPageGoesWhereLinksDo() async {
		let organization = IntegrationFeatureTests().fixture()
		let before = organization.spaces[0].unpinnedTabs
		let store = makeStore(organization, opened: .bottom, links: .top)

		await store.send(.main(.ui(.openInNewTab(url)))).finish()

		let open = store.main.sidebar.space.unpinnedTabs
		expectNoDifference([open[0], open[2]], before)
		expectNoDifference(store.main.sidebar.organization.tabs[id: open[1]]?.restoration.url, url)
	}

	// MARK: - Undo and sync

	@Test
	internal func oneUndoClosesTheNewTab() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = makeStore(organization)

		await store.send(.ui(.command(.newTab, .window(store.main.id)))).finish()
		let tabID = try await openTypedAddress(in: store)
		#expect(store.main.sidebar.space.unpinnedTabs.first == tabID)

		await store.send(.main(.sidebar(.ui(.undo)))).finish()

		expectNoDifference(store.main.sidebar.space.unpinnedTabs, organization.spaces[0].unpinnedTabs)
		#expect(store.main.sidebar.organization.tabs[id: tabID] == nil)
	}

	@Test
	internal func syncKeepsTheOtherTabsRowsAndPutsTheNewOneFirst() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let store = makeStore(organization)
		let before = try OrganizationRows(organization)

		await store.send(.ui(.command(.newTab, .window(store.main.id)))).finish()
		let tabID = try await openTypedAddress(in: store)
		let after = try OrganizationRows(store.main.sidebar.organization, previous: before)

		// Only the new tab's row is new; every other tab keeps its key, so sync sends one row.
		for id in organization.spaces[0].unpinnedTabs {
			expectNoDifference(after.regularTabs[id.rawValue]?.position, before.regularTabs[id.rawValue]?.position)
		}
		let first = try #require(after.regularTabs[tabID.rawValue]?.position)
		let others = organization.spaces[0].unpinnedTabs.compactMap { after.regularTabs[$0.rawValue]?.position }
		#expect(others.allSatisfy { first < $0 })
		expectNoDifference(try after.organization().spaces[0].unpinnedTabs.first, tabID)
	}

	// MARK: - Helpers

	/// AppFeature with the main window on the space's first tab, the flag as `newTabsAtTop` says,
	/// New tabs open at `opened` and the choice saved before DEV-1174 at `links`.
	private func makeStore(
		_ organization: BrowserOrganization,
		newTabsAtTop: Bool = true,
		opened: NewTabPlacement = .top,
		links: NewTabPlacement = .bottom,
		document: WorkspaceDocument = .unsaved()
	) -> StoreOf<AppFeature> {
		document.updatePreferences(requestsSave: false) { preferences in
			preferences.openedTabPlacement = opened
			preferences.newTabPlacement = links
		}
		return withDependencies {
			$0.workspaceDocument = document
		} operation: {
			var main = MainFeature.State(
				organization: organization,
				spaceID: organization.spaces[0].id,
				newTabsAtTop: newTabsAtTop
			)
			main.viewer.item.tab = organization.tabs[0]
			var state = AppFeature.State(main: main)
			state.settings.newTabsAtTopAvailable = newTabsAtTop
			return Store(initialState: state) { AppFeature() } withDependencies: {
				$0.workspaceDocument = document
				$0.uuid = .incrementing
				$0.browserEngine.open = { _ in }
				$0.browserEngine.events = { _ in .finished }
			}
		}
	}

	/// Types `url` into the open command bar and opens it, as Return does; the new tab's ID.
	private func openTypedAddress(in store: StoreOf<AppFeature>) async throws -> BrowserCore.Tab.ID {
		let before = Set(store.main.sidebar.organization.tabs.ids)
		await store.send(.main(.commandBar(.ui(.queryChanged(url.absoluteString))))).finish()
		await store.send(.main(.commandBar(.ui(.selected("destination"))))).finish()
		let added = store.main.sidebar.organization.tabs.ids.filter { !before.contains($0) }
		#expect(added.count == 1)
		return try #require(added.first)
	}
}
