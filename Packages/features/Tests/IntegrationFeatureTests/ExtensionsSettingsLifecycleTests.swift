import AppFeature
import BrowserCore
import BrowserExtensionsClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct ExtensionsSettingsLifecycleTests {
	@Test
	internal func settingsHostCloseCancelsInventoryAndRejectsItsLateResult() async throws {
		let organization = IntegrationFeatureTests().fixture()
		let profileID = organization.profiles[0].id
		let inventory = BrowserExtensionInventory(id: UUID(70), profileID: profileID, revision: 1, extensions: [])
		let started = AsyncStream<Void>.makeStream()
		let release = AsyncStream<Void>.makeStream()
		let store = Store(initialState: AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))) {
			AppFeature()
		} withDependencies: {
			$0.browserExtensions = .init(isAvailable: true, inspect: { id in
				expectNoDifference(id, profileID)
				started.continuation.yield(())
				for await _ in release.stream { break }
				return inventory
			})
		}
		await store.send(.ui(.openSettings)).finish()
		expectNoDifference(store.settings.extensions.profile?.id, profileID)
		let task = store.send(.settings(.extensions(.ui(.present))))
		var iterator = started.stream.makeAsyncIterator()
		try #require(await iterator.next() != nil)
		let generation = store.settings.extensions.generation
		await store.send(.ui(.closeSettings)).finish()
		release.continuation.finish()
		await task.finish()
		await store.send(.settings(.extensions(.event(.finished(generation, profileID, .success(inventory)))))).finish()
		#expect(!store.settingsIsOpen && !store.settings.extensions.isPresented && !store.settings.extensions.isWorking)
		#expect(store.settings.extensions.inventory == nil)
	}
}
