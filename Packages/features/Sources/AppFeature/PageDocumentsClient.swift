import AppKit
import AppUI
import BrowserEngineClient
import Foundation
import PDFKit
import UniformTypeIdentifiers
import _Dependencies

/// What Save Page As writes (DEV-795).
internal enum PageSaveFormat: CaseIterable, Equatable, Sendable {
	/// The HTML and its resources in a "<name>_files" folder, with the engine's Save Page.
	case complete

	/// The page's HTML alone, with the engine's Save Page.
	case htmlOnly

	/// One MHTML web archive, with the engine's Save Page.
	case webArchive

	/// The page printed to PDF, or the PDF document it shows.
	case pdf

	/// Safari's web archive of a WebKit page (DEV-1199).
	case webKitArchive

	/// The formats Save As offers for a WebKit page (DEV-1199): Chromium's Save Page has no
	/// page there.
	internal static let webKit: [Self] = [.webKitArchive, .htmlOnly, .pdf]

	/// How WebKit writes the format for a WebKit page; nil for a Chromium-only one.
	internal var webKitFormat: WebKitPageSaveFormat? {
		switch self {
		case .webKitArchive: .webArchive
		case .htmlOnly: .html
		case .pdf: .pdf
		case .complete, .webArchive: nil
		}
	}

	internal var engineFormat: BrowserSavePageFormat? {
		switch self {
		case .complete: .complete
		case .htmlOnly: .htmlOnly
		case .webArchive: .webArchive
		case .pdf, .webKitArchive: nil
		}
	}

	internal var contentType: UTType {
		switch self {
		case .complete, .htmlOnly: .html
		case .webArchive: UTType(filenameExtension: "mhtml") ?? .data
		case .pdf: .pdf
		case .webKitArchive: .webArchive
		}
	}

	internal var title: String {
		switch self {
		case .complete: String.localized(.appUI.savePage.complete)
		case .htmlOnly: String.localized(.appUI.savePage.htmlOnly)
		case .webArchive: String.localized(.appUI.savePage.archive)
		case .pdf: String.localized(.appUI.savePage.pdf)
		case .webKitArchive: String.localized(.appUI.savePage.webKitArchive)
		}
	}
}

/// Page Setup's choices, as the engine's PDF export takes them (DEV-795).
internal struct PageLayout: Equatable, Sendable {
	internal var isLandscape: Bool

	/// Portrait inches; nil keeps the engine's US Letter.
	internal var paperWidth: Double?
	internal var paperHeight: Double?

	internal init(
		isLandscape: Bool = false,
		paperWidth: Double? = nil,
		paperHeight: Double? = nil
	) {
		self.isLandscape = isLandscape
		self.paperWidth = paperWidth
		self.paperHeight = paperHeight
	}

	/// From AppKit's paper size in points, which follows the orientation; the engine takes
	/// portrait inches and its own landscape flag. Sizes it can't take keep US Letter.
	internal init(
		paperSize: CGSize,
		isLandscape: Bool
	) {
		let width = Double(min(paperSize.width, paperSize.height)) / 72
		let height = Double(max(paperSize.width, paperSize.height)) / 72
		let isUsable = (1...100).contains(width) && (1...100).contains(height)
		self.init(
			isLandscape: isLandscape,
			paperWidth: isUsable ? width : nil,
			paperHeight: isUsable ? height : nil
		)
	}
}

/// AppKit's panels for Print, Page Setup, Save Page As and Open File (DEV-795).
internal struct PageDocumentsClient: Sendable {
	internal var pageSetup: @MainActor @Sendable () async -> Void

	/// Page Setup's paper and orientation, for the page's PDF.
	internal var pageLayout: @MainActor @Sendable () -> PageLayout

	/// Shows the print panel for PDF bytes, as a sheet on the browser window with this ID: the
	/// one Print started in. Nothing is shown if that window has closed or is hidden.
	internal var print: @MainActor @Sendable (Data, _ title: String, _ windowID: UUID) async throws -> Void

