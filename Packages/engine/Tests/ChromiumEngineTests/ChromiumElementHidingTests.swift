import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumEngine

/// DEV-1019: Hide Element's picker and the hidden elements are exports outside the ABI table.
@Suite(.serialized)
@MainActor
internal struct ChromiumElementHidingTests {
	@Test
	internal func olderEnginesNeitherPickNorList() async throws {
		let fixture = ElementHidingFixture(exports: false)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(!fixture.runtime.supportsElementHiding)
		#expect(!fixture.runtime.startElementPicker(on: page))
		#expect(await fixture.runtime.hiddenElements(on: page) == nil)
		#expect(await fixture.runtime.elementPickerStatus(on: page) == nil)
		#expect(!fixture.runtime.showHiddenElement("example.com##.ad", on: page))
		#expect(!fixture.runtime.supportsElementPicker)
		#expect(!fixture.runtime.canHideElements(on: page))
		#expect(!fixture.runtime.hideElement("example.com##.ad", on: page))
		#expect(await fixture.runtime.pickElement(on: page, style: ChromiumElementPickerTests.style()) == .unavailable)
	}

	/// Arx's own picker's line reaches the engine for the page (DEV-1201); asking without one is
	/// asking whether the site would take one. An engine before it still hides with uBlock's.
	@Test(arguments: [false, true])
	internal func thePickedLineReachesTheEngineWhereItExportsIt(hideExport: Bool) throws {
		let fixture = ElementHidingFixture(exports: true, hideExport: hideExport)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(fixture.runtime.supportsElementHiding)
		#expect(fixture.runtime.canHideElements(on: page) == hideExport)
		#expect(fixture.runtime.hideElement("news.example##aside.promo", on: page) == hideExport)
		#expect(ElementHidingFixture.hidden.map(\.filter) == (hideExport ? [nil, "news.example##aside.promo"] : []))
		#expect(ElementHidingFixture.hidden.allSatisfy { $0.page == page.identifier })

		ElementHidingFixture.refuses = true
		#expect(!fixture.runtime.canHideElements(on: page))
		#expect(!fixture.runtime.hideElement("news.example##aside.promo", on: page))
	}

	@Test
	internal func thePickerAndShowReachTheEngineForThePage() throws {
		let fixture = ElementHidingFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		#expect(fixture.runtime.supportsElementHiding)
		#expect(fixture.runtime.startElementPicker(on: page))
		#expect(fixture.runtime.showHiddenElement("example.com##div[data-x=\"1\"]", on: page))
		#expect(ElementHidingFixture.picked == [page.identifier])
		#expect(ElementHidingFixture.shown.map(\.page) == [page.identifier])
		#expect(ElementHidingFixture.shown.map(\.filter) == ["example.com##div[data-x=\"1\"]"])

		ElementHidingFixture.refuses = true
		#expect(!fixture.runtime.startElementPicker(on: page))
	}

	@Test
	internal func hiddenElementsDecodeKeepingOnlyFilterLists() async throws {
		let fixture = ElementHidingFixture(exports: true)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		ElementHidingFixture.json = """
		{"Example.com":["example.com##.ad","","bad\\nline"],"news.example":"not a list",\
		"shop.example":["shop.example##.banner"]}
		"""
		let hidden = try #require(await fixture.runtime.hiddenElements(on: page))
		#expect(hidden.sites == ["example.com": ["example.com##.ad"], "shop.example": ["shop.example##.banner"]])

		ElementHidingFixture.json = "not json"
		#expect(await fixture.runtime.hiddenElements(on: page) == .init())

		ElementHidingFixture.refuses = true
		#expect(await fixture.runtime.hiddenElements(on: page) == nil)
	}

	/// The extensions smoke reads what uBlock made of a picker ask (DEV-1019). An engine built
	/// before that export still picks and lists.
	@Test(arguments: [false, true])
	internal func thePickerStatusIsReadWhereTheEngineExportsIt(statusExport: Bool) async throws {
		let fixture = ElementHidingFixture(exports: true, statusExport: statusExport)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()

		ElementHidingFixture.statusJSON = """
		{"request":1.5,"tabId":7,"outcome":"opened","probe":"ok"}
		"""
		let status = await fixture.runtime.elementPickerStatus(on: page)
		#expect(fixture.runtime.supportsElementHiding)
		#expect(status?["outcome"] as? String == (statusExport ? "opened" : nil))
		#expect(status?["probe"] as? String == (statusExport ? "ok" : nil))
		#expect(status?["tabId"] as? Int == (statusExport ? 7 : nil))
		guard statusExport else { return }

		ElementHidingFixture.statusJSON = "not json"
		#expect(await fixture.runtime.elementPickerStatus(on: page)?.isEmpty == true)

		ElementHidingFixture.refuses = true
		#expect(await fixture.runtime.elementPickerStatus(on: page) == nil)
	}

