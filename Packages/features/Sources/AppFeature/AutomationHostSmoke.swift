#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Exercises MCP Peek and Little Arx openings and every promotion through the bundled helper,
/// only inside the caller's disposable spaces.
@MainActor
internal enum AutomationHostSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		session: AutomationSmokeSession,
		profileID: Profile.ID,
		sourceSpace: Space.ID,
		destinationSpace: Space.ID,
		url: URL
	) async throws {
		guard
			sourceSpace != destinationSpace,
			store.workspace.spaces[id: sourceSpace]?.profileID == profileID,
			store.workspace.spaces[id: destinationSpace]?.profileID == profileID,
			store.peeks.isEmpty,
			store.littleWindows.isEmpty
		else { throw stage("setup") }

		let context = Context(store: store, engine: engine, session: session, url: url)
		var promoted: [UUID] = []

		// Little Arx opens outside the workspace, then promotes into an explicit destination.
		let littleTab = try await context.openLittleArx(in: sourceSpace)
		promoted.append(try await context.promoteLittleArx(littleTab, to: destinationSpace))

		// Peek borrows an explicit source pane; it never selects the user's focused tab implicitly.
		let sourceTab = try await context.openTab(in: sourceSpace)
		try await context.present(sourceTab, space: sourceSpace)
		try await context.refuseBackgroundPeek(source: sourceTab)
		let peekTab = try await context.openPeek(source: sourceTab)
		promoted.append(try await context.promotePeekToTab(
			peekTab,
			source: sourceTab,
			space: sourceSpace
		))

		try await context.present(sourceTab, space: sourceSpace)
		let secondPeek = try await context.openPeek(source: sourceTab)
		let littleFromPeek = try await context.promotePeekToLittleArx(
			secondPeek,
			source: sourceTab,
			space: sourceSpace
		)
		promoted.append(try await context.promoteLittleArx(littleFromPeek, to: destinationSpace))

		guard
			store.peeks.isEmpty,
			store.littleWindows.isEmpty,
			case let .inventory(inventory) = try await session.inventory(),
			inventory.presentations.isEmpty
		else { throw stage("settled") }

		for id in promoted + [sourceTab] {
			try await context.close(id)
		}

		print("ARX_MCP_HOST_NATIVE_SMOKE_SUCCESS")
	}

	/// The item with `id` in an inventory reply, or why there's none, without IDs or page text:
	/// the reply wasn't an inventory, it came in pages, or the item isn't in it (DEV-1191 follow-up,
	/// engine batch 7 saw a bare `inventory` stage).
	internal static func lookUp(
		_ id: UUID,
		in reply: AutomationResult
	) -> Result<AutomationInventoryItem, InventoryMiss> {
		guard case let .inventory(inventory) = reply else {
			if case let .failure(failure) = reply { return .failure(.failed(failure.rawValue)) }
			return .failure(.notInventory)
		}
		guard inventory.nextCursor == nil else { return .failure(.paged(items: inventory.items.count)) }
		guard let item = inventory.items.first(where: { $0.id == id }) else {
			let kinds = Dictionary(grouping: inventory.items, by: \.kind.rawValue).mapValues(\.count)
			return .failure(.missing(kinds: kinds))
		}

		return .success(item)
	}

	internal enum InventoryMiss: Error, Equatable, CustomStringConvertible {
		case failed(String)
		case notInventory
		case paged(items: Int)

		/// The listed items by kind.
		case missing(kinds: [String: Int])

		internal var description: String {
			switch self {
			case let .failed(failure): "failure=\(failure)"
			case .notInventory: "reply=notInventory"
			case let .paged(items): "paged items=\(items)"
			case let .missing(kinds):
				"missing items=" + kinds.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
			}
		}
	}

	fileprivate static func stage(
		_ name: String,
		reply: AutomationResult? = nil,
		expectedTabID: UUID? = nil
	) -> AutomationSmokeFailure {
		// Stage labels and reply codes are value-free; they locate a failed assertion in app-smoke logs.
		let outcome: String = switch reply {
		case let .failure(failure): " failure=\(failure.rawValue)"
		case let .command(result): " status=\(result.status.rawValue) sameTab=\(result.targetID == expectedTabID)"
		default: ""
		}

		// Stderr is unbuffered, so the label survives a teardown watchdog termination.
		FileHandle.standardError.write(Data("ARX_MCP_HOST_SMOKE_FAILED_STAGE \(name)\(outcome)\n".utf8))
		return .hostMismatch
	}
}

