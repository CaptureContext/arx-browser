import BrowserEngineClient
import ChromiumEngine
import Testing

@testable import ChromiumBrowserEngine

/// DEV-927: the engine's Cast picker as the app reads it.
@MainActor
internal struct ChromiumCastAdapterTests {
	@Test
	internal func mapsDevicesAndDropsWhatTheAppCantOffer() {
		let picker = ChromiumBrowserEngine.castPicker(.init(
			source: "youtube.com",
			presentation: true,
			permissionRejected: false,
			devices: [
				.init(id: "a", name: "Living Room", state: "connected", icon: "cast", modes: [1, 2, 4], status: "YouTube", route: "r"),
				.init(id: "b", name: "Kitchen", state: "sleeping", icon: "speaker", modes: [8]),
			]
		))

		#expect(picker.source == "youtube.com")
		#expect(picker.isSiteRequest)
		#expect(picker.devices[0].modes == [.presentation, .tab])
		#expect(picker.devices[0].preferredMode == .presentation)
		#expect(picker.devices[0].route == "r")
		#expect(picker.devices[0].canChoose)
		// Unknown states and kinds read as unavailable and generic; no mode, no choice.
		#expect(picker.devices[1].state == .unavailable)
		#expect(picker.devices[1].kind == .generic)
		#expect(picker.devices[1].modes.isEmpty)
		#expect(!picker.devices[1].canChoose)
	}

	@Test
	internal func anIssueCanAlwaysBeCleared() {
		let device = BrowserCastPicker.Device(id: "a", name: "TV", state: .unavailable, modes: [], issue: "Couldn't cast")
		#expect(device.canChoose)
	}
}
