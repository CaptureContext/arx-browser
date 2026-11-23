import BrowserCore
import BrowserEngineClient
import Foundation
import LittleArxFeature
import _ComposableArchitecture

/// Archives Little Arx windows left unused for Settings' interval (DEV-1138).
/// Behind `ARX_LITTLE_ARX_AUTO_ARCHIVE`, on by default; the interval starts at
/// Never.
///
/// A window is idle from when it stops being the key window, or from when it opens if it never
/// becomes key, until it's key again. One with something going on (Peek, media, a prompt, a
/// loading page, a child window, something typed) is spared, and its clock starts over once
/// that ends. Archiving is a close: the page is asked, and goes to Recently Closed and the Tab
/// Archive as a closed Little Arx page does.
@Reducer
internal struct LittleArxAutoArchiving {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.date.now)
	private var now

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.focusWindow) { state, id in
			if state.littleWindows[id: id] != nil {
				state.littleArxKeyWindowID = id
				state.littleArxIdleSince[id] = nil
			} else if state.littleArxKeyWindowID != nil {
				state.littleArxKeyWindowID = nil
			}
			return .none
		}

		Pullback(\.littleWindows) { state, action in
			guard case let .element(id, action) = action else { return .none }

			switch action {
			case .ui(.lostFocus):
				if state.littleArxKeyWindowID == id { state.littleArxKeyWindowID = nil }
				if state.littleArxIdleSince[id] == nil { state.littleArxIdleSince[id] = now }

			case .delegate(.autoArchiveRefused):
				state.littleArxArchiving.remove(id)
				state.restartLittleArxClock(id, now: now)

			default:
				break
			}
			return .none
		}

		Pullback(\.archiveInactiveTabs) { state in
			let due = state.littleArxWindowsDue(now: now)
			guard !due.isEmpty else { return .none }

			state.littleArxArchiving.formUnion(due.map(\.id))
			return .merge(due.map { little in
				let (id, tabID) = (little.id, little.tab.id)
				return .run { [engine] send in
					let holdsDraft = await AgentTabTidying.holdsDraft(tabID, engine: engine)
					await send(.littleArxArchiveChecked(id, tabID, holdsDraft: holdsDraft))
				}
			})
		}

		Pullback(\.littleArxArchiveChecked) { state, value in
			let (id, tabID, holdsDraft) = value
			guard
				!holdsDraft,
				state.littleWindows[id: id]?.tab.id == tabID,
				state.littleArxIsStillDue(id, now: now)
			else {
				state.littleArxArchiving.remove(id)
				state.restartLittleArxClock(id, now: now)
				return .none
			}

			return .send(.littleWindows(.element(id: id, action: .autoArchive)))
		}
	}
}

extension Reducer where State == AppFeature.State {
	/// Starts a protected Little Arx window's clock over when its protection begins or ends, and
	/// every clock when the interval changes, so each gets a full interval (DEV-1138).
	internal func restartingLittleArxClocks() -> some Reducer<State, Action> {
		self
			.onChange(of: { $0.littleArxProtected }, reduce: { state, previous, current in
				@Dependency(\.date)
				var date

				// Arx's own automatic close isn't a protection, so a change here, even while a window's
				// page is being checked, is the page doing something: a full interval again.
				for id in previous.symmetricDifference(current) {
					if state.littleArxIdleSince[id] != nil { state.littleArxIdleSince[id] = date.now }
				}
				return .none
			})
			.onChange(of: { $0.settings.linkClicks.littleArxArchiveInterval }, reduce: { state, _, _ in
				@Dependency(\.date)
				var date

				for id in state.littleArxIdleSince.keys { state.littleArxIdleSince[id] = date.now }
				return .none
			})
	}
}

extension AppFeature.State {
	/// The interval idle Little Arx windows are archived after, or nil while archiving is off.
	internal var littleArxArchiveInterval: LittleArxArchiveInterval? {
		guard littleArxAutoArchiveEnabled else { return nil }
		return settings.linkClicks.littleArxArchiveInterval
	}

	/// Little Arx windows that have something going on (DEV-1138).
	internal var littleArxProtected: Set<UUID> {
		Set(littleWindows.filter { littleArxCanArchive($0) && littleArxIsProtected($0) }.map(\.id))
	}

