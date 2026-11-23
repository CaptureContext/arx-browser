import AppKit
import BrowserCore
import BrowserEngineClient
import WebKit

/// The `WKWebView` of a `WebKitPage`, which hands WebKit's context menu to the page before it
/// opens (DEV-1199).
internal final class WebKitPageView: WKWebView {
	internal var willOpenMenu: (@MainActor (NSMenu) -> Void)?

	/// Arx's back and forward swipe, which reads the view's scrolls first (DEV-1203).
	internal var historySwipe: WebKitHistorySwipe?

	/// A tab switch or a move takes the view from its window: its swipe ends with it, list and all.
	override internal func viewWillMove(toWindow newWindow: NSWindow?) {
		if newWindow !== window { historySwipe?.invalidate() }
		super.viewWillMove(toWindow: newWindow)
	}

	override internal func scrollWheel(with event: NSEvent) {
		if let historySwipe, historySwipe.handle(event, in: self) { return }
		super.scrollWheel(with: event)
	}

	override internal func willOpenMenu(
		_ menu: NSMenu,
		with event: NSEvent
	) {
		super.willOpenMenu(menu, with: event)
		willOpenMenu?(menu)
	}
}

// MARK: - Print and Save As

extension WebKitPage {
	/// Prints the page with WebKit's print panel, on the window showing it (DEV-1199). Page
	/// Setup's paper and orientation come from the shared print info, as for Chromium pages.
	public func print(title: String) async throws {
		guard let window = webView.window else { throw BrowserEngineClient.Failure.unavailable }

		let operation = webView.printOperation(with: NSPrintInfo.shared)
		operation.jobTitle = title
		operation.showsPrintPanel = true
		operation.showsProgressPanel = true

		// WebKit's print view has no frame of its own; without one the operation prints nothing.
		operation.view?.frame = webView.bounds
		await Self.run(operation, for: window)
	}

	/// Writes the page's current document to `destination` (DEV-1199): Safari's web archive, the
	/// HTML the server sent, or a PDF on Page Setup's paper. Refuses when the page no longer
	/// shows `address`, rather than saving another document under this one's name.
	public func save(
		_ address: URL,
		to destination: URL,
		as format: WebKitPageSaveFormat
	) async throws {
		guard destination.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
		guard webView.url == address else { throw BrowserEngineClient.Failure.unavailable }

		let data: Data = switch format {
		case .webArchive: try await webArchive()
		case .html: try Self.mainResource(of: try await webArchive())
		case .pdf: try await pdf()
		}
		guard webView.url == address else { throw BrowserEngineClient.Failure.unavailable }

		try data.write(to: destination, options: .atomic)
	}

	/// The main resource's bytes in a web archive: the document as the server sent it.
	internal static func mainResource(of archive: Data) throws -> Data {
		guard
			let plist = try PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
			let main = plist["WebMainResource"] as? [String: Any],
			let data = main["WebResourceData"] as? Data
		else { throw CocoaError(.fileReadCorruptFile) }

		return data
	}

	/// The page printed to PDF on Page Setup's paper, in pages. A page no window shows can't run
	/// a print operation and gives one long page instead.
	private func pdf() async throws -> Data {
		guard let window = webView.window else {
			return try await singlePagePDF()
		}
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("arx-webkit-\(UUID().uuidString).pdf")
		defer { try? FileManager.default.removeItem(at: file) }

		let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
		info.jobDisposition = .save
		info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = file
		let operation = webView.printOperation(with: info)
		operation.showsPrintPanel = false
		operation.showsProgressPanel = false
		operation.view?.frame = webView.bounds
		guard await Self.run(operation, for: window)
		else { throw CocoaError(.fileWriteUnknown) }

		return try Data(contentsOf: file)
	}

	/// Safari's web archive of the page: its document and every resource it loaded.
	private func webArchive() async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			webView.createWebArchiveData { continuation.resume(with: $0) }
		}
	}

	/// The whole page as one PDF page.
	private func singlePagePDF() async throws -> Data {
		try await withCheckedThrowingContinuation { continuation in
			webView.createPDF(configuration: .init()) { continuation.resume(with: $0) }
		}
	}

	/// Runs a print operation as a sheet on `window`; true when it succeeded.
	@discardableResult
	private static func run(
		_ operation: NSPrintOperation,
		for window: NSWindow
	) async -> Bool {
		await withCheckedContinuation { continuation in
			let delegate = PrintDelegate { continuation.resume(returning: $0) }
			operation.runModal(
				for: window,
				delegate: delegate,
				didRun: #selector(PrintDelegate.printOperationDidRun(_:success:contextInfo:)),
				contextInfo: nil
			)
		}
	}
}

/// Hears the end of a print operation and keeps itself until then.
@MainActor
private final class PrintDelegate: NSObject {
	private var onFinish: ((Bool) -> Void)?
	private var retained: PrintDelegate?

	internal init(onFinish: @escaping (Bool) -> Void) {
		self.onFinish = onFinish
		super.init()
		retained = self
	}

	@objc
	internal func printOperationDidRun(
		_ operation: NSPrintOperation,
		success: Bool,
		contextInfo: UnsafeMutableRawPointer?
	) {
		onFinish?(success)
		onFinish = nil
		retained = nil
	}
}
