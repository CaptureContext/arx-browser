import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-824 follow-up: a page's action icon is copied from the engine's export once its size is
/// known; an engine built before the export, or an icon that changes between the calls, gives none.
@MainActor
@Suite(.serialized)
internal struct ChromiumExtensionActionIconTests {
	private static let extensionID = String(repeating: "a", count: 32)

	@Test
	internal func copiesTheIconOnceItsSizeIsKnown() throws {
		ActionIconExport.reset(png: Data([0x89, 0x50, 0x4E, 0x47]))
		let icon = ChromiumRuntime.copyExtensionActionIcon(
			ActionIconExport.copy,
			page: 7,
			extensionID: Self.extensionID,
			scale: 2
		)

		#expect(icon == Data([0x89, 0x50, 0x4E, 0x47]))
		#expect(ActionIconExport.calls.map(\.page) == [7, 7])
		#expect(ActionIconExport.calls.map(\.extensionID) == [Self.extensionID, Self.extensionID])
		#expect(ActionIconExport.calls.map(\.scale) == [2, 2])
		#expect(ActionIconExport.calls.map(\.capacity) == [0, 4])
	}

	@Test
	internal func anExtensionWithoutASetIconGivesNone() {
		ActionIconExport.reset(png: Data())
		let icon = ChromiumRuntime.copyExtensionActionIcon(
			ActionIconExport.copy,
			page: 7,
			extensionID: Self.extensionID,
			scale: 1
		)

		#expect(icon == nil)
		#expect(ActionIconExport.calls.count == 1)
	}

	@Test
	internal func anIconThatChangesBetweenTheCallsOrIsTooLargeGivesNone() {
		ActionIconExport.reset(png: Data([1, 2, 3, 4]), then: Data([1, 2]))
		#expect(
			ChromiumRuntime.copyExtensionActionIcon(
				ActionIconExport.copy,
				page: 7,
				extensionID: Self.extensionID,
				scale: 2
			) == nil
		)

		ActionIconExport.reset(png: Data([1, 2]), then: Data([1, 2, 3, 4]))
		#expect(
			ChromiumRuntime.copyExtensionActionIcon(
				ActionIconExport.copy,
				page: 7,
				extensionID: Self.extensionID,
				scale: 2
			) == nil
		)

		ActionIconExport.reset(reportedSize: ChromiumRuntime.maximumExtensionActionIconBytes + 1)
		#expect(
			ChromiumRuntime.copyExtensionActionIcon(
				ActionIconExport.copy,
				page: 7,
				extensionID: Self.extensionID,
				scale: 2
			) == nil
		)
		#expect(ActionIconExport.calls.count == 1)
	}

	@Test
	internal func anOpenPageReadsTheExportAndAnOlderEngineGivesNone() throws {
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { ActionIconExport.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let page = try runtime.makePage()

		ActionIconExport.reset(png: Data([1, 2]))
		#expect(runtime.extensionActionIcon(Self.extensionID, on: page, scale: 2) == nil)

		runtime.optionalExports.extensionActionIcon = ActionIconExport.copy
		#expect(runtime.extensionActionIcon(Self.extensionID, on: page, scale: 3) == nil)
		#expect(runtime.extensionActionIcon("not-an-id", on: page, scale: 2) == nil)
		#expect(ActionIconExport.calls.isEmpty)

		#expect(runtime.extensionActionIcon(Self.extensionID, on: page, scale: 1) == Data([1, 2]))
		#expect(ActionIconExport.calls.map(\.page) == [page.id, page.id])
		#expect(ActionIconExport.calls.map(\.scale) == [1, 1])
	}
}

/// A stand-in for the engine's export: a C function can't capture, so it reads shared state.
@MainActor
private enum ActionIconExport {
	struct Call {
		var page: UInt64
		var extensionID: String
		var scale: Float
		var capacity: Int
	}

	static var view: NSView = .init()
	static var answers: [Data] = []
	static var reportedSize: Int?
	static var calls: [Call] = []

	static func reset(
		png: Data = .init(),
		then later: Data? = nil,
		reportedSize: Int? = nil
	) {
		answers = [png, later ?? png]
		self.reportedSize = reportedSize
		calls = []
	}

	nonisolated static let copy: ChromiumExtensionActionIconFunction = { page, extensionID, scale, buffer, capacity in
		let call = Call(
			page: page,
			extensionID: extensionID.map { String(cString: $0) } ?? "",
			scale: scale,
			capacity: capacity
		)
		let (png, reportedSize) = MainActor.assumeIsolated { ActionIconExport.record(call) }
		if let reportedSize { return reportedSize }

		if let buffer, capacity >= png.count, !png.isEmpty {
			png.copyBytes(to: buffer, count: png.count)
		}
		return png.count
	}

	/// Records a call and answers the PNG it gets, the first answer then the second.
	private static func record(_ call: Call) -> (png: Data, reportedSize: Int?) {
		let png = answers[min(calls.count, 1)]
		calls.append(call)
		return (png, reportedSize)
	}
}