	/// The extensions smoke's filters reach the engine as lines; a line that would split doesn't.
	@Test(arguments: [false, true])
	internal func fixtureFiltersReachTheEngineAsLines(statusExport: Bool) throws {
		let fixture = ElementHidingFixture(exports: true, statusExport: statusExport)
		defer { fixture.runtime.finish() }
		let page = try fixture.runtime.makePage()
		let filters = ["127.0.0.1##.arx-hide-target", "127.0.0.1##+js(noop)"]

		#expect(fixture.runtime.addFixtureFiltersForTesting(filters, on: page) == statusExport)
		#expect(ElementHidingFixture.added == (statusExport ? [filters.joined(separator: "\n")] : []))
		#expect(!fixture.runtime.addFixtureFiltersForTesting([], on: page))
		#expect(!fixture.runtime.addFixtureFiltersForTesting(["a##.b\nc##.d"], on: page))
		#expect(ElementHidingFixture.added.count == (statusExport ? 1 : 0))
	}
}

/// A runtime whose engine records Hide Element's calls.
@MainActor
private final class ElementHidingFixture {
	fileprivate static var view: NSView = .init()
	fileprivate static var json: String = "{}"
	fileprivate static var statusJSON: String = "{}"
	fileprivate static var added: [String] = []
	fileprivate static var refuses: Bool = false
	fileprivate static var picked: [UInt64] = []
	fileprivate static var shown: [(page: UInt64, filter: String)] = []
	fileprivate static var hidden: [(page: UInt64, filter: String?)] = []
	fileprivate let runtime: ChromiumRuntime

	fileprivate init(
		exports: Bool,
		statusExport: Bool = true,
		hideExport: Bool = false
	) {
		Self.json = "{}"
		Self.statusJSON = "{}"
		Self.added = []
		Self.refuses = false
		Self.picked = []
		Self.shown = []
		Self.hidden = []
		var api = ArxEngineAPI()
		api.create_page = { _, _ in 1 }
		api.page_view = { _ in
			let view = MainActor.assumeIsolated { ElementHidingFixture.view }
			return Unmanaged.passUnretained(view).toOpaque()
		}
		api.destroy_page = { _ in }
		self.runtime = .init(api: api)
		if exports {
			runtime.optionalExports.elementHiding = .init(
				startPicker: { page in
					MainActor.assumeIsolated {
						guard !ElementHidingFixture.refuses else { return false }
						ElementHidingFixture.picked.append(page)
						return true
					}
				},
				copyHidden: { _, done, context in
					MainActor.assumeIsolated {
						guard !ElementHidingFixture.refuses else { return false }
						ElementHidingFixture.json.withCString { done?(context, $0, strlen($0)) }
						return true
					}
				},
				show: { page, filter in
					MainActor.assumeIsolated {
						guard !ElementHidingFixture.refuses else { return false }
						ElementHidingFixture.shown.append((page, filter.map { String(cString: $0) } ?? ""))
						return true
					}
				}
			)
		}
		if exports, statusExport {
			runtime.optionalExports.elementHiding?.copyPickerStatus = { _, done, context in
				MainActor.assumeIsolated {
					guard !ElementHidingFixture.refuses else { return false }
					ElementHidingFixture.statusJSON.withCString { done?(context, $0, strlen($0)) }
					return true
				}
			}
			runtime.optionalExports.elementHiding?.addFixtureFilters = { _, filters in
				let text = filters.map { String(cString: $0) } ?? ""
				return MainActor.assumeIsolated {
					ElementHidingFixture.added.append(text)
					return true
				}
			}
		}
		if exports, hideExport {
			runtime.optionalExports.elementHiding?.hide = { page, filter in
				let line = filter.map { String(cString: $0) }
				return MainActor.assumeIsolated {
					guard !ElementHidingFixture.refuses else { return false }
					ElementHidingFixture.hidden.append((page, line))
					return true
				}
			}
		}
		runtime.didBecomeReady()
	}
}
