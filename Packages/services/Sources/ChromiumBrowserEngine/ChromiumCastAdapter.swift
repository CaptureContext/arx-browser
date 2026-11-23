import BrowserCore
import BrowserEngineClient
import ChromiumEngine
import Foundation

extension ChromiumBrowserEngine {
	/// DEV-927. Cast pickers for the app's sheet. The engine opens none until someone listens to
	/// `events`, and a site's Cast button fails at once meanwhile, so a headless run never waits.
	public var cast: BrowserCastClient {
		.init(
			isAvailable: { [self] in runtime.supportsCasting },
			events: { [self] menuTitle in castPickerEvents(menuTitle: menuTitle) },
			show: { [self] id in
				guard let page = chromiumPage(id) else { return false }
				return runtime.showCastPicker(on: page)
			},
			choose: { [self] id, device, mode in
				guard let page = chromiumPage(id) else { return false }
				return runtime.chooseCastDevice(device, mode: mode?.rawValue, on: page)
			},
			stop: { [self] id, route in
				guard let page = chromiumPage(id) else { return false }
				return runtime.stopCasting(route: route, on: page)
			},
			close: { [self] id in
				guard let page = chromiumPage(id) else { return }
				runtime.closeCastPicker(on: page)
			}
		)
	}

	private func castPickerEvents(menuTitle: String) -> AsyncStream<BrowserCastPickerEvent> {
		let (stream, continuation) = AsyncStream<BrowserCastPickerEvent>.makeStream()
		runtime.observeCastPickers(menuTitle: menuTitle) { [weak self] page, picker in
			guard let self, let tabID = self.tabID(ofChromiumPage: page) else {
				// A picker for a page no tab shows has nobody to answer it.
				if picker != nil { self?.runtime.closeCastPicker(on: page) }
				return
			}
			continuation.yield(.init(tabID: tabID, picker: picker.map(Self.castPicker)))
		}
		castPickerContinuation = continuation
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.runtime.observeCastPickers(menuTitle: "", nil) }
		}
		return stream
	}

	internal static func castPicker(_ native: ChromiumCastPicker) -> BrowserCastPicker {
		.init(
			source: native.source,
			isSiteRequest: native.presentation,
			isLocalNetworkDenied: native.permissionRejected,
			devices: native.devices.map { device in
				.init(
					id: device.id,
					name: device.name,
					state: .init(rawValue: device.state) ?? .unavailable,
					kind: .init(rawValue: device.icon) ?? .generic,
					modes: device.modes.compactMap(BrowserCastPicker.Device.Mode.init(rawValue:)),
					status: device.status,
					issue: device.issue,
					route: device.route
				)
			}
		)
	}
}
