import BrowserCore
import BrowserExtensionsClient
import BrowserWorkspaceClient
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-884: Settings › General › Content blocking.
@Suite(.dependencies)
@MainActor
internal struct ContentBlockingSettingTests {
	@Test
	internal func theSwitchesSaveAndTellTheEngine() async {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.settings.contentBlockingAvailable = true
		let calls = LockIsolated<[[Bool]]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserExtensions = BrowserExtensionsClient(
				setContentBlocking: { isOn, cookieBanners in calls.withValue { $0.append([isOn, cookieBanners]) } }
			)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.blocksCookieBanners(true))))
		#expect(document.preferences.blocksCookieBanners)
		await store.send(.settings(.ui(.blocksContent(false))))
		#expect(!store.state.settings.general.blocksContent)
		#expect(!document.preferences.blocksContent)
		await store.send(.settings(.ui(.blocksContent(true))))

		expectNoDifference(calls.value, [[true, true], [false, true], [true, true]])
	}

	@Test
	internal func anEngineWithoutContentBlockingGetsNothing() async {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		let state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		let calls = LockIsolated(0)
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.browserExtensions = BrowserExtensionsClient(setContentBlocking: { _, _ in calls.withValue { $0 += 1 } })
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.blocksContent(false))))
		#expect(calls.value == 0)
		#expect(store.state.settings.general.blocksContent)
	}

	@Test
	internal func theDashboardOpensAsUBlocksOptionsInTheFrontWindowsProfile() async {
		let organization = IntegrationFeatureTests().fixture()
		let document = WorkspaceDocument.unsaved()
		var state = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
		state.settings.contentBlockingAvailable = true
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.workspaceDocument = document
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.openContentBlockingDashboard)))
		await store.receive(\.settings.delegate.openContentBlockingDashboard)
		await store.receive(\.ui.openExtensionOptions)
	}
}
