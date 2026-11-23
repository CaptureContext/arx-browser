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

/// Media is observed once for the app; each window lists only what plays in its current profile.
internal struct AppLibraryMediaPanel: View {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID
	) {
		self.store = store
		self.windowID = windowID
	}

	internal var body: some View {
		let sources = self.sources
		SidebarMediaPanel(
			items: sources.map(item),
			notice: notice,
			isBusy: store.media.pending != nil,
			onPlayPause: { item in
				store.send(.media(.ui(.perform(item.id, item.canPause ? .pause : .play))))
			},
			onMute: { item in store.send(.ui(.toggleMediaMute(item.id.tabID))) },
			onVolume: { item, volume in store.send(.ui(.setTabVolume(item.id.tabID, volume))) },
			onReturn: { item in
				if let source = sources.first(where: { $0.id == item.id }) { returnToTab(source) }
			},
			onCall: { item, control in
				let action: BrowserMediaSource.Action = switch control {
				case .microphone: .toggleMicrophone
				case .camera: .toggleCamera
				case .hangUp: .hangUp
				}
				store.send(.media(.ui(.perform(item.id, action))))
			},
			rowMenu: { item in
				if let source = sources.first(where: { $0.id == item.id }) {
					menu(source)
				}
			}
		)
	}

	private func returnToTab(_ source: BrowserMediaSource) {
		if store.media.visibleSources.contains(where: { $0.id == source.id }) {
			store.send(.media(.ui(.returnToTab(source.id))))
		} else {
			store.send(.ui(.returnToMutedMedia(source.id.tabID)))
		}
	}

	/// The sources of the window's profile and muted pages that left their session, in the order
	/// their media was opened (DEV-1245).
	private var sources: [BrowserMediaSource] {
		let window = windowID == store.main.id ? store.main : store.windows[id: windowID]
		guard let window, !window.isPrivate else { return [] }
		return store.state.mediaStack(of: window.sidebar.space.profileID)
	}

	private func item(_ source: BrowserMediaSource) -> SidebarMediaItem {
		let tab = store.workspace.tabs.first { $0.id == source.id.tabID && $0.profileID == source.id.profileID }
		let isVisible = store.media.visibleSources.contains { $0.id == source.id }
		let pageURL = tab?.restoration.url ?? source.site?.origin
		let title = source.title.isEmpty ? tab?.displayTitle ?? "" : source.title
		return .init(
			id: source.id,
			title: title.isEmpty ? String.localized(.appUI.media.unknownTitle) : title,
			subtitle: source.site?.origin.host() ?? pageURL?.host() ?? "",
			siteIcon: pageURL.map { .init(profileID: source.id.profileID.rawValue, pageURL: $0) },
			playback: playback(source),
			canPlay: isVisible && source.supports(.play),
			canPause: isVisible && source.supports(.pause),
			isMuted: store.mutedMedia[source.id.tabID] != nil,
			volume: store.supportsTabVolume ? store.tabVolumes[source.id.tabID] ?? 1 : nil,
			canReturn: !isVisible || !source.isInPictureInPicture || source.supports(.exitPictureInPicture),
			call: isVisible ? source.call.map { call in
				.init(
					isMicrophoneOn: call.isMicrophoneOn,
					isCameraOn: call.isCameraOn,
					canToggleMicrophone: source.supports(.toggleMicrophone),
					canToggleCamera: source.supports(.toggleCamera),
					canHangUp: source.supports(.hangUp)
				)
			} : nil
		)
	}

	private func playback(_ source: BrowserMediaSource) -> SidebarMediaItem.Playback {
		if source.isInPictureInPicture { return .pictureInPicture }
		return switch source.playback {
		case .playing: .playing
		case .paused: .paused
		case .inactive: .inactive
		}
	}

	/// ArxPiP and automatic PiP, which the row has no room for.
	@ViewBuilder
	private func menu(_ source: BrowserMediaSource) -> some View {
		let isVisible = store.media.visibleSources.contains { $0.id == source.id }
		let mediaItem = item(source)

		// Present in Picture in Picture and the row's own actions (DEV-1106); a muted page that
		// left its session can only come back.
		SidebarMediaMenu(
			item: mediaItem,
			pictureInPicture: isVisible ? store.state.mediaPictureInPicture(of: source) : nil,
			onPresent: { store.send(.media(.ui(.perform(source.id, .enterPictureInPicture)))) },
			onExitPictureInPicture: isVisible && source.isInPictureInPicture && source.supports(.exitPictureInPicture)
			? { store.send(.media(.ui(.perform(source.id, .exitPictureInPicture)))) }
			: nil,
			onPlayPause: { pauses in store.send(.media(.ui(.perform(source.id, pauses ? .pause : .play)))) },
			onMute: { store.send(.ui(.toggleMediaMute(source.id.tabID))) },
			onReturn: { returnToTab(source) }
		)
		let canConfigureAutomatic = isVisible
		&& source.site != nil

		// A site without its own automatic action still floats through Arx's manual entry (DEV-848).
		&& (
			source.actions.contains(.enterAutomaticPictureInPicture)
			|| source.actions.contains(.enterPictureInPicture)
			|| store.media.automatic.permits(source)
		)
		if canConfigureAutomatic {
			Toggle(
				String.localized(.appUI.media.automaticPicture),
				isOn: Binding(
					get: { store.media.automatic.permits(source) },
					set: { store.send(.media(.ui(.setAutomatic(source.id, enabled: $0)))) }
				)
			)
		}
	}

	private var notice: String? {
		if let failure = store.mediaReturnFailure {
			return failure == .previewOpen
			? String.localized(.appUI.media.previewOpen)
			: String.localized(.appUI.media.missingSpace)
		}
		return store.media.failure.map { failure in
			switch failure {
			case .unavailable: String.localized(.appUI.media.unavailable)
			case .staleSource: String.localized(.appUI.media.staleSource)
			case .unsupportedAction: String.localized(.appUI.media.unsupportedAction)
			case .requestFailed: String.localized(.appUI.media.requestFailed)
			case .timedOut: String.localized(.appUI.media.timedOut)
			}
		}
	}
}
