import AppUI
import BrowserCore
import BrowserMediaClient
import CommandBarFeature
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// DEV-1106: a tab's video, or a media cell's, is presented in Media PiP from its menu and from
/// the Present Media in Picture in Picture command; media that can't float there says why.
@Suite(.dependencies)
@MainActor
internal struct MediaPictureInPictureTests {
	@Test
	internal func aPlayingVideoCanBePresentedAndASilentTabCant() async throws {
		var state = fixture()
		let playing = state.workspace.tabs[0].id
		let silent = state.workspace.tabs[1].id
		state.media.snapshot = .init(revision: 1, sources: [source(playing)])

		#expect(state.mediaPictureInPicture(ofTab: playing) == .available)
		#expect(state.presentableMedia(of: playing)?.id.tabID == playing)
		#expect(state.mediaPictureInPicture(ofTab: silent) == nil)
		#expect(state.presentableMediaTabs == [playing])
	}

	@Test
	internal func mediaThatCantFloatSaysWhy() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id

		// A site that turns Picture in Picture off, or protected video, offers no entry.
		var protected = source(tab)
		protected.actions.remove(.enterPictureInPicture)
		state.media.snapshot = .init(revision: 1, sources: [protected])
		#expect(state.mediaPictureInPicture(ofTab: tab) == .unavailable(
			reason: String.localized(.appUI.media.pictureUnavailableSite)
		))
		#expect(state.presentableMedia(of: tab) == nil)

		// Audio has nothing to show.
		var audio = source(tab)
		audio.hasVideo = false
		state.media.snapshot = .init(revision: 2, sources: [audio])
		#expect(state.mediaPictureInPicture(ofTab: tab) == .unavailable(
			reason: String.localized(.appUI.media.pictureUnavailableAudio)
		))

		// Already floating.
		var floating = source(tab)
		floating.isInPictureInPicture = true
		state.media.snapshot = .init(revision: 3, sources: [floating])
		#expect(state.mediaPictureInPicture(ofTab: tab) == .unavailable(
			reason: String.localized(.appUI.media.pictureAlreadyOpen)
		))
		#expect(state.presentableMediaTabs.isEmpty)
	}

	@Test
	internal func aTabsMenuOffersMediaOnlyWhileItPlays() async throws {
		let playing = BrowserPictureInPictureMenu.items(media: .available, canPresentTab: true)
		expectNoDifference(playing.map(\.kind), [.media, .tab])
		expectNoDifference(playing.map(\.title), [
			BrowserCommand.mediaPictureInPicture.title,
			BrowserCommand.pagePictureInPicture.title,
		])
		let allEnabled = playing.allSatisfy(\.isEnabled)
		#expect(allEnabled)

		let silent = BrowserPictureInPictureMenu.items(media: nil, canPresentTab: true)
		expectNoDifference(silent.map(\.kind), [.tab])

		// Media that can't float is disabled with the reason; the whole tab still can.
		let reason = String.localized(.appUI.media.pictureUnavailableSite)
		let protected = BrowserPictureInPictureMenu.items(media: .unavailable(reason: reason), canPresentTab: true)
		expectNoDifference(protected.map(\.isEnabled), [false, true])
		expectNoDifference(protected.first?.help, reason)
	}

	@Test
	internal func theCommandPresentsTheTabsVideo() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		let video = source(tab)
		state.media.snapshot = .init(revision: 1, sources: [video])
		let requests = LockIsolated<[BrowserMediaRequest]>([])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
			$0.browserMedia.availability = { true }
			$0.browserMedia.perform = { request in requests.withValue { $0.append(request) } }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// Any action brings the windows up to date with the media, as its events do in the app.
		await store.send(.event(.pagePictureInPictureNavigation(tab, .init())))

		// The window learned the tab can present, so its command bar and menu bar offer it.
		expectNoDifference(store.state.main.presentableMediaTabs, [tab])

		await store.send(.ui(.command(.mediaPictureInPicture, .window(state.main.id))))
		await store.receive(\.media.ui.perform)
		await store.skipReceivedActions(strict: false)
		expectNoDifference(requests.value, [.init(source: video, action: .enterPictureInPicture)])
		#expect(store.state.main.commandContext.canPresentMedia)
		#expect(BrowserCommand.mediaPictureInPicture.isEnabled(in: store.state.main.commandContext))
		let listed = CommandBarFeature.Entry.commands(in: store.state.main.commandContext, bindings: [])
			.compactMap { entry -> BrowserCommand? in
				guard case let .command(command) = entry.intent else { return nil }

				return command
			}
		#expect(listed.contains(.mediaPictureInPicture))
		await store.finish()
	}

	@Test
	internal func aTabWithoutPresentableMediaHasNoCommand() async throws {
		var state = fixture()
		let tab = state.workspace.tabs[0].id
		var protected = source(tab)
		protected.actions.remove(.enterPictureInPicture)
		state.media.snapshot = .init(revision: 1, sources: [protected])
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.date.now = Date(timeIntervalSince1970: 1_000)
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.command(.mediaPictureInPicture, .window(state.main.id))))
		#expect(store.state.main.presentableMediaTabs.isEmpty)
		#expect(!BrowserCommand.mediaPictureInPicture.isEnabled(in: store.state.main.commandContext))
		await store.finish()
	}

	// MARK: - Fixture

	private func fixture() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		state.media.isAvailable = true
		state.media.includesAllOrdinaryProfiles = true
		return state
	}

	private func source(_ tabID: BrowserCore.Tab.ID) -> BrowserMediaSource {
		let organization = IntegrationFeatureTests().fixture()
		let profileID = organization.tabs[id: tabID]?.profileID ?? organization.profiles[0].id
		return .init(
			id: .init(tabID: tabID, profileID: profileID, generation: 1),
			revision: 1,
			title: "Video",
			site: nil,
			hasVideo: true,
			playback: .playing,
			actions: [.play, .pause, .enterPictureInPicture, .exitPictureInPicture]
		)
	}
}
