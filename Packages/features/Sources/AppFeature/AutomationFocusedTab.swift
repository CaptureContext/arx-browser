import BrowserAutomationClient
import BrowserCore
import Foundation

extension AppFeature.State {
	/// The tab the focused-tab alias stands for: the focused pane's tab of the focused
	/// ordinary window, only when the client opted in and its grant covers that tab. In a split
	/// that's the pane last clicked or focused with the keyboard, not the sidebar's row (DEV-835).
	/// The MCP helper substitutes the result into the request and reports which tab it used,
	/// so every later check binds to an explicit tab and revision.
	public func automationFocusedTab(
		for client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFocusedTab? {
		guard
			automationPreferences.isEnabled,
			client.allowsRead,
			client.allowsFocusedTab,
			!automationPrivacyIsLocked
		else { return nil }

		let windowID = focusedWindowID ?? main.id
		let window = windowID == main.id ? main : windows[id: windowID]
		guard
			let window,
			!window.isPrivate,
			let tab = window.focusedPageTab,
			workspace.tabs[id: tab.id] != nil,
			AutomationAccess.permitsTab(tab.id, client: client, organization: workspace)
		else { return nil }

		let item = AutomationInventoryBuilder.item(
			tab.id.rawValue,
			kind: .tab,
			client: client,
			organization: workspace,
			snapshots: snapshots
		)
		guard let item else { return nil }

		return .init(tabID: item.id, revision: item.revision)
	}

	/// A tab's events-feed signal. The address is a short hash salted per client, so a change shows
	/// without the address itself leaving the digest, two clients can't match their hashes, and a
	/// grant change doesn't make every tab look navigated.
	internal static func automationSignal(
		_ snapshot: BrowserSessionSnapshot?,
		dialog: BrowserPageDialog.Kind?,
		salt: UUID
	) -> AutomationTabSignal {
		guard let navigation = snapshot?.navigation
		else { return .init(state: .unloaded, dialog: dialog) }

		let address = navigation.url.map { url in
			String(AutomationSecurity.digest(Data((salt.uuidString + url.absoluteString).utf8)).prefix(16))
		}
		let state: AutomationInventoryItem.SessionState = navigation.errorCode != nil
		? .failed
		: navigation.isLoading ? .loading : .ready
		return .init(address: address, state: state, errorCode: navigation.errorCode, dialog: dialog)
	}

	/// The granted tabs' current revisions, for the helper's resource subscriptions.
	/// Nothing is reported while automation is off or the sign-in lock holds.
	public func automationChanges(
		for client: AutomationClient,
		snapshots snapshot: (BrowserCore.Tab.ID) -> BrowserSessionSnapshot?,
		dialog: (BrowserCore.Tab.ID) -> BrowserPageDialog.Kind? = { _ in nil }
	) -> AutomationChangeDigest? {
		guard
			automationPreferences.isEnabled,
			client.allowsRead,
			!automationPrivacyIsLocked,
			automationWorkspaceIsSynchronized
		else { return nil }

		let pairs = automationSnapshotTabIDs.compactMap { id in snapshot(id).map { (id, $0) } }
		var digest = AutomationInventoryBuilder.changes(
			client: client,
			organization: workspace,
			snapshots: Dictionary(uniqueKeysWithValues: pairs)
		)

		// A tab changing window changes what its resources read, so subscribers hear of it
		// (DEV-1157). The digest is only compared, never shown.
		if independentWindows {
			let locations = workspace.tabLocations
			for (id, revision) in digest.tabs {
				guard let window = automationWindow(keeping: .init(rawValue: id), locations: locations) else { continue }
				digest.tabs[id] = AutomationSecurity.digest(Data("\(revision):\(window.uuidString)".utf8))
			}
		}
		if client.allows([.read, .downloads]) {
			let revisions = automationDataItems(.downloads, client: client).map(\.revision)
			digest.downloads = AutomationSecurity.digest(Data(revisions.joined(separator: ",").utf8))
		}

		// DEV-924: what `arx://events` reports, for the tabs the digest already lists.
		for id in digest.tabs.keys {
			let tabID = BrowserCore.Tab.ID(rawValue: id)
			digest.signals[id] = Self.automationSignal(
				snapshot(tabID),
				dialog: dialog(tabID),
				salt: client.id
			)
		}
		return digest
	}
}
