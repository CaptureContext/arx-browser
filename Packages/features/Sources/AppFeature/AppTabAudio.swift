import AppUI
import BrowserCore
import BrowserMediaClient
import Foundation
import MainFeature
import SidebarFeature
import _ComposableArchitecture

/// Per-tab mute and volume (DEV-800): a tab row's speaker, its menu, its volume popover and the
/// Media page's sliders. Chromium mutes a tab natively; the volume needs an engine built with
/// `ArxEngineSetPageAudioVolume`, and stays hidden on older engines.
///
/// A tab's volume lasts while the app runs, across navigations, and isn't saved per site: a call
/// turned down shouldn't quiet the next video on the same site.
@Reducer
internal struct AppTabAudio {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	/// Slider positions this close to the end mean 100%.
	internal static let fullVolumeTolerance: Double = 0.005

	@Dependency(\.browserMedia)
	private var client

	internal var body: some ReducerOf<Self> {
		Pullback(\.media) { state, _ in
			let available = state.media.isAvailable
			state.supportsTabVolume = available && MainActor.assumeIsolated { [client] in client.supportsVolume() }
			return .none
		}

		Pullback(\.main.delegate.setTabMuted) { _, value in
			.send(.ui(.setTabMuted(value.0, value.1)))
		}

		Pullback(\.main.delegate.setTabVolume) { _, value in
			.send(.ui(.setTabVolume(value.0, value.1)))
		}

		Pullback(\.windows) { _, action in
			switch action {
			case let .element(_, .delegate(.setTabMuted(tabID, isMuted))):
				return .send(.ui(.setTabMuted(tabID, isMuted)))
			case let .element(_, .delegate(.setTabVolume(tabID, volume))):
				return .send(.ui(.setTabVolume(tabID, volume)))
			default:
				return .none
			}
		}

		Pullback(\.ui.setTabMuted) { state, value in
			let (tabID, isMuted) = value
			guard state.media.isAvailable, state.hasOrdinaryTab(tabID)
			else { return .none }

			return .run { @MainActor [client] send in
				let succeeded = (try? client.setMuted(tabID, isMuted)) != nil
				let fallback = succeeded ? isMuted : !isMuted
				send(.event(.mediaMuteChanged(tabID, client.position(tabID)?.isMuted ?? fallback)))
			}
		}

		Pullback(\.event.mediaMuteChanged) { state, value in
			let (tabID, isMuted) = value
			if isMuted {
				state.mutedTabs.insert(tabID)
			} else {
				state.mutedTabs.remove(tabID)
			}
			return .none
		}

		Pullback(\.ui.setTabVolume) { state, value in
			let (tabID, requested) = value
			guard
				state.supportsTabVolume,
				requested.isFinite,
				state.hasOrdinaryTab(tabID)
			else { return .none }

			let volume = Self.normalized(requested)
			let previous = state.tabVolumes[tabID] ?? 1
			guard volume != previous else { return .none }

			// The slider follows the drag at once; a refusal puts it back.
			state.tabVolumes[tabID] = volume < 1 ? volume : nil

			// Turning a muted tab up unmutes it, as the system volume does.
			let unmutes = volume > 0 && state.mutedTabs.contains(tabID)

			return .run { @MainActor [client] send in
				do {
					try client.setVolume(tabID, volume)
				} catch {
					send(.event(.tabVolumeChanged(tabID, previous)))
					return
				}
				guard unmutes else { return }

				let succeeded = (try? client.setMuted(tabID, false)) != nil
				send(.event(.mediaMuteChanged(tabID, client.position(tabID)?.isMuted ?? !succeeded)))
			}
		}

		Pullback(\.event.tabVolumeChanged) { state, value in
			let (tabID, volume) = value
			let normalized = Self.normalized(volume)
			state.tabVolumes[tabID] = normalized < 1 ? normalized : nil
			return .none
		}

		Pullback(\.media.event.changed) { state, _ in
			let tabs = state.audioTabIDs
			state.tabVolumes = state.tabVolumes.filter { tabs.contains($0.key) }

			let candidates = Set(state.media.visibleSources.map(\.id.tabID))
				.union(state.mutedTabs)
				.intersection(tabs)
			state.mutedTabs = MainActor.assumeIsolated { [client] in
				Set(candidates.filter { client.position($0)?.isMuted == true })
			}

			// A tab's page can be created again (a crash or a profile move): it starts at full volume.
			let volumes = state.tabVolumes.filter { id, _ in
				state.media.visibleSources.contains { $0.id.tabID == id }
			}
			guard state.supportsTabVolume, !volumes.isEmpty
			else { return .none }

			return .run { @MainActor [client] _ in
				for (tabID, volume) in volumes {
					try? client.setVolume(tabID, volume)
				}
			}
		}
	}

