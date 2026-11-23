import ChromiumBridge
import CoreGraphics
import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

/// ABI48 extension actions (DEV-828) and document types (DEV-819).
@MainActor
@Suite(.serialized)
internal struct ChromiumPageActionsTests {
	fileprivate static var calls: [(page: UInt64, id: String, x: Double, y: Double)] = []
	fileprivate static var status: ArxExtensionActionRunStatus = ARX_EXTENSION_ACTION_RUN_POPUP
	fileprivate static var documentType: ArxPageDocumentType = ARX_PAGE_DOCUMENT_NONE

	private static let extensionID: String = "abcdefghijklmnopabcdefghijklmnop"

	private func actions() -> ChromiumPageActions {
		Self.calls = []
		var api = ArxEngineAPI()
		api.run_extension_action = { page, id, x, y in
			MainActor.assumeIsolated {
				ChromiumPageActionsTests.calls.append((page, String(cString: id!), x, y))
				return ChromiumPageActionsTests.status
			}
		}
		api.page_document_type = { _ in
			MainActor.assumeIsolated { ChromiumPageActionsTests.documentType }
		}
		return .init(api: api)
	}

	@Test
	internal func runsWithThePageIDAndScreenPoint() throws {
		let actions = actions()
		Self.status = ARX_EXTENSION_ACTION_RUN_POPUP
		let run = try actions.runExtensionAction(page: 4, extensionID: Self.extensionID, at: CGPoint(x: 120, y: 840.5))
		expectNoDifference(run, .popup)
		#expect(Self.calls.count == 1)
		#expect(Self.calls.first?.page == 4)
		#expect(Self.calls.first?.id == Self.extensionID)
		#expect(Self.calls.first?.x == 120)
		#expect(Self.calls.first?.y == 840.5)
	}

	@Test(arguments: [
		(ARX_EXTENSION_ACTION_RUN_CLICKED, Result<ChromiumExtensionActionRun, ChromiumExtensionActionFailure>.success(.clicked)),
		(ARX_EXTENSION_ACTION_RUN_UNAVAILABLE, .failure(.unavailable)),
		(ARX_EXTENSION_ACTION_RUN_INVALID, .failure(.invalid)),
		(ARX_EXTENSION_ACTION_RUN_REFUSED, .failure(.refused)),
		(ArxExtensionActionRunStatus(rawValue: 99), .failure(.unavailable)),
	])
	internal func statusesMap(
		_ status: ArxExtensionActionRunStatus,
		_ expected: Result<ChromiumExtensionActionRun, ChromiumExtensionActionFailure>
	) {
		let actions = actions()
		Self.status = status
		let result = Result { () throws(ChromiumExtensionActionFailure) in
			try actions.runExtensionAction(page: 1, extensionID: Self.extensionID, at: .zero)
		}
		expectNoDifference(result, expected)
	}

	@Test
	internal func invalidIDsAndPointsNeverReachNative() {
		let actions = actions()
		for (id, point) in [
			("short", CGPoint.zero),
			("ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP", .zero),
			("qrstuvwxyzqrstuvwxyzqrstuvwxyzqr", .zero),
			(Self.extensionID, CGPoint(x: CGFloat.nan, y: 0)),
			(Self.extensionID, CGPoint(x: 0, y: CGFloat.infinity)),
		] {
			#expect(throws: ChromiumExtensionActionFailure.invalid) {
				try actions.runExtensionAction(page: 1, extensionID: id, at: point)
			}
		}
		#expect(Self.calls.isEmpty)
	}

	@Test
	internal func anEngineWithoutTheEntriesIsUnavailable() {
		let actions = ChromiumPageActions(api: ArxEngineAPI())
		#expect(!actions.supportsExtensionActions)
		#expect(!actions.supportsDocumentTypes)
		#expect(throws: ChromiumExtensionActionFailure.unavailable) {
			try actions.runExtensionAction(page: 1, extensionID: Self.extensionID, at: .zero)
		}
		#expect(actions.documentType(page: 1) == nil)
	}

	@Test
	internal func documentTypesMap() {
		let actions = actions()
		Self.documentType = ARX_PAGE_DOCUMENT_PDF
		#expect(actions.documentType(page: 1) == .pdf)
		Self.documentType = ARX_PAGE_DOCUMENT_WEB
		#expect(actions.documentType(page: 1) == .web)
		Self.documentType = ARX_PAGE_DOCUMENT_NONE
		#expect(actions.documentType(page: 1) == nil)
		Self.documentType = ArxPageDocumentType(rawValue: 7)
		#expect(actions.documentType(page: 1) == nil)
	}
}
