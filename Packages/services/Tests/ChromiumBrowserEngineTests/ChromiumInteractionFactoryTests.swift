import AppKit
import BrowserCore
import ChromiumBridge
import CustomDump
import Foundation
import Testing
import _TestSupport

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumInteractionFactoryTests {
	@Test
	internal func retainedFactoryTracksReadinessAndRejectsPrivateOrDisposedSessions() async throws {
		NativeInteractionFixture.calls = 0
		var api = ArxEngineAPI()
		api.inspect_page = { _, _, _, _ in }
		api.validate_inspection_reference = { _, _, _, _, _ in }
		api.inspection_document_is_current = { _, _, _ in true }
		api.cancel_inspection = { _ in }
		api.revoke_inspection_scope = { _ in }
		api.click_inspection_reference = { _, _, _, _, _, _, _ in
			MainActor.assumeIsolated { NativeInteractionFixture.calls += 1 }
		}
		api.cancel_reference_click = { _ in }
		api.page_close_generation = { _ in 8 }
		api.prepare_private_profile = { _ in true }
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { NativeInteractionFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.navigate = { _, _ in true }
		api.destroy_page = { _ in }

		let runtime = ChromiumRuntime(api: api)
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: .init(rawValue: UUID(0)))
		let client = engine.interaction
		let inspection = Self.inspection
		let request = AutomationClickRequest(
			operationID: UUID(),
			targetID: inspection.request.targetID,
			expectedRevision: inspection.request.expectedRevision,
			snapshotID: inspection.snapshot.snapshotID,
			reference: "opaque"
		)
		let authorize: @MainActor @Sendable () -> Bool = {
			Issue.record("Rejected source reached final dispatch authorization")
			return true
		}
		#expect(!client.isAvailable())
		let result1 = await client.clickAuthorized(request, inspection, authorize)
		expectNoDifference(result1.failure, .unsupported)

		runtime.didBecomeReady()
		#expect(client.isAvailable())
		let result2 = await client.clickAuthorized(request, inspection, authorize)
		expectNoDifference(result2.failure, .staleReference)
		try runtime.preparePrivateProfile(inspection.source.profileID.rawValue)
		try await engine.client.open(.init(
			id: inspection.source.tabID,
			profileID: inspection.source.profileID,
			restoration: .init(title: "Private fixture", url: URL(string: "https://fixture.invalid")!)
		))
		expectNoDifference(engine.client.snapshot(inspection.source.tabID)?.revision, inspection.source.sessionRevision)
		expectNoDifference(engine.client.snapshot(inspection.source.tabID)?.documentRevision, inspection.source.documentRevision)
		let result3 = await client.clickAuthorized(request, inspection, authorize)
		expectNoDifference(result3.failure, .staleReference)

		engine.closeAll()
		let result4 = await client.clickAuthorized(request, inspection, authorize)
		expectNoDifference(result4.failure, .staleReference)
		runtime.finish()
		#expect(!client.isAvailable())
		let result5 = await client.clickAuthorized(request, inspection, authorize)
		expectNoDifference(result5.failure, .unsupported)
		expectNoDifference(NativeInteractionFixture.calls, 0)
	}

	@Test
	internal func absentTableDoesNotAdvertiseActivationAfterReadiness() {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		let engine = ChromiumBrowserEngine(runtime: runtime, profileID: .init(rawValue: UUID(0)))
		let client = engine.interaction
		runtime.didBecomeReady()
		defer { runtime.finish() }
		#expect(!client.isAvailable())
	}

	private static var inspection: AutomationInspectionResult {
		.init(
			request: .init(targetID: UUID(3), expectedRevision: String(repeating: "a", count: 64)),
			source: .init(
				tabID: .init(rawValue: UUID(3)),
				profileID: .init(rawValue: UUID(4)),
				sessionRevision: 1,
				documentRevision: 8,
				scopeID: UUID(99)
			),
			snapshot: .init(
				snapshotID: "snapshot",
				documentID: "document",
				frameID: "frame",
				domVersion: "4",
				nodes: [.init(index: 0, role: "button", reference: "opaque")],
				omissions: PageInspectionOmission.allCases
			)
		)
	}
}

@MainActor
private enum NativeInteractionFixture {
	fileprivate static var calls: Int = 0
	fileprivate static let view: NSView = .init()
}
