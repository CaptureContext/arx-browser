import AppKit
import BrowserCore
import Foundation
import UniformTypeIdentifiers
import _Dependencies

public struct PageCaptureExportClient: Sendable {
	public var save: @MainActor @Sendable (PageCaptureImage, PageCaptureFormat, String) async throws -> URL?
	public var reveal: @MainActor @Sendable (URL) -> Void

	/// Asks the person where to save an already encoded capture, suggesting a
	/// name derived from the page title. Returns `nil` when they cancel.
	public var chooseDestination: @MainActor @Sendable (_ title: String, PageCaptureFormat) async throws -> URL?

	/// Writes already encoded image bytes to a destination the person chose.
	public var write: @Sendable (Data, URL) async throws -> Void

	/// Puts the PNG on the general pasteboard.
	public var copy: @MainActor @Sendable (PageCaptureImage) throws -> Void

	/// Opens the PNG in Preview for markup, from a file named after the page title.
	public var edit: @MainActor @Sendable (PageCaptureImage, _ title: String) async throws -> Void

	public init(
		save: @escaping @MainActor @Sendable (PageCaptureImage, PageCaptureFormat, String) async throws -> URL?,
		reveal: @escaping @MainActor @Sendable (URL) -> Void,
		chooseDestination: @escaping @MainActor @Sendable (_ title: String, PageCaptureFormat) async throws -> URL? = { _, _ in nil },
		write: @escaping @Sendable (Data, URL) async throws -> Void = { _, _ in },
		copy: @escaping @MainActor @Sendable (PageCaptureImage) throws -> Void = { _ in },
		edit: @escaping @MainActor @Sendable (PageCaptureImage, _ title: String) async throws -> Void = { _, _ in }
	) {
		self.save = save
		self.reveal = reveal
		self.chooseDestination = chooseDestination
		self.write = write
		self.copy = copy
		self.edit = edit
	}
}

extension PageCaptureExportClient: DependencyKey {
	public static var liveValue: Self {
		.init(
			save: { image, format, title in
				guard let url = try await presentSavePanel(title: title, format: format, activates: false)
				else { return nil }

				try await detached { try PageCaptureCodec.write(image, as: format, to: url) }
				return url
			},
			reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
			chooseDestination: { title, format in

				// An agent's request arrives while another app may be frontmost.
				try await presentSavePanel(title: title, format: format, activates: true)
			},
			write: { data, url in
				try await detached {
					guard url.isFileURL else { throw PageCaptureFailure.invalidFormat }
					try Task.checkCancellation()
					try data.write(to: url, options: .atomic)
				}
			},
			copy: { image in
				let pasteboard = NSPasteboard.general
				pasteboard.clearContents()
				guard pasteboard.setData(image.png, forType: .png)
				else { throw PageCaptureFailure.encodingFailed }
			},
			edit: { image, title in
				let folder = FileManager.default.temporaryDirectory
					.appending(path: "Arx Captures", directoryHint: .isDirectory)
					.appending(path: UUID().uuidString, directoryHint: .isDirectory)
				let url = folder.appending(path: PageCaptureCodec.filename(title: title, format: .png))
				try await detached {
					try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
					try image.png.write(to: url, options: .atomic)
				}
				let configuration = NSWorkspace.OpenConfiguration()
				configuration.activates = true
				if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
					_ = try await NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration)
				} else {
					_ = try await NSWorkspace.shared.open(url, configuration: configuration)
				}
			}
		)
	}

	public static var testValue: Self {
		.init(
			save: { _, _, _ in nil },
			reveal: { _ in },
			chooseDestination: { _, _ in nil },
			write: { _, _ in },
			copy: { _ in },
			edit: { _, _ in }
		)
	}

	public static var previewValue: Self { testValue }

	@MainActor
	private static func presentSavePanel(
		title: String,
		format: PageCaptureFormat,
		activates: Bool
	) async throws -> URL? {
		try Task.checkCancellation()
		let panel: NSSavePanel = .init()
		panel.allowedContentTypes = [format.fileExtension == "png" ? .png : .jpeg]
		panel.allowsOtherFileTypes = false
		panel.isExtensionHidden = false
		panel.nameFieldStringValue = PageCaptureCodec.filename(title: title, format: format)
		if activates { NSApplication.shared.activate() }
		let response = await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				panel.begin { continuation.resume(returning: $0) }
			}
		} onCancel: {
			Task { @MainActor in panel.cancel(nil) }
		}
		try Task.checkCancellation()
		guard response == .OK else { return nil }
		return panel.url
	}

	private static func detached(_ operation: @escaping @Sendable () throws -> Void) async throws {
		let writer = Task.detached(priority: .userInitiated, operation: operation)
		try await withTaskCancellationHandler {
			try await writer.value
		} onCancel: {
			writer.cancel()
		}
	}
}

extension DependencyValues {
	public var pageCaptureExport: PageCaptureExportClient {
		get { self[PageCaptureExportClient.self] }
		set { self[PageCaptureExportClient.self] = newValue }
	}
}
