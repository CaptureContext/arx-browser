import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Device choosers for WebUSB, WebHID, Web Serial and Web Bluetooth (DEV-905).
@Suite(.dependencies)
@MainActor
internal struct DeviceChooserTests {
	private static let tab = BrowserCore.Tab.ID(rawValue: UUID(3))
	private static let profile = Profile.ID(rawValue: UUID(0))

	private static func chooser(token: UInt64 = 7, options: [String] = ["Board A", "Board B"]) -> BrowserDeviceChooser {
		.init(token: token, title: "flash.example wants to connect to a serial port", options: options.map { .init(name: $0) })
	}

	private static func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: tab]
		return state
	}

	@Test
	internal func aShownTabsRequestOpensASheetAndConnectAnswersIt() async throws {
		let answers = LockIsolated<[(BrowserCore.Tab.ID, UInt64, [Int])]>([])
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.deviceChoosers.answer = { tab, token, _, indices in
				answers.withValue { $0.append((tab, token, indices)) }
				return true
			}
		}
		store.exhaustivity = .off

		await store.send(.deviceChoosers(.changed(.init(tabID: Self.tab, chooser: Self.chooser()))))
		#expect(store.state.deviceChooser?.windowID == store.state.main.id)
		#expect(store.state.deviceChooser?.canConnect == false)

		// The list changes; the sheet keeps its request and drops a vanished choice.
		await store.send(.deviceChooser(.ui(.selectionChanged([1]))))
		await store.send(.deviceChoosers(.changed(.init(tabID: Self.tab, chooser: Self.chooser(options: ["Board A"])))))
		#expect(store.state.deviceChooser?.selection == [])
		await store.send(.deviceChooser(.ui(.selectionChanged([0, 5]))))
		#expect(store.state.deviceChooser?.selection == [0])

		await store.send(.deviceChooser(.ui(.connectButtonTapped)))
		await store.receive(\.deviceChooser.delegate.answered)
		#expect(store.state.deviceChooser == nil)
		#expect(answers.value.map(\.2) == [[0]])
		#expect(answers.value.map(\.1) == [7])
	}

	@Test
	internal func aChoiceFromAListThatChangedIsRefusedAndTheSheetStays() async throws {
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.deviceChoosers.answer = { _, _, _, _ in false }
		}
		store.exhaustivity = .off

		await store.send(.deviceChoosers(.changed(.init(tabID: Self.tab, chooser: Self.chooser()))))
		await store.send(.deviceChooser(.ui(.selectionChanged([1]))))
		await store.send(.deviceChooser(.ui(.connectButtonTapped)))
		#expect(store.state.deviceChooser != nil)
		#expect(store.state.deviceChooser?.selection == [])
	}

	@Test
	internal func cancelAnswersWithNoDeviceAndTheEngineClosingTheRequestClosesTheSheet() async throws {
		let answers = LockIsolated<[[Int]]>([])
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.deviceChoosers.answer = { _, _, _, indices in
				answers.withValue { $0.append(indices) }
				return true
			}
		}
		store.exhaustivity = .off

		await store.send(.deviceChoosers(.changed(.init(tabID: Self.tab, chooser: Self.chooser()))))
		await store.send(.deviceChooser(.ui(.cancelButtonTapped)))
		await store.receive(\.deviceChooser.delegate.answered)
		#expect(answers.value == [[]])

		await store.send(.deviceChoosers(.changed(.init(tabID: Self.tab, chooser: Self.chooser(token: 8)))))
		#expect(store.state.deviceChooser != nil)
		await store.send(.deviceChoosers(.changed(.init(tabID: Self.tab, chooser: nil))))
		#expect(store.state.deviceChooser == nil)
	}

	@Test
	internal func aRequestNobodyCanSeeIsCancelledAtOnce() async throws {
		let answers = LockIsolated<[(BrowserCore.Tab.ID, [Int])]>([])
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.deviceChoosers.answer = { tab, _, _, indices in
				answers.withValue { $0.append((tab, indices)) }
				return true
			}
		}
		store.exhaustivity = .off
		let hidden = BrowserCore.Tab.ID(rawValue: UUID(4))

		await store.send(.deviceChoosers(.changed(.init(tabID: hidden, chooser: Self.chooser()))))
		#expect(store.state.deviceChooser == nil)
		#expect(answers.value.map(\.0) == [hidden])
		#expect(answers.value.map(\.1) == [[]])
	}

	@Test
	internal func siteMenuListsTheSitesDevicesAndForgetsOne() async throws {
		let grants = LockIsolated<[BrowserDeviceGrant]>([
			.init(kind: .serial, origin: "https://flash.example", key: "port-1", name: "Board"),
			.init(kind: .usb, origin: "https://other.example", key: "1:2", name: "Key"),
		])
		var state = SiteMenuFeature.State()
		state.context = .init(url: URL(string: "https://flash.example/tool")!, tabID: Self.tab, profileID: Self.profile)
		let store = TestStore(initialState: state) { SiteMenuFeature() } withDependencies: {
			$0.deviceChoosers.grants = { _ in grants.value }
			$0.deviceChoosers.revoke = { _, grant in
				grants.withValue { $0.removeAll { $0 == grant } }
				return true
			}
		}
		store.exhaustivity = .off

		await store.send(.ui(.open(state.context!)))
		#expect(store.state.devices.map(\.name) == ["Board"])
		#expect(store.state.menu?.devices?.map(\.name) == ["Board"])
		await store.send(.ui(.menu(.forgetDevice(store.state.devices[0].id))))
		#expect(store.state.devices.isEmpty)
		#expect(grants.value.map(\.name) == ["Key"])
	}

	@Test
	internal func siteSettingsListsEveryDeviceAndForgetsOne() async throws {
		let grants = LockIsolated<[BrowserDeviceGrant]>([
			.init(kind: .bluetooth, origin: "https://ble.example", key: "a", name: "Sensor"),
		])
		let store = TestStore(initialState: SiteSettingsFeature.State(profileID: Self.profile, profileName: "Default")) {
			SiteSettingsFeature()
		} withDependencies: {
			$0.deviceChoosers.grants = { _ in grants.value }
			$0.deviceChoosers.revoke = { _, grant in
				grants.withValue { $0.removeAll { $0 == grant } }
				return true
			}
		}
		store.exhaustivity = .off

		await store.send(.ui(.appeared))
		#expect(store.state.devices.map(\.name) == ["Sensor"])
		await store.send(.ui(.forgetDevice(store.state.devices[0].id)))
		#expect(store.state.devices.isEmpty)
	}
}
