#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

extension AutomationScrollSmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		session: AutomationSmokeSession,
		source: BrowserCore.Tab,
		snapshot: AutomationInspectionSmoke.Snapshot,
		refreshSnapshot: @MainActor () async throws -> AutomationInspectionSmoke.Snapshot,
		evidenceURL: URL,
		excluded: [BrowserCore.Tab]
	) async throws {
		func freshTarget() async throws -> AutomationClickRequest {
			let snapshot = try await refreshSnapshot()
			return try AutomationClickSmoke.request(for: snapshot, name: "Arx scroll anchor")
		}

		func submit(
			_ request: AutomationScrollRequest,
			expecting disposition: AutomationScrollDisposition
		) async throws {
			let result = try await approvedScroll(
				request,
				session: session,
				store: store,
				engine: engine,
				approve: true
			)
			try require(result, disposition)
		}

		let focusedWindow = store.focusedWindowID
		let focusedPane = store.main.viewer.activePaneID
		let nativeWindow = NSApp.keyWindow
		let document = engine.client.snapshot(source.id)?.documentRevision
		let baseline = try await evidence(at: evidenceURL) { value in
			value.matches() && value.events == 0
		}
		var request = AutomationScrollRequest(
			target: try AutomationClickSmoke.request(for: snapshot, name: "Arx scroll anchor"),
			axis: .vertical,
			deltaCSSPixels: 120.5
		)
		for tab in excluded {
			var foreign = request
			foreign.target.operationID = UUID()
			foreign.target.targetID = tab.id.rawValue
			let before = engine.client.snapshot(tab.id)
			let denied = try await session.scroll(foreign)
			guard
				denied.disposition == .notDispatched,
				denied.failure == .denied,
				engine.client.snapshot(tab.id) == before
			else { throw AutomationSmokeFailure.authorizationFailed }
		}
		let declined = try await approvedScroll(
			request,
			session: session,
			store: store,
			engine: engine,
			approve: false
		)
		guard declined.disposition == .notDispatched, declined.failure == .approvalDeclined
		else { throw AutomationSmokeFailure.authorizationFailed }
		_ = try await evidence(at: evidenceURL, after: baseline.sample + 1) { value in
			value.matches() && value.events == 0
		}
		print("ARX_MCP_SCROLL_PHASE_SCOPE_AND_APPROVAL_DENIED")

		request.target.operationID = UUID()
		try await submit(request, expecting: .dispatched)
		let vertical = try await evidence(at: evidenceURL) { value in
			value.matches(["innerY": 120.5]) && value.events > 0
		}
		print("ARX_MCP_SCROLL_PHASE_VERTICAL_VERIFIED")

		var consumed = request
		consumed.target.operationID = UUID()
		let consumedResult = try await approvedScroll(
			consumed,
			session: session,
			store: store,
			engine: engine,
			approve: true
		)
		try require(consumedResult, .notDispatched, failure: .staleReference)
		print("ARX_MCP_SCROLL_PHASE_CONSUMED_REFERENCE_DENIED")

		request.target = try await freshTarget()
		request.axis = .horizontal
		try await submit(request, expecting: .dispatched)
		let horizontal = try await evidence(at: evidenceURL, after: vertical.sample) {
			$0.matches(["innerY": 120.5, "outerX": 120.5]) && $0.events > vertical.events
		}
		print("ARX_MCP_SCROLL_PHASE_AXIS_VERIFIED")

		request.target = try await freshTarget()
		request.axis = .vertical
		request.deltaCSSPixels = 8192
		try await submit(request, expecting: .dispatched)
		let edge = try await evidence(at: evidenceURL, after: horizontal.sample) {
			$0.innerAtEnd
			&& ($0.offsets["innerY"] ?? 0) > 120.5
			&& $0.matches(["innerY": $0.offsets["innerY"] ?? 0, "outerX": 120.5])
			&& $0.events > horizontal.events
		}
		request.target = try await freshTarget()
		try await submit(request, expecting: .unchanged)
		try require(await session.scroll(request), .unchanged, failure: .duplicateOperation)
		var changed = request
		changed.axis = .horizontal
		try require(
			await session.scroll(changed),
			.possiblyDispatched,
			failure: .duplicateOperation
		)
		changed = request
		changed.deltaCSSPixels = -120.5
		try require(
			await session.scroll(changed),
			.possiblyDispatched,
			failure: .duplicateOperation
		)
		_ = try await evidence(at: evidenceURL, after: edge.sample + 2) {
			$0.innerAtEnd && $0.offsets == edge.offsets && $0.events == edge.events
		}
		print("ARX_MCP_SCROLL_PHASE_EDGE_AND_REPLAY_VERIFIED")

		guard
			store.focusedWindowID == focusedWindow,
			store.main.viewer.activePaneID == focusedPane,
			NSApp.keyWindow === nativeWindow,
			store.main.viewer.item.tab?.id == source.id,
			store.workspace.tabs[id: source.id]?.profileID == source.profileID,
			document != nil,
			engine.client.snapshot(source.id)?.documentRevision == document
		else { throw AutomationSmokeFailure.scrollMismatch }
	}

	internal static func require(
		_ result: AutomationScrollResult,
		_ disposition: AutomationScrollDisposition,
		failure: AutomationFailure? = nil
	) throws {
		guard result.disposition == disposition, result.failure == failure
		else { throw AutomationSmokeFailure.scrollMismatch }
	}
}
#endif