	/// Asks where to save the page and in which of `formats`. Nil when the person cancels.
	/// For a private page, the folder chosen is kept in memory only, as Chrome's incognito
	/// does: the next ordinary save doesn't learn it, and nothing about it reaches disk.
	internal var chooseSaveDestination: @MainActor @Sendable (
		_ title: String,
		[PageSaveFormat],
		_ isPrivate: Bool
	) async -> (URL, PageSaveFormat)?
	internal var write: @Sendable (Data, URL) async throws -> Void

	/// Asks for a local file to open. Nil when the person cancels.
	internal var chooseFile: @MainActor @Sendable () async -> URL?
	internal var alert: @MainActor @Sendable (String) async -> Void
	#if DEBUG
	/// Debug builds only: the error behind a failed Print or Save Page As, just before its
	/// alert, so a smoke that fails names the cause (DEV-1059).
	internal var failed: @MainActor @Sendable (any Error) -> Void = { _ in }
	#endif
}

extension PageDocumentsClient: DependencyKey {
	internal static var liveValue: Self {
		.init(
			pageSetup: {
				let window = NSApplication.shared.keyWindow
				let layout = NSPageLayout()
				if let window {
					await withCheckedContinuation { continuation in
						let delegate = SheetDelegate { continuation.resume() }
						layout.beginSheet(
							using: NSPrintInfo.shared,
							on: window,
							completionHandler: { _ in delegate.finish() }
						)
					}
				} else {
					layout.runModal(with: NSPrintInfo.shared)
				}
			},
			pageLayout: {
				PageLayout(
					paperSize: NSPrintInfo.shared.paperSize,
					isLandscape: NSPrintInfo.shared.orientation == .landscape
				)
			},
			print: { data, title, windowID in

				// Never another window that became key while the PDF was made.
				guard let window = LinkSharingClient.presentationWindow(for: windowID) else { return }
				guard
					let document = PDFDocument(data: data),
					let operation = document.printOperation(
						for: NSPrintInfo.shared,
						scalingMode: .pageScaleDownToFit,
						autoRotate: true
					)
				else { throw CocoaError(.fileReadCorruptFile) }

				operation.jobTitle = title
				operation.showsPrintPanel = true
				operation.showsProgressPanel = true
				await withCheckedContinuation { continuation in
					let delegate = SheetDelegate { continuation.resume() }
					operation.runModal(
						for: window,
						delegate: delegate,
						didRun: #selector(SheetDelegate.printOperationDidRun(_:success:contextInfo:)),
						contextInfo: nil
					)
				}
			},
			chooseSaveDestination: { title, formats, isPrivate in
				guard isPrivate else {
					PrivateSaveFolder.prepareOrdinaryPanel()
					return await Self.chooseSaveDestination(title, formats).choice
				}
				return await PrivateSaveFolder.withoutRemembering {
					let (choice, shown) = await Self.chooseSaveDestination(
						title,
						formats,
						directory: PrivateSaveFolder.lastDirectory
					)
					if let choice { PrivateSaveFolder.lastDirectory = choice.0.deletingLastPathComponent() }
					return (choice, shown: shown)
				}
			},
			write: { data, url in
				guard url.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
				try data.write(to: url, options: .atomic)
			},
			chooseFile: {
				let panel = NSOpenPanel()
				panel.canChooseFiles = true
				panel.canChooseDirectories = false
				panel.allowsMultipleSelection = false
				let response = await withCheckedContinuation { continuation in
					panel.begin { continuation.resume(returning: $0) }
				}
				return response == .OK ? panel.url : nil
			},
			alert: { message in
				let alert = NSAlert()
				alert.messageText = message
				alert.alertStyle = .warning
				if let window = NSApplication.shared.keyWindow {
					await alert.beginSheetModal(for: window)
				} else {
					alert.runModal()
				}
			}
		)
	}

