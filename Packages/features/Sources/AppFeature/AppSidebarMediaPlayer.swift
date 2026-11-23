import AgentClient
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserMediaClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChatFeature
import MainFeature
import DownloadsFeature
import SwiftUI
import ViewerItemFeature
import _ComposableArchitecture

/// The sidebar's media stack (DEV-906, DEV-1245): every tab of the window's current space that
/// plays or has paused media, the one on screen included, so the person can move between them
/// whichever tab is selected. At rest it shows one item, the last opened that plays; hovering
/// expands it into all of them, in the order their media was opened. Each shows the
/// artwork, artist and next or previous track when the page's Media Session has them, and goes when
/// its media ends or its tab closes. Read here, apart from the window, so playback renders only
/// this view.
internal struct AppSidebarMediaPlayer: View {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID
	internal let position: @MainActor @Sendable (BrowserCore.Tab.ID) -> BrowserMediaPosition?

	internal var body: some View {
		let sources = self.sources
		if let resting = restingSource(in: sources) {
			SidebarMediaStack(ids: sources.map(\.id), restingID: resting.id) { id in
				if let source = sources.first(where: { $0.id == id }) {
					player(source)
				}
			}
			.transition(.opacity.combined(with: .move(edge: .bottom)))
		}
	}

	private func player(_ source: BrowserMediaSource) -> some View {
		// A muted page that left its session has nothing to control, only a tab to return to.
		let isLive = store.media.visibleSources.contains { $0.id == source.id }
		return SidebarMediaPlayer(
			item: playerItem(source, isLive: isLive),
			canSeek: isLive && source.supports(.seek),
			progress: { [position] in
				guard
					isLive,
					let read = position(source.id.tabID),
					let seconds = read.position,
					let duration = read.duration
				else { return nil }

				return .init(position: seconds, duration: duration)
			},
			onPlayPause: {
				store.send(.media(.ui(.perform(source.id, source.playback == .playing ? .pause : .play))))
			},
			onPreviousTrack: { store.send(.media(.ui(.perform(source.id, .previousTrack)))) },
			onNextTrack: { store.send(.media(.ui(.perform(source.id, .nextTrack)))) },
			onSeek: { store.send(.media(.ui(.seek(source.id, to: $0)))) },
			onOpen: { open(source, isLive: isLive) },
			onCast: store.castIsAvailable && isLive
			? { store.send(.cast(.open(source.id.tabID, windowID: windowID))) }
			: nil
		) {
			// Present in Picture in Picture and the player's own actions (DEV-1106).
			SidebarMediaMenu(
				item: playerItem(source, isLive: isLive),
				pictureInPicture: isLive ? store.state.mediaPictureInPicture(of: source) : nil,
				onPresent: { store.send(.media(.ui(.perform(source.id, .enterPictureInPicture)))) },
				onExitPictureInPicture: isLive && source.isInPictureInPicture && source.supports(.exitPictureInPicture)
				? { store.send(.media(.ui(.perform(source.id, .exitPictureInPicture)))) }
				: nil,
				onPlayPause: { pauses in store.send(.media(.ui(.perform(source.id, pauses ? .pause : .play)))) },
				onMute: { store.send(.ui(.toggleMediaMute(source.id.tabID))) },
				onReturn: { open(source, isLive: isLive) }
			)
		}
	}

	/// Choosing an item goes to its tab.
	private func open(_ source: BrowserMediaSource, isLive: Bool) {
		if isLive {
			store.send(.media(.ui(.returnToTab(source.id))))
		} else {
			store.send(.ui(.returnToMutedMedia(source.id.tabID)))
		}
	}

	private func playerItem(_ source: BrowserMediaSource, isLive: Bool) -> SidebarMediaItem {
		let tab = store.workspace.tabs[id: source.id.tabID]
		let pageURL = tab?.restoration.url ?? source.site?.origin
		let title = source.title.isEmpty ? tab?.displayTitle ?? "" : source.title
		return .init(
			id: source.id,
			title: title.isEmpty ? String.localized(.appUI.media.unknownTitle) : title,
			subtitle: source.site?.origin.host() ?? pageURL?.host() ?? "",
			artist: source.artist,
			artwork: source.artwork,
			siteIcon: pageURL.map { .init(profileID: source.id.profileID.rawValue, pageURL: $0) },
			playback: source.playback == .playing ? .playing : .paused,
			canPlay: isLive && source.supports(.play),
			canPause: isLive && source.supports(.pause),
			canPreviousTrack: isLive && source.supports(.previousTrack),
			canNextTrack: isLive && source.supports(.nextTrack),
			isMuted: store.mutedMedia[source.id.tabID] != nil,
			volume: nil,
			canReturn: true
		)
	}

	/// The window's media in stack order: its current space's tabs, the one on screen included.
	private var sources: [BrowserMediaSource] {
		guard let window = store.state.openWindow(windowID), !window.isPrivate
		else { return [] }

		let tabs = Set(window.sidebar.windowTabOrder)
		return store.state.mediaStack(of: window.sidebar.space.profileID).filter { source in
			source.playback != .inactive && tabs.contains(source.id.tabID)
		}
	}

	/// What the stack shows at rest: the last item that plays, else the last item, so the stack
	/// mostly grows upward from it on hover and it stays under the pointer.
	private func restingSource(in sources: [BrowserMediaSource]) -> BrowserMediaSource? {
		sources.last { $0.playback == .playing } ?? sources.last
	}
}