@MainActor
private struct Context {
	private let title: String
	fileprivate let store: StoreOf<AppFeature>
	fileprivate let engine: ChromiumBrowserEngine
	fileprivate let session: AutomationSmokeSession
	fileprivate let url: URL

	fileprivate init(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		session: AutomationSmokeSession,
		url: URL
	) {
		self.store = store
		self.engine = engine
		self.session = session
		self.url = url
		self.title = "Arx MCP excluded"
	}

	// MARK: - Little Arx

	fileprivate func openLittleArx(in spaceID: Space.ID) async throws -> AutomationPresentation {
		let space = try await item(spaceID.rawValue)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .openLittleArx,
			targetID: space.id,
			expectedRevision: space.revision,
			url: url,
			focus: true
		)
		let presentation = try await accepted(command, kind: .littleArx, stage: "openLittleArx")
		guard
			let little = store.littleWindows.first(where: { $0.tab.id.rawValue == presentation.tabID }),
			little.tab.profileID.rawValue == presentation.profileID,
			little.tab.automationClientID != nil,
			!store.workspace.tabs.contains(where: { $0.id.rawValue == presentation.tabID })
		else { throw AutomationHostSmoke.stage("littleArxHost") }

		guard try await session.command(command) == .failure(.duplicateOperation)
		else { throw AutomationHostSmoke.stage("littleArxReplay") }

