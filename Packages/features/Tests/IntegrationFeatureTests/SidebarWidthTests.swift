@testable import AppFeature
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct SidebarWidthTests {
	@Test(arguments: [
		(nil, 286),
		(.nan, 286),
		(.infinity, 286),
		(100, 216),
		(300, 300),
		(900, 528),
	] as [(Double?, Double)])
	internal func savedWidthsAreClampedOrFallBackToTheDefault(saved: Double?, expected: Double) {
		expectNoDifference(BrowserSidebarWidth.sanitized(saved), expected)
	}

	@Test
	internal func eachWindowRestoresItsOwnWidth() {
		let organization = IntegrationFeatureTests().fixture()
		let space = organization.spaces[0].id
		let main = MainFeature.State(organization: organization, spaceID: space)
		let other = UUID(901)
		let preferences = BrowserPreferences(
			windowPresentations: [
				.init(id: main.id, activeSpaceID: space, spaces: [], sidebarWidth: 320),
				.init(id: other, activeSpaceID: space, spaces: [], sidebarWidth: 400),
			],
			lastSidebarWidth: 400
		)

		let state = AppFeature.State.launching(main: main, preferences: preferences)

		expectNoDifference(state.main.sidebarWidth, 320)
		expectNoDifference(state.windows[id: other]?.sidebarWidth, 400)
	}

	@Test
	internal func snapshotsWithoutAWidthStartAtTheDefaultAndDecode() throws {
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let saved = BrowserWindowPresentation(id: main.id, activeSpaceID: main.sidebar.spaceID, spaces: [])
		let encoded = try JSONEncoder().encode(BrowserPreferences())
		var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		object.removeValue(forKey: "lastSidebarWidth")

		let legacy = try JSONDecoder().decode(
			BrowserPreferences.self,
			from: JSONSerialization.data(withJSONObject: object)
		)
		let state = AppFeature.State.launching(main: main, preferences: .init(windowPresentations: [saved]))

		expectNoDifference(legacy.lastSidebarWidth, nil)
		expectNoDifference(state.main.sidebarWidth, BrowserSidebarWidth.standard)
	}

	@Test
	internal func resizingSavesThatWindowAndOnlyNewWindowsInherit() async {
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		let store = Store(initialState: AppFeature.State(main: main)) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		await store.send(.ui(.newWindow)).finish()
		let existing = store.windows[0].id

		await store.send(.main(.ui(.sidebarWidthCommitted(340)))).finish()

		expectNoDifference(store.main.sidebarWidth, 340)
		expectNoDifference(store.windows[id: existing]?.sidebarWidth, BrowserSidebarWidth.standard)
		expectNoDifference(store.windowLayout.lastSidebarWidth, 340)
		expectNoDifference(
			store.windowLayout.windowPresentations.first { $0.id == main.id }?.sidebarWidth,
			340
		)

		await store.send(.ui(.newWindow)).finish()
		expectNoDifference(store.windows.last?.sidebarWidth, 340)

		await store.send(.windows(.element(id: existing, action: .ui(.sidebarWidthCommitted(900))))).finish()
		expectNoDifference(store.windows[id: existing]?.sidebarWidth, 528)
		expectNoDifference(store.main.sidebarWidth, 340)
		expectNoDifference(store.windowLayout.lastSidebarWidth, 528)
	}

	@Test
	internal func aPrivateWindowInheritsButIsNeverSaved() async {
		let organization = IntegrationFeatureTests().fixture()
		let main = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		var state = AppFeature.State.launching(main: main, preferences: .init(lastSidebarWidth: 300))
		var window = MainFeature.State(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true,
			id: UUID(902)
		)
		window.sidebarWidth = 300
		state.windows.append(window)
		let store = Store(initialState: state) { AppFeature() } withDependencies: { $0.uuid = .incrementing }

		await store.send(.windows(.element(id: window.id, action: .ui(.sidebarWidthCommitted(420))))).finish()

		expectNoDifference(store.windows[id: window.id]?.sidebarWidth, 420)
		expectNoDifference(store.windowLayout.lastSidebarWidth, 300)
		#expect(!store.windowLayout.windowPresentations.contains { $0.id == window.id })
	}
}
