import AppUI
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import PageCaptureFeature
import _ComposableArchitecture

/// Print, Page Setup, Save Page As, Open File and the page menu (DEV-795).
///
/// Print and Save as PDF read the page through the engine's PDF export, or the bytes of the
/// PDF document it shows. Save as HTML or a web archive is Chromium's Save Page (ABI45).
///
/// A private page offers only Save Page: the engine reads ordinary pages alone as PDF, so a
/// private window can't print, and a PDF document there can't be saved (DEV-816). Save Page
/// writes only the file the person chose; its transfer stays in Private Transfers, in memory.
///
/// A WebKit page (DEV-1199) prints with WebKit's print panel and saves with WebKit: as Safari's
/// web archive, the HTML the server sent, or a PDF. Chromium has no page for it.
@Reducer
internal struct PageDocuments {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserCapture)
	private var capture

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.pageDocuments)
	private var documents

	@Dependency(\.pageEngines)
	private var pageEngines

	/// The engine's limit for one PDF.
	private static let maximumBytes: Int = 33_554_432

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.pageSetup) { _ in
			.run { [documents] _ in await documents.pageSetup() }
		}

		// DEV-971: a private page prints too; its PDF stays in memory until the print panel.
		Pullback(\.ui.printPage) { state, source in
			guard
				let viewer = state.captureViewer(for: source),
				viewer.navigation.showsWebPage
			else { return .none }

			let title = Self.title(viewer.navigation)
			let tabID = source.tabID
			guard let windowID = state.presentationWindowID(for: source) else { return .none }
			if viewer.navigation.engine == .webKit {
				return .run { [pageEngines, documents] _ in
					do {
						try await pageEngines.printWebKitPage(tabID, title)
					} catch is CancellationError {
					} catch {
						await Self.fail(error, String.localized(.appUI.print.failed), documents: documents)
					}
				}
			}
			return .run { [engine, capture, documents] _ in
				do {
					let pdf = try await Self.pdf(
						tabID,
						layout: await documents.pageLayout(),
						engine: engine,
						capture: capture
					)
					try await documents.print(pdf.data, title, windowID)
				} catch is CancellationError {
				} catch {
					await Self.fail(error, String.localized(.appUI.print.failed), documents: documents)
				}
			}
		}

		Pullback(\.ui.savePage) { state, source in
			guard
				let viewer = state.captureViewer(for: source),
				viewer.navigation.showsWebPage
			else { return .none }

			let title = Self.title(viewer.navigation)
			let tabID = source.tabID

			// A private page offers the same formats (DEV-971); its panel keeps the folder it
			// opens out of the remembered ones (DEV-816).
			let isPrivate = state.isPrivate(source)
			if viewer.navigation.engine == .webKit {
				guard let address = viewer.navigation.url else { return .none }
				return .run { [pageEngines, documents] _ in
					guard
						let (url, format) = await documents.chooseSaveDestination(title, PageSaveFormat.webKit, isPrivate),
						let webKitFormat = format.webKitFormat
					else { return }

					do {
						try await pageEngines.saveWebKitPage(tabID, address, url, webKitFormat)
					} catch is CancellationError {
					} catch {
						await Self.fail(error, String.localized(.appUI.savePage.failed), documents: documents)
					}
				}
			}
			return .run { [engine, capture, documents, clock] _ in

				// The page the person chose to save: if it navigates while the panel is open,
				// nothing is saved, rather than another document under this one's name.
				guard let document = await engine.snapshot(tabID)?.documentRevision else { return }

				// A PDF document saves as its own bytes: the HTML formats would save the viewer.
				// Only a page that isn't a PDF goes on to them; a failed read is an error. The
				// engine tells a PDF from its MIME type, also while it loads (ABI48, DEV-819);
				// its bytes are read once it has loaded. An older engine is asked for the bytes
				// at once; a page still loading can't answer, so it's taken as a web page.
				let savesHTML = await engine.savePageIsAvailable()
				let isLoading = await engine.snapshot(tabID)?.navigation.isLoading == true
				let documentType = await engine.documentType(tabID)
				let source: PagePDF?
				var exportsPDF = true
				var isPDF = false
				switch documentType {
				case .pdf:
					source = nil
					isPDF = true

				case .web:
					source = nil
					exportsPDF = !isLoading

				case nil:
					do {
						source = try await Self.sourcePDF(
							tabID,
							document: document,
							engine: engine,
							capture: capture
						)
					} catch PageCaptureFailure.unsupportedRendering {
						source = nil
					} catch PageCaptureFailure.unavailable where savesHTML && isLoading {
						source = nil
						exportsPDF = false
					} catch is CancellationError {
						return
					} catch {
						await Self.fail(error, String.localized(.appUI.savePage.failed), documents: documents)
						return
					}
				}
				let formats: [PageSaveFormat] = !isPDF && source == nil && savesHTML
				? [.complete, .htmlOnly, .webArchive] + (exportsPDF ? [.pdf] : [])
				: [.pdf]
				guard let choice = await documents.chooseSaveDestination(title, formats, isPrivate)
				else { return }

				let (url, format) = choice
				do {
					if let source {
						try await documents.write(source.data, url)
					} else if isPDF {
						let source = try await Self.loadedSourcePDF(
							tabID,
							document: document,
							engine: engine,
							capture: capture,
							clock: clock
						)
						try await documents.write(source.data, url)
					} else if let engineFormat = format.engineFormat {
						try await Self.savePage(
							tabID,
							document: document,
							to: url,
							engineFormat,
							engine: engine
						)
					} else {
						let pdf = try await Self.pdf(
							tabID,
							document: document,
							layout: await documents.pageLayout(),
							engine: engine,
							capture: capture
						)
						try await documents.write(pdf.data, url)
					}
				} catch is CancellationError {
				} catch {
					await Self.fail(error, String.localized(.appUI.savePage.failed), documents: documents)
				}
			}
		}

		Pullback(\.ui.openFile) { state, windowID in
			guard state.window(windowID) != nil else { return .none }
			let isMain = windowID == state.main.id
			return .run { [documents] send in
				guard let url = await documents.chooseFile() else { return }

				// The chosen file opens in the window the command came from.
				let open: MainFeature.Action = .ui(.openInNewTab(url))
				await send(isMain ? .main(open) : .windows(.element(id: windowID, action: open)))
			}
		}

		Pullback(\.ui.pageMenu) { state, value in
			let (tabID, command) = value
			guard let target = state.commandTarget(showing: tabID) else { return .none }
			return .send(.ui(.command(command, target)))
		}
	}

	private static func title(_ navigation: BrowserNavigation) -> String {
		navigation.title.isEmpty ? (navigation.url?.host() ?? "") : navigation.title
	}

	/// Shows the alert for a failed Print or Save Page As. A debug build first hands the error
	/// to `documents.failed`, so a smoke that fails names the cause (DEV-1059).
	@MainActor
	private static func fail(
		_ error: any Error,
		_ message: String,
		documents: PageDocumentsClient
	) async {
		#if DEBUG
		documents.failed(error)
		#endif
		await documents.alert(message)
	}

	/// Saves with the engine's Save Page, only while the tab still shows `document`.
	@MainActor
	private static func savePage(
		_ tabID: BrowserCore.Tab.ID,
		document: UInt64,
		to url: URL,
		_ format: BrowserSavePageFormat,
		engine: BrowserEngineClient
	) throws {
		guard engine.snapshot(tabID)?.documentRevision == document
		else { throw PageCaptureFailure.staleDocument }

		try engine.savePage(tabID, url, format)
	}

	/// The bytes of the PDF document the tab shows; throws for any other page.
	@MainActor
	private static func sourcePDF(
		_ tabID: BrowserCore.Tab.ID,
		document: UInt64,
		engine: BrowserEngineClient,
		capture: BrowserCaptureClient
	) async throws -> PagePDF {
		guard
			capture.pdfIsAvailable(),
			let snapshot = engine.snapshot(tabID),
			snapshot.documentRevision == document
		else { throw PageCaptureFailure.unavailable }

		return try await capture.pdfAuthorized(
			.init(
				tabID: tabID,
				revision: snapshot.revision,
				documentRevision: document,
				kind: .source,
				maximumBytes: maximumBytes,
				allowsPrivate: true
			),
			{ true }
		)
	}

	/// How long Save Page As waits for a PDF to load and hand over its bytes.
	internal static let loadedPDFTimeout: Duration = .seconds(30)

	/// How long Save Page As keeps reading a PDF's bytes once it has loaded.
	internal static let loadedPDFBytesTimeout: Duration = .seconds(6)

	/// The interval between reads of a PDF's bytes while Save Page As waits for them.
	internal static let loadedPDFReadInterval: Duration = .milliseconds(250)

	/// The bytes of the PDF document the tab shows, once it has loaded: the engine can't read
	/// them while the page loads, so this waits up to 30 seconds, only while the tab still shows
	/// `document` (DEV-819).
	///
	/// Both limits are times on `clock`, not counts of reads: under load each read takes longer,
	/// and the PDF viewer takes longer to hand over its bytes after the load ends (DEV-965).
	///
	/// A read the engine reports as stale or busy is read again while the tab still shows
	/// `document`: every navigation update, such as the load ending, makes a read that overlaps
	/// it stale, though the document is the same (DEV-1059).
	@MainActor
	private static func loadedSourcePDF<C: Clock<Duration>>(
		_ tabID: BrowserCore.Tab.ID,
		document: UInt64,
		engine: BrowserEngineClient,
		capture: BrowserCaptureClient,
		clock: C
	) async throws -> PagePDF {
		// Both start at the first read that fails: a PDF read at once never needs the clock.
		var deadline: C.Instant?
		var loadEnded: C.Instant?

		while true {
			do {
				return try await sourcePDF(tabID, document: document, engine: engine, capture: capture)
			} catch let failure as PageCaptureFailure where Self.retriedPDFReadFailures.contains(failure) {
				guard
					let snapshot = engine.snapshot(tabID),
					snapshot.documentRevision == document
				else { throw PageCaptureFailure.staleDocument }

				let now = clock.now
				let giveUpAt = deadline ?? now.advanced(by: Self.loadedPDFTimeout)
				deadline = giveUpAt

				if snapshot.navigation.isLoading {
					// A load that starts again restarts the wait for the bytes after it.
					loadEnded = nil

				} else {
					let ended = loadEnded ?? now
					loadEnded = ended
					guard ended.duration(to: now) < Self.loadedPDFBytesTimeout
					else { throw failure }
				}

				guard now < giveUpAt
				else { throw failure }
			}
			try await clock.sleep(for: Self.loadedPDFReadInterval)
		}
	}

	/// The failures of a PDF read that Save Page As reads again after, while the tab shows
	/// the same document.
	private static let retriedPDFReadFailures: [PageCaptureFailure] = [
		.unavailable,
		.staleDocument,
		.busy,
	]

	/// The PDF document the page shows, else the page printed to PDF on Page Setup's paper.
	/// With `document`, only while the tab still shows that document.
	@MainActor
	private static func pdf(
		_ tabID: BrowserCore.Tab.ID,
		document: UInt64? = nil,
		layout: PageLayout,
		engine: BrowserEngineClient,
		capture: BrowserCaptureClient
	) async throws -> PagePDF {
		guard
			capture.pdfIsAvailable(),
			let snapshot = engine.snapshot(tabID),
			let documentRevision = snapshot.documentRevision
		else { throw PageCaptureFailure.unavailable }
		if let document, document != documentRevision { throw PageCaptureFailure.staleDocument }

		func request(_ kind: PagePDFRequest.Kind) -> PagePDFRequest {
			.init(
				tabID: tabID,
				revision: snapshot.revision,
				documentRevision: documentRevision,
				kind: kind,
				maximumBytes: maximumBytes,
				// The app's own Print and Save as PDF; a private page's PDF stays in memory.
				allowsPrivate: true
			)
		}

		// Only a page that isn't a PDF document is printed to PDF; any other failure stands.
		do {
			return try await capture.pdfAuthorized(request(.source), { true })
		} catch PageCaptureFailure.unsupportedRendering {
			try Task.checkCancellation()
		}
		return try await capture.pdfAuthorized(
			request(.export(
				landscape: layout.isLandscape,
				printsBackground: false,
				scale: nil,
				paperWidth: layout.paperWidth,
				paperHeight: layout.paperHeight
			)),
			{ true }
		)
	}
}

