import AppUI
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

/// Present Media in Picture in Picture (DEV-1106): a tab's video, or a media cell's, in Media PiP,
/// from the tab's menu, the media cells' menus and the command. Media that can't float there is
/// still offered, disabled, with the reason.
extension AppFeature.State {
	/// Whether `source` can float in Media PiP, or why not.
	internal func mediaPictureInPicture(of source: BrowserMediaSource) -> BrowserMediaPictureInPicture {
		if source.isInPictureInPicture {
			return .unavailable(reason: String.localized(.appUI.media.pictureAlreadyOpen))
		}
		if !source.hasVideo {
			return .unavailable(reason: String.localized(.appUI.media.pictureUnavailableAudio))
		}

		// Protected video and sites that set `disablePictureInPicture` don't offer it.
		guard source.supports(.enterPictureInPicture) else {
			return .unavailable(reason: String.localized(.appUI.media.pictureUnavailableSite))
		}

		return .available
	}

	/// What a tab plays, for its menu: `nil` while it plays nothing, which leaves Present Media in
	/// Picture in Picture out.
	internal func mediaPictureInPicture(ofTab tabID: BrowserCore.Tab.ID) -> BrowserMediaPictureInPicture? {
		playingMedia(of: tabID).map(mediaPictureInPicture(of:))
	}

	/// The tab's media that Present Media in Picture in Picture floats, when it can.
	internal func presentableMedia(of tabID: BrowserCore.Tab.ID) -> BrowserMediaSource? {
		playingMedia(of: tabID).flatMap { mediaPictureInPicture(of: $0).isAvailable ? $0 : nil }
	}

	/// The tabs whose video can float now, for the command's availability.
	internal var presentableMediaTabs: Set<BrowserCore.Tab.ID> {
		Set(media.visibleSources.compactMap { source in
			presentableMedia(of: source.id.tabID)?.id.tabID
		})
	}

	/// The tab's media that plays, or that's in Picture in Picture.
	private func playingMedia(of tabID: BrowserCore.Tab.ID) -> BrowserMediaSource? {
		let sources = media.visibleSources.filter { $0.id.tabID == tabID }
		return sources.first { $0.playback == .playing && $0.hasVideo }
		?? sources.first { $0.isInPictureInPicture }
		?? sources.first { $0.playback == .playing }
	}

	/// The tab a command acts on, for Present Media in Picture in Picture.
	internal func mediaPictureInPictureTab(for target: AppFeature.CommandTarget) -> BrowserCore.Tab.ID? {
		switch target {
		case let .peek(id):
			return peeks[id: id]?.tab.id

		case let .window(id, paneID):
			if let little = littleWindows[id: id] { return little.isCommandOnly ? nil : little.viewer.tab?.id }
			guard let window = window(id) else { return nil }

			let pane = paneID ?? window.viewer.activePaneID
			return (window.viewer.panes[id: pane]?.item.tab ?? window.viewer.item.tab)?.id

		default:
			return nil
		}
	}
}

/// Keeps every browser window's `presentableMediaTabs`, and every Little Arx's `canPresentMedia`,
/// current, whichever reducer changed the media, so its command bar offers Present Media in
/// Picture in Picture only for a tab that can. Only a difference reaches a window.
private struct PresentableMediaFollowing<Base: Reducer>: Reducer
where Base.State == AppFeature.State, Base.Action == AppFeature.Action {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal let base: Base

	internal func reduce(
		into state: inout State,
		action: Action
	) -> Effect<Action> {
		let effect = base._reduce(into: &state, action: action)
		let tabs = state.presentableMediaTabs

		// Private windows have no media controls.
		let mainTabs: Set<BrowserCore.Tab.ID> = state.main.isPrivate ? [] : tabs
		if state.main.presentableMediaTabs != mainTabs { state.main.presentableMediaTabs = mainTabs }
		for window in state.windows {
			let windowTabs: Set<BrowserCore.Tab.ID> = window.isPrivate ? [] : tabs
			if window.presentableMediaTabs != windowTabs {
				state.windows[id: window.id]?.presentableMediaTabs = windowTabs
			}
		}
		for little in state.littleWindows {
			let canPresent = little.viewer.tab.map { tabs.contains($0.id) } ?? false
			if little.canPresentMedia != canPresent {
				state.littleWindows[id: little.id]?.canPresentMedia = canPresent
			}
		}
		return effect
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	internal func followingPresentableMedia() -> some Reducer<State, Action> {
		PresentableMediaFollowing(base: self)
	}
}