	/// The save panel with a Format menu when there's more than one format. `directory` is
	/// where it opens; nil leaves it where AppKit last saved. Also returns the folder the panel
	/// showed when it closed, saved to or not.
	@MainActor
	private static func chooseSaveDestination(
		_ title: String,
		_ formats: [PageSaveFormat],
		directory: URL? = nil
	) async -> (choice: (URL, PageSaveFormat)?, shown: URL?) {
		guard let first = formats.first else { return (nil, nil) }
		let panel = NSSavePanel()
		if let directory { panel.directoryURL = directory }
		panel.canCreateDirectories = true
		panel.isExtensionHidden = false
		panel.allowedContentTypes = [first.contentType]
		panel.nameFieldStringValue = Self.filename(title)

		let picker = NSPopUpButton(frame: .zero, pullsDown: false)
		picker.addItems(withTitles: formats.map(\.title))
		let chooser = FormatChooser(panel: panel, formats: formats)
		picker.target = chooser
		picker.action = #selector(FormatChooser.changed(_:))
		let label = NSTextField(labelWithString: String.localized(.appUI.savePage.format))
		let row = NSStackView(views: [label, picker])
		row.orientation = .horizontal
		row.edgeInsets = .init(top: 8, left: 16, bottom: 8, right: 16)
		panel.accessoryView = formats.count > 1 ? row : nil

		let response = await withCheckedContinuation { continuation in
			panel.begin { continuation.resume(returning: $0) }
		}
		let shown = panel.directoryURL
		guard response == .OK, let url = panel.url else { return (nil, shown) }
		return withExtendedLifetime(chooser) {
			((url, formats[max(0, picker.indexOfSelectedItem)]), shown)
		}
	}

	internal static var testValue: Self {
		.init(
			pageSetup: unimplemented("PageDocumentsClient.pageSetup"),
			pageLayout: unimplemented("PageDocumentsClient.pageLayout", placeholder: PageLayout()),
			print: unimplemented("PageDocumentsClient.print"),
			chooseSaveDestination: unimplemented("PageDocumentsClient.chooseSaveDestination", placeholder: nil),
			write: unimplemented("PageDocumentsClient.write"),
			chooseFile: unimplemented("PageDocumentsClient.chooseFile", placeholder: nil),
			alert: unimplemented("PageDocumentsClient.alert")
		)
	}

	/// A file name from the page title, without characters Finder can't keep.
	internal static func filename(_ title: String) -> String {
		let cleaned = title
			.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
			.joined(separator: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return String((cleaned.isEmpty ? "Page" : cleaned).prefix(200))
	}
}

extension DependencyValues {
	internal var pageDocuments: PageDocumentsClient {
		get { self[PageDocumentsClient.self] }
		set { self[PageDocumentsClient.self] = newValue }
	}
}

/// Ends an AppKit sheet's wait. Kept alive by the sheet until it calls back.
@MainActor
private final class SheetDelegate: NSObject {
	private var onFinish: (() -> Void)?
	private var retained: SheetDelegate?

	internal init(onFinish: @escaping () -> Void) {
		self.onFinish = onFinish
		super.init()
		retained = self
	}

	internal func finish() {
		onFinish?()
		onFinish = nil
		retained = nil
	}

	@objc
	internal func printOperationDidRun(
		_ operation: NSPrintOperation,
		success: Bool,
		contextInfo: UnsafeMutableRawPointer?
	) {
		finish()
	}
}

/// Keeps the save panel's file type in step with the chosen format.
@MainActor
private final class FormatChooser: NSObject {
	private weak var panel: NSSavePanel?
	private let formats: [PageSaveFormat]

	internal init(
		panel: NSSavePanel,
		formats: [PageSaveFormat]
	) {
		self.panel = panel
		self.formats = formats
	}

	@objc
	internal func changed(_ sender: NSPopUpButton) {
		guard formats.indices.contains(sender.indexOfSelectedItem) else { return }
		panel?.allowedContentTypes = [formats[sender.indexOfSelectedItem].contentType]
	}
}

/// Where private pages were last saved, for this run of Arx only (DEV-816).
///
/// AppKit remembers the last save panel folder in Arx's defaults (`NSOSPLastRootDirectory`),
/// and may write it after the panel's completion handler. A private save mustn't leave its
/// folder there, so from before its panel opens until a while after it closes, Arx watches
/// that value:
/// - while a private panel is open, any change is put back;
/// - after it closes, a change to the folder that panel showed is put back, and any other
///   change is another panel's own choice, which stays and becomes what's put back next.
/// An ordinary save panel also checks it before it opens. The private folder itself stays
/// here, in memory, as Chrome's incognito keeps it.
@MainActor
internal enum PrivateSaveFolder {
	internal static var lastDirectory: URL?

