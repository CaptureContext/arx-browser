import AppKit
import WebKit

/// A WebKit page's downloads (DEV-877): saved into the Downloads folder under a name that's
/// free, then shown in the Finder. They don't appear in Arx's Downloads list, which reads
/// Chromium's.
@MainActor
internal final class WebKitDownloads: NSObject {
	private var active: [ObjectIdentifier: (download: WKDownload, destination: URL?)] = [:]

	internal func adopt(_ download: WKDownload) {
		download.delegate = self
		active[ObjectIdentifier(download)] = (download, nil)
	}

	/// The first name in `folder` that's free: `name`, then `name 2`, `name 3`, …
	internal static func freeDestination(
		for name: String,
		in folder: URL,
		exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
	) -> URL {
		let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
		let file = safe.isEmpty ? "Download" : safe
		let base = (file as NSString).deletingPathExtension
		let suffix = (file as NSString).pathExtension
		var candidate = folder.appending(path: file)
		var number = 2
		while exists(candidate) {
			let numbered = suffix.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(suffix)"
			candidate = folder.appending(path: numbered)
			number += 1
		}
		return candidate
	}
}

extension WebKitDownloads: WKDownloadDelegate {
	internal func download(
		_ download: WKDownload,
		decideDestinationUsing response: URLResponse,
		suggestedFilename: String
	) async -> URL? {
		guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
		else { return nil }

		let destination = Self.freeDestination(for: suggestedFilename, in: folder)
		active[ObjectIdentifier(download)]?.destination = destination
		return destination
	}

	internal func downloadDidFinish(_ download: WKDownload) {
		let destination = active.removeValue(forKey: ObjectIdentifier(download))?.destination
		if let destination { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
	}

	internal func download(
		_ download: WKDownload,
		didFailWithError error: any Error,
		resumeData: Data?
	) {
		active[ObjectIdentifier(download)] = nil
	}
}
