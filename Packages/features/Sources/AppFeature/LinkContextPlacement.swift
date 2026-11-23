import BrowserCore
import Foundation

/// Re-resolved at menu selection. Focus changes never substitute another target.
internal struct LinkContextPlacement: Equatable {
	internal let windowID: UUID
	internal let paneID: UUID
	internal let peekID: UUID?
	internal let generation: Int

	/// A page floating in Page PiP that no pane shows (DEV-1105): its links open in the window it
	/// floats from, next to it, with `paneID` that window's active pane.
	internal let floatingTabID: BrowserCore.Tab.ID?

	internal init(
		windowID: UUID,
		paneID: UUID,
		peekID: UUID? = nil,
		generation: Int,
		floatingTabID: BrowserCore.Tab.ID? = nil
	) {
		self.windowID = windowID
		self.paneID = paneID
		self.peekID = peekID
		self.generation = generation
		self.floatingTabID = floatingTabID
	}
}

extension AppFeature.State {
	private func hasLinkContextSource(
		windowID: UUID,
		paneID: UUID,
		profileID: Profile.ID
	) -> Bool {
		if let little = littleWindows[id: windowID] {
			return paneID == little.id
			&& workspace.spaces[id: little.spaceID]?.profileID == profileID
		}
		let host = windowID == main.id ? (windowIsOpen ? main : nil) : windows[id: windowID]
		return host?.isPrivate == false
		&& host?.sidebar.space.profileID == profileID
		&& host?.viewer.panes.contains(where: { $0.id == paneID }) == true
	}

	internal func linkContextPlacement(_ context: BrowserLinkContext) -> LinkContextPlacement? {
		do {
			try context.validate()
		} catch {
			return nil
		}

		return nativeContentPlacement(
			tabID: context.tabID,
			profileID: context.profileID,
			isPrivate: context.isPrivate
		)
	}

	internal func nativeContentPlacement(
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		isPrivate: Bool
	) -> LinkContextPlacement? {
		guard !shouldQuit, !checkingQuit else { return nil }

		var matches: [LinkContextPlacement] = []
		for peek in peeks where peek.tab.id == tabID {
			guard
				!isPrivate, peek.phase == .idle, !peek.orphanCloseRequested,
				hasLinkActionHost(peek.source.windowID),
				hasLinkContextSource(windowID: peek.source.windowID, paneID: peek.source.paneID, profileID: profileID),
				peek.tab.profileID == profileID,
				peek.viewer.tab?.id == tabID,
				peek.viewer.tab?.profileID == profileID,
				workspace.profiles.ids.contains(profileID)
			else { continue }
			matches.append(.init(
				windowID: peek.source.windowID, paneID: peek.source.paneID,
				peekID: peek.id, generation: peek.viewer.generation
			))
		}
		for little in littleWindows where little.tab.id == tabID {
			guard
				!isPrivate, !little.isCommandOnly, !little.isClosing, !little.isPromoting,
				!little.isSwitchingProfile,
				little.tab.profileID == profileID,
				little.viewer.tab?.id == tabID,
				little.viewer.tab?.profileID == profileID,
				!peeks.contains(where: { $0.source.windowID == little.id }),
				workspace.spaces[id: little.spaceID]?.profileID == profileID,
				workspace.profiles.ids.contains(profileID)
			else { continue }
			matches.append(.init(windowID: little.id, paneID: little.id, generation: little.viewer.generation))
		}
		for host in (windowIsOpen ? [main] : []) + Array(windows) where !host.isClosing {
			guard !host.transferInProgress, !host.pendingTabCloses.contains(tabID) else { continue }
			guard host.isPrivate == isPrivate else { continue }
			guard !peeks.contains(where: { $0.source.windowID == host.id }) else { continue }
			if !host.isPrivate {
				guard
					workspace.tabs[id: tabID]?.profileID == profileID,
					host.sidebar.organization.tabs[id: tabID]?.profileID == profileID,
					workspace.canPresent(tabID, in: host.sidebar.spaceID),
					host.sidebar.organization.canPresent(tabID, in: host.sidebar.spaceID)
				else { continue }
			}
			for pane in host.viewer.panes {
				guard
					pane.item.tab?.id == tabID,
					pane.item.tab?.profileID == profileID,
					host.sidebar.space.profileID == profileID
				else { continue }
				matches.append(.init(windowID: host.id, paneID: pane.id, generation: pane.item.generation))
			}
		}
		if matches.isEmpty, let floating = floatingPagePlacement(tabID: tabID, profileID: profileID, isPrivate: isPrivate) {
			matches.append(floating)
		}
		return matches.count == 1 ? matches.first : nil
	}

	/// A page floating in Page PiP that no pane shows belongs to the window it floats from
	/// (DEV-1105), so its new tabs and windows open there, in the tab's own space and profile
	/// whatever the window shows now (`nativeContentsSpace`).
	private func floatingPagePlacement(
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		isPrivate: Bool
	) -> LinkContextPlacement? {
		guard
			let floating = pagePictureInPicture,
			floating.tabID == tabID,
			floating.isFloating,
			isPagePictureInPictureHostOpen(floating.windowID),
			let host = window(floating.windowID),
			!host.transferInProgress,
			!host.pendingTabCloses.contains(tabID),
			host.isPrivate == isPrivate,
			!peeks.contains(where: { $0.source.windowID == host.id }),
			host.sidebar.organization.tabs[id: tabID]?.profileID == profileID,
			host.isPrivate || workspace.tabs[id: tabID]?.profileID == profileID,
			let pane = host.viewer.panes[id: host.viewer.activePaneID]
		else { return nil }

		return .init(
			windowID: host.id,
			paneID: pane.id,
			generation: pane.item.generation,
			floatingTabID: tabID
		)
	}
}