	private static let appKitKey: String = "NSOSPLastRootDirectory"

	/// How long after a private panel closes AppKit's folder is still watched.
	private static let watchPeriod: Duration = .seconds(10)

	private static var watch: Watch?

	internal static func withoutRemembering(
		_ body: @MainActor () async -> ((URL, PageSaveFormat)?, shown: URL?)
	) async -> (URL, PageSaveFormat)? {
		panelWillOpen()
		let (choice, shown) = await body()
		panelDidClose(showing: shown)
		return choice
	}

	/// Before an ordinary save panel opens: AppKit's own folder, never a private save's. The
	/// watch goes on, for a private panel's write that comes late; the ordinary panel's own
	/// choice of another folder stays. Choosing the very folder a private panel showed in that
	/// time isn't remembered.
	internal static func prepareOrdinaryPanel() {
		defaultsChanged()
	}

	private static func panelWillOpen() {
		let watch = self.watch ?? startWatching()
		watch.expiry?.cancel()
		watch.expiry = nil
		watch.openPanels += 1
	}

	private static func panelDidClose(showing directory: URL?) {
		guard let watch else { return }
		watch.openPanels -= 1
		if let directory { watch.privateDirectories.insert(directory.standardizedFileURL) }
		defaultsChanged()
		guard watch.openPanels == 0 else { return }
		watch.expiry = Task { @MainActor in
			try? await Task.sleep(for: watchPeriod)
			guard !Task.isCancelled else { return }
			stopWatching()
		}
	}

	private static func startWatching() -> Watch {
		let observer = NotificationCenter.default.addObserver(
			forName: UserDefaults.didChangeNotification,
			object: UserDefaults.standard,
			queue: .main
		) { _ in
			MainActor.assumeIsolated { defaultsChanged() }
		}
		let watch: Watch = .init(
			baseline: UserDefaults.standard.data(forKey: appKitKey),
			observer: observer
		)
		self.watch = watch
		return watch
	}

	private static func stopWatching() {
		guard let watch else { return }
		watch.expiry?.cancel()
		NotificationCenter.default.removeObserver(watch.observer)
		self.watch = nil
	}

	/// Puts back the folder from before a private save when a private panel wrote it; keeps
	/// another panel's choice.
	private static func defaultsChanged() {
		guard let watch else { return }
		let defaults: UserDefaults = .standard
		let current = defaults.data(forKey: appKitKey)
		guard current != watch.baseline else { return }

		guard watch.openPanels > 0 || isPrivate(current, watch) else {
			watch.baseline = current
			return
		}
		if let baseline = watch.baseline {
			defaults.set(baseline, forKey: appKitKey)
		} else {
			defaults.removeObject(forKey: appKitKey)
		}
	}

	/// Whether AppKit's stored folder is one a private panel showed. One that can't be read
	/// counts as private, so it's put back.
	private static func isPrivate(
		_ bookmark: Data?,
		_ watch: Watch
	) -> Bool {
		guard let bookmark else { return false }
		var isStale = false
		guard
			let url = try? URL(
				resolvingBookmarkData: bookmark,
				options: [.withoutUI, .withoutMounting],
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			)
		else { return true }

		return watch.privateDirectories.contains(url.standardizedFileURL)
	}

	private final class Watch {
		/// What's put back: AppKit's folder before the private panels, or another panel's
		/// choice since.
		internal var baseline: Data?
		internal let observer: any NSObjectProtocol
		internal var openPanels: Int

		/// The folders private panels showed when they closed.
		internal var privateDirectories: Set<URL>
		internal var expiry: Task<Void, Never>?

		internal init(
			baseline: Data?,
			observer: any NSObjectProtocol
		) {
			self.baseline = baseline
			self.observer = observer
			self.openPanels = 0
			self.privateDirectories = []
			self.expiry = nil
		}
	}
}
