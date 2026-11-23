import BrowserCore
import BrowserSurfaceClient
import Foundation
import _ComposableArchitecture

internal struct MediaSurfaceRecord: Equatable {
	internal let windowID: UUID
	internal let report: BrowserSurfaceVisibility

	internal init(
		windowID: UUID,
		report: BrowserSurfaceVisibility
	) {
		self.windowID = windowID
		self.report = report
	}
}

extension AppFeature.State {
	internal mutating func reconcileAutomaticMediaVisibility() -> Effect<AppFeature.Action> {
		// Runs for every action, so it looks up only the media's tabs rather than listing every tab.
		let mediaTabs = Set(media.visibleSources.filter { !$0.isPrivate }.map { $0.id.tabID })
		mediaRehostingSources.formIntersection(mediaTabs.filter { containsTab($0) || tabsTearingOff.contains($0) })

		// A tab dropped outside every window is moving until Little Arx shows it (DEV-793).
		mediaRehostingSources.formUnion(tabsTearingOff.intersection(mediaTabs))
		for little in littleWindows {
			let isMoving = little.isPromoting || little.isClosing || little.isSwitchingProfile

			// A new window that hasn't shown its page yet is still taking it over, as after a
			// tear-off or a Peek opened in Little Arx: the old host's detach doesn't hide it.
			let isArriving = !little.isCommandOnly && little.viewer.tab?.id != little.tab.id
			if isMoving || isArriving, mediaTabs.contains(little.tab.id) {
				mediaRehostingSources.insert(little.tab.id)
			}
		}
		for peek in peeks where mediaTabs.contains(peek.tab.id) && peek.phase != .idle {
			mediaRehostingSources.insert(peek.tab.id)
		}
		if ([main] + Array(windows)).contains(where: \.transferInProgress) {
			mediaRehostingSources.formUnion(media.visibleSources.map { $0.id.tabID })
		}
		let currentIDs = Set(media.visibleSources.map(\.id))
		mediaSourceVisibility = mediaSourceVisibility.filter { currentIDs.contains($0.key) }
		mediaSurfaces = mediaSurfaces.filter { hasMediaHost($0.value.windowID) }
		mediaHostWindows = mediaHostWindows.filter { mediaTabs.contains($0.key) && window($0.value) != nil }
		fullScreenTransitionWindows = fullScreenTransitionWindows.filter(hasMediaHost)
		var effects: [Effect<AppFeature.Action>] = []

		for source in media.visibleSources where !source.isPrivate {
			guard let visible = mediaVisibility(of: source) else { continue }

			if visible {
				mediaRehostingSources.remove(source.id.tabID)
				let host = mediaSurfaces.values.first { $0.report.tabID == source.id.tabID && $0.report.isVisible == true }
				if let host, window(host.windowID) != nil { mediaHostWindows[source.id.tabID] = host.windowID }
			}
			let previous = mediaSourceVisibility[source.id]
			mediaSourceVisibility[source.id] = visible

			if visible, previous != true {
				effects.append(.send(.media(.ui(.sourceBecameVisible(source.id)))))

			} else if !visible, previous == true, !shouldQuit, !checkingQuit {
				effects.append(.send(.media(.ui(.sourceBecameHidden(source.id)))))
			}
		}

		if let effect = returnAutomaticPagePictureInPicture() { effects.append(effect) }

		return .merge(effects)
	}

	/// Sends an automatic Page PiP back to its tab once the window it floats from shows that tab
	/// on the display with Arx in front, as a video's PiP returns (DEV-1246). Forgets it once its
	/// page no longer floats.
	private mutating func returnAutomaticPagePictureInPicture() -> Effect<AppFeature.Action>? {
		guard let tabID = automaticPagePictureInPicture else { return nil }
		guard let current = pagePictureInPicture, current.tabID == tabID else {
			automaticPagePictureInPicture = nil
			return nil
		}
		guard
			current.phase == .open,
			media.automatic.closesOnReturn,
			media.automaticEntry.isApplicationActive,
			windowsOnDisplay?.contains(current.windowID) == true,
			let host = window(current.windowID),
			host.viewer.panes.contains(where: { $0.item.tab?.id == tabID })
		else { return nil }

		automaticPagePictureInPicture = nil
		return .send(.ui(.closePagePictureInPicture(focusesTab: false)))
	}

	/// Nil means a source is moving or its expected native host has not reported yet.
	internal func mediaVisibility(of source: BrowserMediaSource) -> Bool? {
		guard
			!source.isPrivate,
			containsTab(source.id.tabID),
			workspace.profiles.ids.contains(source.id.profileID)
		else { return nil }

		let id = source.id.tabID
		let ordinary = (windowIsOpen ? [main] : []) + windows.filter { !$0.isPrivate }
		let peeksForSource = peeks.filter { $0.tab.id == id && $0.tab.profileID == source.id.profileID }
		let littleForSource = littleWindows.filter { $0.tab.id == id && $0.tab.profileID == source.id.profileID }

		// A transfer must not look like leaving a video tab during surface handoff.
		guard
			!ordinary.contains(where: { $0.transferInProgress || $0.pendingTabCloses.contains(id) }),
			!peeksForSource.contains(where: { $0.phase != .idle }),
			!littleForSource.contains(where: { $0.isPromoting || $0.isClosing || $0.isSwitchingProfile })
		else { return nil }

		var hosts: Set<UUID> = []
		for window in ordinary where !window.isClosing {
			let isBorrowed = peeks.contains { !$0.isTemporary && $0.tab.id == id }
			let showsSource = window.viewer.panes.contains { pane in
				pane.item.tab?.id == id
				&& pane.item.tab?.profileID == source.id.profileID
			}
			if !isBorrowed, showsSource {
				hosts.insert(window.id)
			}
		}
		for little in littleForSource where little.viewer.tab?.id == id && !little.isCommandOnly {
			hosts.insert(little.id)
		}
		for peek in peeksForSource where peek.viewer.tab?.id == id && hasMediaHost(peek.source.windowID) {
			hosts.insert(peek.source.windowID)
		}

		let reports = mediaSurfaces.values.filter {
			$0.report.tabID == id && hosts.contains($0.windowID)
		}
		if mediaRehostingSources.contains(id) {
			return reports.contains(where: { $0.report.isVisible == true }) ? true : nil
		}

		// Selection state can lead SwiftUI's actual detach. Wait for its source-bound
		// report, otherwise native admission would reject a still-visible old view.
		let hasVisibleReport = mediaSurfaces.values.contains { record in
			record.report.tabID == id && record.report.isVisible == true
		}
		if hasVisibleReport { return true }

		// A window in a macOS full-screen transition can read as covered while its Space moves
		// (DEV-991): what it shows is known once the transition has settled.
		guard hosts.isDisjoint(with: fullScreenTransitionWindows) else { return nil }

		guard !hosts.isEmpty else { return false }

		let reportedHosts = Set(reports.map(\.windowID))
		guard hosts.isSubset(of: reportedHosts) else { return nil }

		// Its window is still on the display, only covered by another app's, out of focus, or not
		// full screen with the person on another OS workspace: the video keeps playing in place.
		// It floats once the window is minimised or hidden, or a full-screen window's OS
		// workspace leaves the display (DEV-1246, DEV-1322; `WindowDisplay`).
		if let onDisplay = windowsOnDisplay, !hosts.isDisjoint(with: onDisplay) { return true }

		return false
	}
}
