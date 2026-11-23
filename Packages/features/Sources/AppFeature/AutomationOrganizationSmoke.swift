#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Exercises real MCP organization and close commands only in the caller's disposable spaces.
@MainActor
internal enum AutomationOrganizationSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		session: AutomationSmokeSession,
		profileID: Profile.ID,
		sourceSpace: Space.ID,
		destinationSpace: Space.ID,
		url: URL
	) async throws {
		guard engine.client.closeAuthorized != nil
		else { throw AutomationSmokeFailure.atomicCloseUnavailable }
		guard
			sourceSpace != destinationSpace,
			store.workspace.spaces[id: sourceSpace]?.profileID == profileID,
			store.workspace.spaces[id: destinationSpace]?.profileID == profileID
		else { throw AutomationSmokeFailure.setupFailed }

		let focusedWindow = store.focusedWindowID
		let focusedPane = store.main.viewer.activePaneID
		let focusedTab = store.main.viewer.item.tab?.id
		let source = try await item(sourceSpace.rawValue, in: session)
		let createFolder = AutomationCommand(
			operationID: UUID(),
			action: .createFolder,
			targetID: source.id,
			expectedRevision: source.revision,
			name: "MCP moved folder fixture"
		)
		let folderID = try await committed(createFolder, in: session)
		let pinnedID = try await open(
			in: sourceSpace,
			url: url,
			store: store,
			session: session,
			engine: engine
		)
		let pin = try await item(pinnedID, in: session)
		let folder = try await item(folderID, in: session)
		let pinTab = AutomationCommand(
			operationID: UUID(),
			action: .pinTab,
			targetID: pin.id,
			expectedRevision: pin.revision,
			destinationID: folder.id,
			destinationRevision: folder.revision
		)
		_ = try await committed(pinTab, in: session)

		let saved = store.workspace.tabs.first { $0.id.rawValue == pinnedID }
		let snapshot = engine.client.snapshot(.init(rawValue: pinnedID))
		let freshFolder = try await item(folderID, in: session)
		let destination = try await item(destinationSpace.rawValue, in: session)
		let moveFolder = AutomationCommand(
			operationID: UUID(),
			action: .moveFolder,
			targetID: freshFolder.id,
			expectedRevision: freshFolder.revision,
			destinationID: destination.id,
			destinationRevision: destination.revision
		)
		_ = try await committed(moveFolder, in: session)
		let moved = store.workspace.folders.first(where: { $0.id.rawValue == folderID })
		let sourceItems = store.workspace.spaces[id: sourceSpace]?.savedItems
		let destinationItems = store.workspace.spaces[id: destinationSpace]?.savedItems

		// The moved page keeps its session. A color it reports late, as a page loaded in the
		// background can, isn't the move changing it (`SmokeSnapshotDifference`).
		let page = SmokeSnapshotDifference.between(snapshot, engine.client.snapshot(.init(rawValue: pinnedID)))
		let pageCheck = if case let .changed(fields) = page { "pageSession[\(fields)]" } else { "pageSession" }

		// The tab keeps its place in the organization; the title and address its page last
		// reported aren't the move's (`SmokeTabDifference`).
		let tab = SmokeTabDifference.between(saved, store.workspace.tabs.first(where: { $0.id.rawValue == pinnedID }))
		let tabCheck = if case let .changed(fields) = tab { "tabUnchanged[\(fields)]" } else { "tabUnchanged" }
		try require("moveFolder", [
			"folderInDestination": moved?.spaceID == destinationSpace,
			"folderChildren": moved?.children == [.tab(.init(rawValue: pinnedID))],
			"sourceLetGo": moved.map { sourceItems?.contains(.folder($0.id)) == false } ?? false,
			"destinationHolds": moved.map { destinationItems?.contains(.folder($0.id)) == true } ?? false,
			tabCheck: tab.isUnchanged(check: "organization.moveFolder.tab"),
			"pinned": saved?.savedDestination != nil,
			"profile": saved?.profileID == profileID,
			"client": saved?.automationClientID != nil,
			"snapshot": snapshot != nil,
			pageCheck: snapshot != nil && page.isUnchanged(check: "organization.moveFolder.pageSession"),
		])
		guard let clientID = saved?.automationClientID else { throw AutomationSmokeFailure.inventoryMismatch }

		let closeID = try await open(
			in: destinationSpace,
			url: url,
			store: store,
			session: session,
			engine: engine
		)
		let closeTarget = try await item(closeID, in: session)
		let closeTab = AutomationCommand(
			operationID: UUID(),
			action: .closeTab,
			targetID: closeTarget.id,
			expectedRevision: closeTarget.revision
		)
		_ = try await committed(closeTab, in: session)
		let archived = store.workspace.archive.first(where: { $0.tab.id.rawValue == closeID })
		try require("closeTab", [
			"pageClosed": engine.client.snapshot(.init(rawValue: closeID)) == nil,
			"tabRemoved": !store.workspace.tabs.contains(where: { $0.id.rawValue == closeID }),
			"archived": archived != nil,
			"archivedSpace": archived?.originalSpaceID == destinationSpace,
			"archivedProfile": archived?.tab.profileID == profileID,
			"archivedClient": archived?.tab.automationClientID == clientID,
			"focusedWindow": store.focusedWindowID == focusedWindow,
			"focusedPane": store.main.viewer.activePaneID == focusedPane,
			"focusedTab": store.main.viewer.item.tab?.id == focusedTab,
		])
		let after = try await session.inventory()
		guard case let .inventory(inventory) = after else {
			let miss = if case let .failure(miss) = AutomationHostSmoke.lookUp(closeID, in: after) { "\(miss)" } else { "reply" }
			throw mismatch("closedInventory", actual: miss)
		}
		try require("closedInventory", ["closedUnlisted": !inventory.items.contains(where: { $0.id == closeID })])

		print("ARX_MCP_ORGANIZATION_NATIVE_SMOKE_SUCCESS")
	}

	private static func item(
		_ id: UUID,
		in session: AutomationSmokeSession,
		function: StaticString = #function,
		line: Int = #line
	) async throws -> AutomationInventoryItem {
		switch AutomationHostSmoke.lookUp(id, in: try await session.inventory()) {
		case let .success(item): return item
		case let .failure(miss): throw mismatch("inventory for=\(function):\(line)", actual: "\(miss)")
		}
	}

	/// Throws an inventory mismatch naming every check that failed; engine batch 7 saw a bare one.
	private static func require(
		_ stage: String,
		_ checks: KeyValuePairs<String, Bool>
	) throws {
		let failed = checks.filter { !$0.value }.map(\.key)
		guard !failed.isEmpty else { return }

		throw mismatch(stage, actual: "failed " + failed.joined(separator: ","))
	}

	private static func mismatch(
		_ check: String,
		actual: String
	) -> AutomationSmokeMismatch {
		AutomationSmokeMismatch(
			.inventoryMismatch,
			check: "organization.\(check)",
			expected: "holds",
			actual: actual,
			focus: SmokeDiagnostics.focus()
		)
	}

	private static func committed(
		_ command: AutomationCommand,
		in session: AutomationSmokeSession
	) async throws -> UUID {
		guard
			case let .command(result) = try await session.command(command),
			result.operationID == command.operationID,
			result.status == .committed,
			let targetID = result.targetID,
			command.action == .createFolder || targetID == command.targetID
		else { throw AutomationSmokeFailure.authorizationFailed }
		return targetID
	}

	private static func open(
		in spaceID: Space.ID,
		url: URL,
		store: StoreOf<AppFeature>,
		session: AutomationSmokeSession,
		engine: ChromiumBrowserEngine
	) async throws -> UUID {
		let destination = try await item(spaceID.rawValue, in: session)
		let operationID = UUID()
		let command = AutomationCommand(
			operationID: operationID,
			action: .openTab,
			targetID: destination.id,
			expectedRevision: destination.revision,
			url: url
		)
		guard
			case let .command(result) = try await session.command(command),
			result.operationID == operationID,
			result.status == .acceptedLoading,
			let id = result.targetID
		else { throw AutomationSmokeFailure.navigationMismatch }

		for _ in 0..<100 {
			guard
				let snapshot = engine.client.snapshot(.init(rawValue: id)),
				snapshot.navigation.url == url,
				snapshot.navigation.title == "Arx MCP excluded",
				!snapshot.navigation.isLoading,
				snapshot.navigation.errorCode == nil,
				let tab = store.workspace.tabs.first(where: { $0.id.rawValue == id }),
				tab.restoration.url == url,
				tab.restoration.title == "Arx MCP excluded"
			else {
				try await Task.sleep(for: .milliseconds(100))
				continue
			}

			return id
		}
		throw AutomationSmokeFailure.timedOut
	}
}
#endif