	internal static func normalized(_ volume: Double) -> Double {
		let clamped = min(max(volume, 0), 1)
		return clamped >= 1 - fullVolumeTolerance ? 1 : clamped
	}
}

extension AppFeature.State {
	fileprivate func hasOrdinaryTab(_ tabID: BrowserCore.Tab.ID) -> Bool {
		audioTabIDs.contains(tabID)
	}

	/// Tabs whose sound the app keeps: the workspace's, and pages Little Arx holds, such as a tab
	/// dropped outside every window (DEV-793), which keeps its volume there and back.
	fileprivate var audioTabIDs: Set<BrowserCore.Tab.ID> {
		Set(workspace.tabs.map(\.id))
		.union(littleWindows.map(\.tab.id))
		.union(tabsTearingOff)
	}

	/// What the sidebars show of each tab's sound.
	internal struct TabAudioPresentation: Equatable {
		internal var tabs: [BrowserCore.Tab.ID: SidebarItem.Audio]
		internal var fallback: SidebarItem.Audio?
	}

	internal var tabAudioPresentation: TabAudioPresentation {
		let playing = Set(
			media.visibleSources
				.filter { $0.playback == .playing && !$0.isPrivate }
				.map(\.id.tabID)
		)
		let volume: (BrowserCore.Tab.ID) -> Double? = { [supportsTabVolume, tabVolumes] id in
			supportsTabVolume ? tabVolumes[id] ?? 1 : nil
		}
		var tabs: [BrowserCore.Tab.ID: SidebarItem.Audio] = [:]
		for id in playing.union(mutedTabs).union(tabVolumes.keys) {
			tabs[id] = .init(
				isPlaying: playing.contains(id),
				isMuted: mutedTabs.contains(id),
				volume: volume(id)
			)
		}
		return .init(
			tabs: tabs,
			fallback: media.isAvailable ? .init(volume: supportsTabVolume ? 1 : nil) : nil
		)
	}

	/// Private windows can't mute their tabs, so their rows show no speaker.
	internal mutating func publish(_ presentation: TabAudioPresentation) {
		let ordinary = (tabs: presentation.tabs, fallback: presentation.fallback)
		let none: (tabs: [BrowserCore.Tab.ID: SidebarItem.Audio], fallback: SidebarItem.Audio?) = ([:], nil)

		let mainAudio = main.isPrivate ? none : ordinary
		if main.sidebar.tabAudio != mainAudio.tabs { main.sidebar.tabAudio = mainAudio.tabs }
		if main.sidebar.defaultTabAudio != mainAudio.fallback { main.sidebar.defaultTabAudio = mainAudio.fallback }

		for window in windows {
			let audio = window.isPrivate ? none : ordinary
			if window.sidebar.tabAudio != audio.tabs { windows[id: window.id]?.sidebar.tabAudio = audio.tabs }
			if window.sidebar.defaultTabAudio != audio.fallback {
				windows[id: window.id]?.sidebar.defaultTabAudio = audio.fallback
			}
		}
	}

}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Keeps every window's tab rows in step with the tabs' sound, whichever reducer changed it,
	/// new windows included. Only a difference reaches a sidebar.
	internal func publishingTabAudio() -> some Reducer<State, Action> {
		CombineReducers {
			self
			Reduce { state, _ in
				state.publish(state.tabAudioPresentation)
				return .none
			}
		}
	}
}
