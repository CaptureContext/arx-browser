@testable import AppFeature
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import PageCaptureFeature
import Testing
import WebKitBrowserEngine
import _ComposableArchitecture

/// DEV-1199: a WebKit page's right-click page menu, and its Print and Save As.
@Suite(.dependencies)
@MainActor
internal struct WebKitPageMenuTests {
	private let page = URL(string: "https://www.netflix.com/browse")!

	private func state() throws -> (AppFeature.State, CaptureSource) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.sidebar.organization.spaces[0].selectedTabID = organization.tabs[0].id
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: page)
		state.main.viewer.item.navigation.title = "Netflix"
		state.main.viewer.item.navigation.engine = .webKit
		let source = try #require(state.captureSource(for: .window(state.main.id)))
		return (state, source)
	}

	@Test
	internal func theWebKitPageMenuHasEveryCommandOfThePageMenu() throws {
		var (state, source) = try state()
		state.main.viewer.item.navigation.canGoBack = true
		state.main.viewer.item.navigation.canGoForward = true

		// A command the page menu gains needs a place, or a reason to stay out, in WebKit's.
		expectNoDifference(state.pageMenuCommands(showing: source.tabID), WebKitPageMenu.allCommands)
		#expect(WebKitPageMenu.allCommands.isDisjoint(with: [.castTab, .translatePage]))
	}

	@Test
	internal func printOnAWebKitPageUsesWebKitsPrintPanel() async throws {
		let (state, source) = try state()
		let printed = LockIsolated<[(BrowserCore.Tab.ID, String)]>([])
		var capture = BrowserCaptureClient()
		capture.pdfIsAvailable = { true }
		capture.pdfAuthorized = { _, _ in
			Issue.record("Chromium has no page to print for a WebKit tab")
			throw PageCaptureFailure.unavailable
		}
		var pageEngines = PageEngineClient(engine: { _ in .webKit })
		pageEngines.printWebKitPage = { tabID, title in printed.withValue { $0.append((tabID, title)) } }
		var documents = PageDocumentsClient.testValue
		documents.alert = { _ in Issue.record("Print didn't fail") }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserCapture = capture
			$0.pageEngines = pageEngines
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.printPage(source)))
		await store.finish()

		expectNoDifference(printed.value.map(\.0), [source.tabID])
		expectNoDifference(printed.value.map(\.1), ["Netflix"])
	}

	@Test
	internal func aWebKitPrintThatFailsSaysSo() async throws {
		let (state, source) = try state()
		var pageEngines = PageEngineClient(engine: { _ in .webKit })
		pageEngines.printWebKitPage = { _, _ in throw BrowserEngineClient.Failure.unavailable }
		let alerts = LockIsolated(0)
		var documents = PageDocumentsClient.testValue
		documents.alert = { _ in alerts.withValue { $0 += 1 } }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.pageEngines = pageEngines
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.printPage(source)))
		await store.finish()

		expectNoDifference(alerts.value, 1)
	}

	@Test(arguments: [
		(PageSaveFormat.webKitArchive, WebKitPageSaveFormat.webArchive),
		(.htmlOnly, .html),
		(.pdf, .pdf),
	])
	internal func saveAsOnAWebKitPageOffersWebKitsFormatsAndSavesWithWebKit(
		chosen: PageSaveFormat,
		saved format: WebKitPageSaveFormat
	) async throws {
		let (state, source) = try state()
		let offered = LockIsolated<[PageSaveFormat]>([])
		let saved = LockIsolated<[WebKitPageSaveFormat]>([])
		let addresses = LockIsolated<[URL]>([])
		let destination = URL(fileURLWithPath: "/tmp/Netflix")
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.savePage = { _, _, _ in Issue.record("Chromium's Save Page has no page for a WebKit tab") }
		var pageEngines = PageEngineClient(engine: { _ in .webKit })
		pageEngines.saveWebKitPage = { tabID, address, url, format in
			#expect(tabID == source.tabID)
			#expect(url == destination)
			addresses.withValue { $0.append(address) }
			saved.withValue { $0.append(format) }
		}
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { title, formats, isPrivate in
			#expect(title == "Netflix")
			#expect(!isPrivate)
			offered.setValue(formats)
			return (destination, chosen)
		}
		documents.alert = { _ in Issue.record("Save As didn't fail") }

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.pageEngines = pageEngines
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(offered.value, [.webKitArchive, .htmlOnly, .pdf])
		expectNoDifference(saved.value, [format])

		// The address the person chose to save: WebKit refuses once the page shows another.
		expectNoDifference(addresses.value, [page])
	}

	@Test
	internal func aChromiumPageStillSavesWithChromium() async throws {
		var (state, source) = try state()
		state.main.viewer.item.navigation.engine = .chromium
		let offered = LockIsolated<[PageSaveFormat]>([])
		var engine = BrowserEngineClient(status: { .notIntegrated })
		engine.snapshot = { _ in .init(navigation: .init(), revision: 1, documentRevision: 1) }
		engine.savePageIsAvailable = { true }
		engine.documentType = { _ in .web }
		var pageEngines = PageEngineClient()
		pageEngines.saveWebKitPage = { _, _, _, _ in Issue.record("A Chromium page never saves with WebKit") }
		var documents = PageDocumentsClient.testValue
		documents.chooseSaveDestination = { _, formats, _ in
			offered.setValue(formats)
			return nil
		}

		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.browserEngine = engine
			$0.pageEngines = pageEngines
			$0.pageDocuments = documents
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.savePage(source)))
		await store.finish()

		expectNoDifference(offered.value, [.complete, .htmlOnly, .webArchive, .pdf])
	}
}
