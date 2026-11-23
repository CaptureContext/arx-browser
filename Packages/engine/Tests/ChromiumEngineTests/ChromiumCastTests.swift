import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-927: the Cast picker's reports and the app's answers reach only their own page.
@MainActor
@Suite(.serialized)
internal struct ChromiumCastTests {
	@Test
	internal func picksDecodeFromTheEnginesJSON() throws {
		let json = Data("""
		{"source":"youtube.com","presentation":true,"permissionRejected":false,
		 "devices":[{"id":"cast:1","name":"Living Room","state":"connected","icon":"cast",
		             "modes":[1,2],"status":"YouTube","route":"route-1"},
		            {"id":"dial:2","name":"TV","state":"available","icon":"generic","modes":[]}]}
		""".utf8)
		let picker = try JSONDecoder().decode(ChromiumCastPicker.self, from: json)

		#expect(picker.source == "youtube.com")
		#expect(picker.presentation)
		#expect(picker.devices.map(\.id) == ["cast:1", "dial:2"])
		#expect(picker.devices[0].route == "route-1")
		#expect(picker.devices[0].modes == [1, 2])
		#expect(picker.devices[1].status == nil)
	}

	@Test
	internal func reportsReachTheirPageAndCloseUnreadablePickers() throws {
		let fixture = CastFixture()
		let page = try fixture.runtime.makePage()
		let reports = CastReports()
		fixture.runtime.observeCastPickers(menuTitle: "Cast…") { page, picker in
			reports.values.append((page.identifier, picker))
		}

		#expect(CastFixture.menuTitles == ["Cast…"])
		fixture.runtime.castPickerChanged(page.identifier, json: Data(#"{"source":"","presentation":false,"permissionRejected":true,"devices":[]}"#.utf8))
		fixture.runtime.castPickerChanged(page.identifier, json: nil)
		fixture.runtime.castPickerChanged(404, json: nil)
		withKnownIssue("A malformed reply from the bridge is reported") {
			fixture.runtime.castPickerChanged(page.identifier, json: Data("not json".utf8))
		}

		#expect(reports.values.map(\.0) == [page.identifier, page.identifier])
		#expect(reports.values[0].1?.permissionRejected == true)
		#expect(reports.values[1].1 == nil)
		#expect(CastFixture.closed == [page.identifier])
	}

	@Test
	internal func answersReachOnlyTheirOwnPage() throws {
		let fixture = CastFixture()
		let page = try fixture.runtime.makePage()

		#expect(fixture.runtime.supportsCasting)
		#expect(fixture.runtime.showCastPicker(on: page))
		#expect(fixture.runtime.chooseCastDevice("cast:1", mode: 2, on: page))
		#expect(fixture.runtime.chooseCastDevice("cast:1", mode: nil, on: page))
		#expect(fixture.runtime.stopCasting(route: "route-1", on: page))
		fixture.runtime.closeCastPicker(on: page)

		#expect(CastFixture.shown == [page.identifier])
		#expect(CastFixture.chosen.map(\.device) == ["cast:1", "cast:1"])
		#expect(CastFixture.chosen.map(\.mode) == [2, 0])
		#expect(CastFixture.stopped == ["route-1"])
		#expect(CastFixture.closed == [page.identifier])
	}

	@Test
	internal func stoppingObservationClearsTheEnginesHandler() throws {
		let fixture = CastFixture()
		fixture.runtime.observeCastPickers(menuTitle: "Cast…") { _, _ in }
		fixture.runtime.observeCastPickers(menuTitle: "Cast…", nil)

		#expect(CastFixture.handlerSet == [true, false])
	}

	@Test
	internal func olderEnginesCastNothing() throws {
		let fixture = CastFixture(supportsCasting: false)
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsCasting)
		#expect(!fixture.runtime.showCastPicker(on: page))
		#expect(!fixture.runtime.chooseCastDevice("cast:1", mode: nil, on: page))
		#expect(CastFixture.shown.isEmpty)
	}
}

@MainActor
private final class CastReports {
	fileprivate var values: [(UInt64, ChromiumCastPicker?)] = []
}

@MainActor
private final class CastFixture {
	fileprivate static var nextPage: UInt64 = 1
	fileprivate static var shown: [UInt64] = []
	fileprivate static var chosen: [(device: String, mode: Int32)] = []
	fileprivate static var stopped: [String] = []
	fileprivate static var closed: [UInt64] = []
	fileprivate static var menuTitles: [String] = []
	fileprivate static var handlerSet: [Bool] = []
	fileprivate static let view: NSView = .init()
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(supportsCasting: Bool = true) {
		Self.nextPage = 1
		Self.shown = []
		Self.chosen = []
		Self.stopped = []
		Self.closed = []
		Self.menuTitles = []
		Self.handlerSet = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				defer { CastFixture.nextPage += 1 }
				return CastFixture.nextPage
			}
		}
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { CastFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.history_count = { _ in 0 }
		runtime = ChromiumRuntime(api: api)
		if supportsCasting {
			runtime.optionalExports.cast = .init(
				setHandler: { handler, _, title in
					let title = title.map { String(cString: $0) }
					MainActor.assumeIsolated {
						CastFixture.handlerSet.append(handler != nil)
						if let title { CastFixture.menuTitles.append(title) }
					}
				},
				show: { page in
					MainActor.assumeIsolated { CastFixture.shown.append(page) }
					return true
				},
				choose: { _, device, mode in
					let device = device.map { String(cString: $0) } ?? ""
					MainActor.assumeIsolated { CastFixture.chosen.append((device, mode)) }
					return true
				},
				stop: { _, route in
					let route = route.map { String(cString: $0) } ?? ""
					MainActor.assumeIsolated { CastFixture.stopped.append(route) }
					return true
				},
				close: { page in
					MainActor.assumeIsolated { CastFixture.closed.append(page) }
				}
			)
		}
		runtime.didBecomeReady()
	}
}
