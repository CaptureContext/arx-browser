import BrowserCore
import Foundation
import MainFeature

extension AppFeature.State {
	/// Rechecks ownership after profile preparation and every native before-unload dialog.
	internal func canCommitTabMove(
		windowID: UUID,
		sourceIDs: [BrowserCore.Tab.ID]
	) -> Bool {
		guard
			!checkingQuit,
			!shouldQuit,
			let host = windowID == main.id && windowIsOpen ? main : windows[id: windowID],
			host.canCommitTabMove(sourceIDs: sourceIDs),
			let request = host.activeTabMove,
			workspace.hasSameMoveStructure(as: request.plan.previous),
			!closingPeekHosts.contains(windowID)
		else { return false }

		let sources = Set(sourceIDs)
		let hosts = (windowIsOpen ? [main] : []) + Array(windows)
		for window in hosts {
			guard sources.isDisjoint(with: window.pendingTabCloses) else { return false }
			guard window.id != windowID else { continue }
			if window.viewer.panes.contains(where: { $0.item.tab.map { sources.contains($0.id) } ?? false }) {
				return false
			}
			if let move = window.activeTabMove {
				let moving = move.plan.movedTabIDs + move.plan.replacements.map(\.source.id)
				if !sources.isDisjoint(with: moving) { return false }
			}
		}

		let peekClaims = peeks.contains {
			$0.source.windowID == windowID
			|| sources.contains($0.tab.id)
			|| $0.source.tabID.map(sources.contains) == true
		}
		let littleClaims = littleWindows.contains {
			sources.contains($0.tab.id) || $0.viewer.tab.map { sources.contains($0.id) } == true
		}
		return !peekClaims && !littleClaims
	}
}
