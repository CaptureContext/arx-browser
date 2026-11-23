#if DEBUG
import BrowserCore
import BrowserMediaClient
import ChromiumBrowserEngine
import ChromiumEngine
import Foundation
import _ComposableArchitecture

/// DEV-800 review: Mute Tab from a tab row must silence the page, not only flip the row's speaker.
///
/// MediaSmoke drives the native media client directly, so it kept passing while the app's own
/// path dropped every mute: `BrowserCapabilities.media` didn't forward the tab-level calls. This
/// check takes MediaSmoke's playing fixture page and sends the sidebar's Mute Tab through the
/// app's composition, as a browser window builds it: an `AppFeature` store owning the tab, with
/// `BrowserCapabilities` over the same engine. It then reads the result back from the engine,
/// not from the store: the page's WebContents is audio-muted, which is what engages the audio
/// service's muter for every stream of the tab, and the page keeps playing, so it's silenced
/// rather than paused. Chromium reports no "silent" level for a muted tab (its audible state is
/// measured before the muter), so the engine's mute state is the closest observable proof.
@MainActor
internal enum AppTabMuteSmoke {
	internal enum Failure: Error {
		case alreadyMuted
		case notSilenced
		case stoppedPlaying
		case notRestored
	}

	internal static func run(
		engine: ChromiumBrowserEngine,
		runtime: ChromiumRuntime,
		tab: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		url: URL,
		native: BrowserMediaClient,
		isPlaying: @escaping @MainActor () -> Bool
	) async throws {
		let profile = Profile(id: profileID, name: "Media fixture")
		let space = Space(
			id: .init(rawValue: UUID()),
			profileID: profileID,
			name: "Media fixture",
			unpinnedTabs: [tab],
			selectedTabID: tab
		)
		let organization = BrowserOrganization(
			profiles: [profile],
			spaces: [space],
			tabs: [.init(id: tab, profileID: profileID, restoration: .init(title: "Media fixture", url: url))]
		)

		let capabilities = BrowserCapabilities(
			isRunning: { runtime.state == .running },
			capture: .init(),
			media: { try engine.media() },
			extensions: { _ in .init() }
		)
		defer { capabilities.stop() }

		var state = AppFeature.State(main: .init(organization: organization, spaceID: space.id))
		state.media.isAvailable = true
		state.main.mediaAvailable = true
		let store = Store(initialState: state) {
			AppFeature()
		} withDependencies: {
			$0.browserMedia = capabilities.media

			// The fixture page is MediaSmoke's: this store never opens or closes engine pages.
			$0.browserEngine.open = { _ in }
			$0.browserEngine.events = { _ in .finished }
		}
		capabilities.store = store
		capabilities.activate()

		guard native.position(tab)?.isMuted == false
		else { throw Failure.alreadyMuted }

		// The tab row's Mute Tab, as the sidebar sends it.
		store.send(.main(.sidebar(.ui(.sidebar(.setMuted(.tab(tab.rawValue), true))))))
		try await wait(or: Failure.notSilenced) {
			native.position(tab)?.isMuted == true && store.mutedTabs.contains(tab)
		}
		guard isPlaying() else { throw Failure.stoppedPlaying }

		store.send(.main(.sidebar(.ui(.sidebar(.setMuted(.tab(tab.rawValue), false))))))
		try await wait(or: Failure.notRestored) {
			native.position(tab)?.isMuted == false && !store.mutedTabs.contains(tab)
		}
		guard isPlaying() else { throw Failure.stoppedPlaying }

		print("ARX_MEDIA_APP_TAB_MUTE_SUCCESS")
	}

	private static func wait(
		or failure: Failure,
		_ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while ContinuousClock.now < deadline {
			try Task.checkCancellation()
			if condition() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		throw failure
	}
}
#endif