		return try await loaded(presentation, promotionTarget: spaceID.rawValue)
	}

	fileprivate func promoteLittleArx(
		_ presentation: AutomationPresentation,
		to spaceID: Space.ID
	) async throws -> UUID {
		let destination = try await item(spaceID.rawValue)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .promoteLittleArx,
			targetID: destination.id,
			expectedRevision: destination.revision,
			focus: true,
			presentationID: presentation.id,
			presentationRevision: presentation.revision
		)
		let snapshot = engine.client.snapshot(.init(rawValue: presentation.tabID))
		try await committed(command, tabID: presentation.tabID, stage: "promoteLittleArx")
		let promotedSnapshot = engine.client.snapshot(.init(rawValue: presentation.tabID))
		guard
			!store.littleWindows.contains(where: { $0.tab.id.rawValue == presentation.tabID }),
			let space = store.workspace.spaces[id: spaceID],
			space.unpinnedTabs.contains(.init(rawValue: presentation.tabID)),
			snapshot != nil,
			promotedSnapshot?.navigation.url == snapshot?.navigation.url
		else { throw AutomationHostSmoke.stage("littleArxPromoted") }

		guard try await session.command(command) == .failure(.duplicateOperation)
		else { throw AutomationHostSmoke.stage("promoteLittleArxReplay") }

		return presentation.tabID
	}

	// MARK: - Peek

	fileprivate func refuseBackgroundPeek(source: UUID) async throws {
		let item = try await item(source)
		let background = AutomationCommand(
			operationID: UUID(),
			action: .openPeek,
			targetID: item.id,
			expectedRevision: item.revision,
			url: url,
			sourceTabID: item.id,
			sourceRevision: item.revision
		)
		guard
			try await session.command(background, validatesLocally: false) == .failure(.unsupported),
			store.peeks.isEmpty
		else { throw AutomationHostSmoke.stage("backgroundPeek") }
	}

	fileprivate func openPeek(source: UUID) async throws -> AutomationPresentation {
		let item = try await item(source)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .openPeek,
			targetID: item.id,
			expectedRevision: item.revision,
			url: url,
			focus: true,
			sourceTabID: item.id,
			sourceRevision: item.revision
		)
		let presentation = try await accepted(command, kind: .peek, stage: "openPeek")
		guard
			let peek = store.peeks.first(where: { $0.tab.id.rawValue == presentation.tabID }),
			peek.isTemporary,
			peek.source.tabID?.rawValue == source,
			presentation.sourceTargetID == source
		else { throw AutomationHostSmoke.stage("peekHost") }

		return try await loaded(presentation, promotionTarget: source)
	}

	fileprivate func promotePeekToTab(
		_ presentation: AutomationPresentation,
		source: UUID,
		space spaceID: Space.ID
	) async throws -> UUID {
		let item = try await item(source)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .promotePeekToTab,
			targetID: item.id,
			expectedRevision: item.revision,
			focus: true,
			presentationID: presentation.id,
			presentationRevision: presentation.revision
		)
		try await committed(command, tabID: presentation.tabID, stage: "promotePeekToTab")
		guard
			!store.peeks.contains(where: { $0.tab.id.rawValue == presentation.tabID }),
			let space = store.workspace.spaces[id: spaceID],
			space.unpinnedTabs.contains(.init(rawValue: presentation.tabID)),
			engine.client.snapshot(.init(rawValue: presentation.tabID))?.navigation.url == url
		else { throw AutomationHostSmoke.stage("peekPromoted") }

		return presentation.tabID
	}

	fileprivate func promotePeekToLittleArx(
		_ presentation: AutomationPresentation,
		source: UUID,
		space spaceID: Space.ID
	) async throws -> AutomationPresentation {
		let item = try await item(source)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .promotePeekToLittleArx,
			targetID: item.id,
			expectedRevision: item.revision,
			focus: true,
			presentationID: presentation.id,
			presentationRevision: presentation.revision
		)
		let little = try await accepted(command, kind: .littleArx, stage: "promotePeekToLittleArx")
		guard
			little.tabID == presentation.tabID,
			little.id != presentation.id,
			store.peeks.isEmpty,
			store.littleWindows.contains(where: { $0.tab.id.rawValue == presentation.tabID })
		else { throw AutomationHostSmoke.stage("peekLittleArx") }

		return try await loaded(little, promotionTarget: spaceID.rawValue)
	}

	// MARK: - Workspace

	fileprivate func openTab(in spaceID: Space.ID) async throws -> UUID {
		let space = try await item(spaceID.rawValue)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .openTab,
			targetID: space.id,
			expectedRevision: space.revision,
			url: url
		)
		guard
			case let .command(result) = try await session.command(command),
			result.status == .acceptedLoading,
			let id = result.targetID
		else { throw AutomationHostSmoke.stage("openTab") }

		try await poll("openTabLoaded") { isLoaded(id) }
		return id
	}

	/// Shows the tab in the destination space's own active pane; pane identities are per space layout.
	fileprivate func present(
		_ id: UUID,
		space: Space.ID
	) async throws {
		store.send(.main(.sidebar(.ui(.spaceSelected(space)))))
		try await poll("spaceSelected") {
			store.main.sidebar.spaceID == space && store.main.viewer.spaceID == space
		}
		store.send(.main(.present(.init(rawValue: id), in: store.main.viewer.activePaneID)))
		try await poll("present") {
			store.main.viewer.item.tab?.id.rawValue == id
		}
	}

	fileprivate func close(_ id: UUID) async throws {
		let target = try await item(id)
		let command = AutomationCommand(
			operationID: UUID(),
			action: .closeTab,
			targetID: target.id,
			expectedRevision: target.revision
		)
		try await committed(command, tabID: id, stage: "close")
	}

	// MARK: - Receipts

	private func accepted(
		_ command: AutomationCommand,
		kind: AutomationPresentation.Kind,
		stage: String
	) async throws -> AutomationPresentation {
		guard
			case let .command(result) = try await session.command(command),
			result.operationID == command.operationID,
			result.status == .acceptedLoading,
			let presentation = result.presentation,
			presentation.kind == kind,
			presentation.revision.utf8.count == 64
		else { throw AutomationHostSmoke.stage(stage) }

		return presentation
	}

	private func committed(
		_ command: AutomationCommand,
		tabID: UUID,
		stage: String
	) async throws {
		let reply = try await session.command(command)
		guard
			case let .command(result) = reply,
			result.operationID == command.operationID,
			result.status == .committed,
			result.targetID == tabID,
			result.presentation == nil
		else { throw AutomationHostSmoke.stage(stage, reply: reply, expectedTabID: tabID) }
	}

	/// Waits for the hosted page and a settled presentation revision, then proves that a
	/// revision other than the current one is refused.
	///
	/// The opening receipt can already describe the loaded document when the page commits
	/// before the receipt is built, so the revision is not required to move; when it did move,
	/// the original pre-load revision is probed as well.
	///
	/// - Parameters:
	///   - promotionTarget: A valid target for the stale promotion probe: the Peek source tab or a space.
	private func loaded(
		_ presentation: AutomationPresentation,
		promotionTarget: UUID
	) async throws -> AutomationPresentation {
		try await poll("presentationLoaded") { isLoaded(presentation.tabID) }

		var current: AutomationPresentation?
		var previous: String?
		try await poll("presentationSettled \(presentation.kind.rawValue)") {
			guard case let .inventory(inventory) = try await session.inventory()
			else { return false }

			guard let fresh = inventory.presentations.first(where: { $0.id == presentation.id }) else {
				previous = nil
				return false
			}

			defer { previous = fresh.revision }
			guard fresh.revision == previous, isLoaded(presentation.tabID)
			else { return false }

			current = fresh
			return true
		}
		guard let current else { throw AutomationHostSmoke.stage("presentationSettled") }

		var outdated = [String(repeating: "0", count: 64)]
		if presentation.revision != current.revision { outdated.append(presentation.revision) }

		for revision in outdated {
			let stale = AutomationCommand(
				operationID: UUID(),
				action: presentation.kind == .peek ? .promotePeekToTab : .promoteLittleArx,
				targetID: promotionTarget,
				expectedRevision: try await item(promotionTarget).revision,
				focus: true,
				presentationID: presentation.id,
				presentationRevision: revision
			)
			let reply = try await session.command(stale)
			guard reply == .failure(.staleTarget)
			else { throw AutomationHostSmoke.stage("stalePresentation", reply: reply) }
		}

		return current
	}

	private func isLoaded(_ id: UUID) -> Bool {
		guard let snapshot = engine.client.snapshot(.init(rawValue: id)) else { return false }
		return snapshot.navigation.url == url
		&& snapshot.navigation.title == title
		&& !snapshot.navigation.isLoading
		&& snapshot.navigation.errorCode == nil
		&& snapshot.documentRevision != nil
	}

	private func item(
		_ id: UUID,
		function: StaticString = #function
	) async throws -> AutomationInventoryItem {
		let reply = try await session.inventory()
		switch AutomationHostSmoke.lookUp(id, in: reply) {
		case let .success(item):
			return item
		case let .failure(miss):
			// Whether the workspace has it tells a grant that hides it from a store that hasn't
			// published it yet.
			let inWorkspace = store.workspace.tabs.ids.contains(.init(rawValue: id))
				|| store.workspace.spaces.ids.contains(.init(rawValue: id))
			throw AutomationHostSmoke.stage("inventory for=\(function) \(miss) inWorkspace=\(inWorkspace)")
		}
	}

	private func poll(
		_ stage: String,
		until condition: () async throws -> Bool
	) async throws {
		for _ in 0..<100 {
			if try await condition() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw AutomationHostSmoke.stage(stage)
	}
}
#endif