	/// Whether the window is one Arx archives at all: a web page in Chromium whose space can take
	/// it. A launcher with only the command bar closes on its own; a WebKit page can't be read for
	/// drafts nor asked before it closes; and a chat, another page off the web, or one whose space
	/// went or changed profile can't go to the Tab Archive, so closing it would lose it.
	internal func littleArxCanArchive(_ little: LittleArxFeature.State) -> Bool {
		guard
			!little.isCommandOnly,
			!webKitTabs.contains(little.tab.id),
			workspace.spaces[id: little.spaceID]?.profileID == little.tab.profileID
		else { return false }

		return (little.viewer.navigation.url ?? little.tab.restoration.url).hasWebScheme
	}

	/// Whether the window is in use in a way that isn't focus: floating as Page PiP (DEV-1112),
	/// Peek over it, a close, move or profile change under way, a loading page, media playing
	/// (muted too), in Picture in Picture or a call, the page in full screen, a permission prompt, an app link's question,
	/// a device chooser or the WebKit page question, or another Little Arx it opened still open. Arx's own automatic close
	/// doesn't count.
	internal func littleArxIsProtected(_ little: LittleArxFeature.State) -> Bool {
		let ownClose = little.closeRequest?.isAutomatic == true

		// A floating window is on screen even when it isn't key.
		if little.isPictureInPicture { return true }
		if little.peekID != nil || little.isPromoting || little.isSwitchingProfile || little.pendingDestination != nil {
			return true
		}
		if little.isClosing, !ownClose { return true }
		if little.viewer.navigation.isLoading { return true }

		let tabID = little.tab.id
		let media = media.visibleSources.contains { source in
			source.id.tabID == tabID && (source.playback == .playing || source.isInPictureInPicture || source.call != nil)
		}
		if media || pagePictureInPicture?.tabID == tabID || pageFullScreen?.tabID == tabID { return true }
		if pagePermissionPrompts.contains(where: { $0.tabID == tabID }) { return true }

		// An app link's question, a device chooser or the WebKit page question (DEV-1000) waiting
		// on the person.
		if appLinkPrompt?.windowID == little.id || deviceChooser?.windowID == little.id { return true }
		if webKitPrompt?.windowID == little.id || browserLinkPrompt?.windowID == little.id { return true }
		return littleWindows.contains { $0.openerWindowID == little.id }
	}

	/// Windows past the interval, not key, not protected and not already being archived. Starts
	/// the clock of a window that never had one, such as one that opened without becoming key,
	/// starts a protected one's over, and forgets windows that closed.
	internal mutating func littleArxWindowsDue(now: Date) -> [LittleArxFeature.State] {
		let open = Set(littleWindows.ids)
		littleArxIdleSince = littleArxIdleSince.filter { open.contains($0.key) }
		littleArxArchiving.formIntersection(open)
		guard let interval = littleArxArchiveInterval else { return [] }

		var due: [LittleArxFeature.State] = []
		for little in littleWindows where littleArxCanArchive(little) && !littleArxArchiving.contains(little.id) {
			guard littleArxKeyWindowID != little.id else { continue }
			guard let since = littleArxIdleSince[little.id], !littleArxIsProtected(little) else {
				littleArxIdleSince[little.id] = now
				continue
			}
			if now.timeIntervalSince(since) >= interval.duration { due.append(little) }
		}
		return due
	}

	/// Right before an archive goes ahead: the window is still idle past the interval, unused and
	/// unprotected, and archiving is still on.
	internal func littleArxIsStillDue(
		_ id: UUID,
		now: Date
	) -> Bool {
		guard
			let interval = littleArxArchiveInterval,
			let little = littleWindows[id: id],
			littleArxCanArchive(little),
			littleArxKeyWindowID != id,
			littleArxArchiving.contains(id),
			let since = littleArxIdleSince[id],
			now.timeIntervalSince(since) >= interval.duration
		else { return false }

		return !littleArxIsProtected(little)
	}

	/// A full interval from now, or no clock at all for the key window.
	internal mutating func restartLittleArxClock(
		_ id: UUID,
		now: Date
	) {
		guard littleWindows[id: id] != nil else { return }
		littleArxIdleSince[id] = littleArxKeyWindowID == id ? nil : now
	}
}
