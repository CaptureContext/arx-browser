import BrowserCore
import BrowserEngineClient
import ChromiumEngine
import Foundation

extension ChromiumBrowserEngine {
	/// DEV-905. Device choosers for the app's sheet, and the devices sites may use. The engine
	/// hears nothing until someone listens to `events`, and cancels every request meanwhile,
	/// so a headless run never waits for a person.
	public var deviceChoosers: BrowserDeviceChooserClient {
		.init(
			events: { [self] in deviceChooserEvents() },
			answer: { [self] id, token, revision, indices in
				guard let page = chromiumPage(id) else { return false }
				return runtime.answerDeviceChooser(on: page, token: token, revision: revision, indices: indices)
			},
			scanAgain: { [self] id, token in
				guard let page = chromiumPage(id) else { return false }
				return runtime.rescanDeviceChooser(on: page, token: token)
			},
			grants: { [self] profile in
				runtime.deviceGrants(profile: profile.chromiumProfile(legacy: legacyProfileID))?
					.compactMap(Self.grant)
			},
			revoke: { [self] profile, grant in
				runtime.revokeDeviceGrant(
					.init(kind: grant.kind.rawValue, origin: grant.origin, key: grant.key, name: grant.name),
					profile: profile.chromiumProfile(legacy: legacyProfileID)
				)
			}
		)
	}

	private func deviceChooserEvents() -> AsyncStream<BrowserDeviceChooserEvent> {
		let (stream, continuation) = AsyncStream<BrowserDeviceChooserEvent>.makeStream()
		runtime.observeDeviceChoosers { [weak self] page, token, isOpen in
			guard let self, let tabID = self.tabID(ofChromiumPage: page) else {
				// A chooser for a page no tab shows has nobody to answer it.
				if isOpen { self?.runtime.answerDeviceChooser(on: page, token: token, revision: 0, indices: []) }
				return
			}
			let chooser = isOpen ? self.runtime.deviceChooser(on: page).map(Self.chooser) : nil
			continuation.yield(.init(tabID: tabID, chooser: chooser))
		}
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in self?.runtime.observeDeviceChoosers(nil) }
		}
		return stream
	}

	internal static func chooser(_ native: ChromiumDeviceChooser) -> BrowserDeviceChooser {
		.init(
			token: native.token,
			revision: native.revision,
			title: native.title,
			allowsMultiple: native.multiple,
			canScanAgain: native.rescan,
			isScanning: native.scanning,
			adapterIsOff: native.adapterOff,
			options: native.options.map { option in
				.init(
					name: option.name,
					isConnected: option.connected,
					isPaired: option.paired,
					signal: option.signal >= 0 ? option.signal : nil
				)
			}
		)
	}

	internal static func grant(_ native: ChromiumDeviceGrant) -> BrowserDeviceGrant? {
		guard let kind = BrowserDeviceGrant.Kind(rawValue: native.kind) else { return nil }
		return .init(kind: kind, origin: native.origin, key: native.key, name: native.name)
	}
}