extension AppFeature.State {
	/// The command target showing `tabID` now: a Peek, a Little Arx window or one of a window's
	/// panes. Nil when nothing or more than one host shows it, so a choice never lands elsewhere.
	internal func commandTarget(showing tabID: BrowserCore.Tab.ID) -> AppFeature.CommandTarget? {
		guard !shouldQuit, !checkingQuit else { return nil }

		let targets = commandTargets(showing: tabID)
		return targets.count == 1 ? targets.first : nil
	}

	/// Every Peek, Little Arx window and window pane showing `tabID` now.
	internal func commandTargets(showing tabID: BrowserCore.Tab.ID) -> [AppFeature.CommandTarget] {
		var targets: [AppFeature.CommandTarget] = []
		for peek in peeks where peek.viewer.tab?.id == tabID {
			targets.append(.peek(peek.id))
		}
		for little in littleWindows where little.viewer.tab?.id == tabID && !little.isCommandOnly {
			targets.append(.window(little.id))
		}
		for host in (windowIsOpen ? [main] : []) + Array(windows) where !host.isClosing {
			for pane in host.viewer.panes where pane.item.tab?.id == tabID {
				targets.append(.window(host.id, paneID: pane.id))
			}
		}
		return targets
	}

	/// Whether `source` is a page of a private window, or a Peek over one (DEV-816).
	internal func isPrivate(_ source: CaptureSource) -> Bool {
		presentationWindowID(for: source).flatMap(window)?.isPrivate == true
	}

	/// The browser window a page's sheets belong to: its own, or the one a Peek opened over.
	internal func presentationWindowID(for source: CaptureSource) -> UUID? {
		switch source.host {
		case let .pane(windowID, _): windowID
		case let .little(id): id
		case let .peek(id): peeks[id: id]?.source.windowID
		}
	}

	/// The page menu's commands the host showing `tabID` can carry out now (DEV-795).
	internal func pageMenuCommands(showing tabID: BrowserCore.Tab.ID) -> Set<BrowserCommand> {
		guard
			let target = commandTarget(showing: tabID),
			let context = commandContext(for: target)
		else { return [] }

		let commands: [BrowserCommand] = [.goBack, .goForward, .reload, .savePageAs, .printPage, .viewSource, .sharePage]
		return Set(commands.filter { $0.isEnabled(in: context) })
	}
}
