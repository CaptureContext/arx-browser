import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// What a tab with no page of its own shows when its navigation became a download (DEV-1116):
/// the file, the site it came from and its progress, then what can be done with it. Calm on
/// purpose: a download isn't a page error. A cancelled or failed one says so plainly.
public struct BrowserDownloadingPage: View {
	public enum Action: Equatable, Sendable {
		case open
		case reveal
		case cancel
		case resume
		case retry
	}

	/// The name the engine gave the transfer when the navigation became it.
	private let filename: String

	/// The live transfer from the downloads queue, once it's there, or its last record once it
	/// was removed from the list.
	private let download: BrowserDownload?

	/// The transfer left the downloads list, so only Retry can do anything with it.
	private let isRemoved: Bool

	/// Why the last action didn't work, such as a file that couldn't open.
	private let message: String?
	private let send: @MainActor (Action) -> Void

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	public init(
		filename: String,
		download: BrowserDownload?,
		isRemoved: Bool = false,
		message: String? = nil,
		send: @escaping @MainActor (Action) -> Void
	) {
		self.filename = filename
		self.download = download
		self.isRemoved = isRemoved
		self.message = message
		self.send = send
	}

	public var body: some View {
		VStack(spacing: BrowserMetrics.DownloadingPage.spacing) {
			Image(nsImage: icon)
				.resizable()
				.scaledToFit()
				.frame(
					width: BrowserMetrics.DownloadingPage.iconSide,
					height: BrowserMetrics.DownloadingPage.iconSide
				)
				.accessibilityHidden(true)

			VStack(spacing: 4) {
				Text(name)
					.font(.title3.weight(.semibold))
					.foregroundStyle(BrowserTheme.text)
					.multilineTextAlignment(.center)
					.lineLimit(2)
					.truncationMode(.middle)
					.textSelection(.enabled)
				if let site {
					Text(String.localized(.appUI.downloadingPage.fromSite(site)))
						.font(.callout)
						.foregroundStyle(BrowserTheme.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}

			VStack(spacing: 6) {
				if phase.showsProgress {
					progress
				}
				Text(status)
					.font(.callout.monospacedDigit())
					.foregroundStyle(BrowserTheme.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
				if let message {
					Text(message)
						.font(.callout)
						.foregroundStyle(BrowserTheme.text)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: BrowserMetrics.DownloadingPage.progressWidth)
			.accessibilityElement(children: .combine)
			.accessibilityAddTraits(phase == .downloading ? .updatesFrequently : [])

			actions
				.controlSize(.large)
		}
		.padding(32)
		.frame(maxWidth: BrowserMetrics.DownloadingPage.width)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.animation(reduceMotion ? nil : .smooth(duration: 0.25), value: phase)
	}

	@ViewBuilder
	private var progress: some View {
		if phase == .downloading, let value = download?.progress {
			ProgressView(value: value)
				.progressViewStyle(.linear)
		} else if phase == .downloading || phase == .preparing {
			ProgressView()
				.progressViewStyle(.linear)
		} else {
			ProgressView(value: download?.progress ?? 0)
				.progressViewStyle(.linear)
		}
	}

	@ViewBuilder
	private var actions: some View {
		HStack(spacing: 10) {
			switch phase {
			case .preparing, .downloading, .blocked:
				Button(String.localized(.appUI.downloads.cancel)) { send(.cancel) }
			case .paused:
				Button(String.localized(.appUI.downloads.cancel)) { send(.cancel) }
				Button(String.localized(.appUI.downloads.resume)) { send(.resume) }
					.buttonStyle(.borderedProminent)
			case .downloaded:
				Button(String.localized(.appUI.downloads.reveal)) { send(.reveal) }
				Button(String.localized(.appUI.downloads.open)) { send(.open) }
					.buttonStyle(.borderedProminent)
			case .resumable:
				Button(String.localized(.appUI.downloads.resume)) { send(.resume) }
					.buttonStyle(.borderedProminent)
			case .missing, .removed, .cancelled, .failed:
				Button(String.localized(.appUI.viewer.retry)) { send(.retry) }
					.buttonStyle(.borderedProminent)
			}
		}
	}

	/// The transfer's state, as this page presents it.
	internal enum Phase: Equatable {
		case preparing
		case downloading
		case paused
		case blocked
		case downloaded
		case missing

		/// No longer in the downloads list.
		case removed
		case cancelled

		/// Interrupted, and Chromium can continue it from the bytes it kept.
		case resumable
		case failed

		internal var showsProgress: Bool {
			switch self {
			case .preparing, .downloading, .paused: true
			default: false
			}
		}
	}

	internal var phase: Phase {
		if isRemoved { return .removed }
		guard let download else { return .preparing }
		switch download.status {
		case .inProgress:
			if download.isDangerous { return .blocked }
			if download.isPaused { return .paused }
			return download.filename.isEmpty && download.receivedBytes == 0 ? .preparing : .downloading
		case .complete:
			return download.isMissing ? .missing : .downloaded
		case .cancelled:
			return .cancelled
		case .interrupted:
			return download.canResume ? .resumable : .failed
		}
	}

	private var name: String {
		if let download, !download.filename.isEmpty { return download.filename }
		if !filename.isEmpty { return filename }
		return String.localized(.appUI.downloads.preparing)
	}

	private var site: String? {
		download?.url?.host(percentEncoded: false)
	}

	internal var status: String {
		switch phase {
		case .preparing:
			return String.localized(.appUI.downloads.preparing)
		case .downloading:
			return byteProgress.map { String.localized(.appUI.downloadingPage.downloadingBytes($0)) }
			?? String.localized(.appUI.downloads.inProgress)
		case .paused:
			return byteProgress.map { String.localized(.appUI.downloadingPage.pausedBytes($0)) }
			?? String.localized(.appUI.downloads.paused)
		case .blocked:
			return String.localized(.appUI.downloads.blocked)
		case .downloaded:
			return size(download?.receivedBytes ?? 0).map { String.localized(.appUI.downloadingPage.downloadedBytes($0)) }
			?? String.localized(.appUI.downloadingPage.downloaded)
		case .missing:
			return String.localized(.appUI.downloads.missing)
		case .removed:
			return String.localized(.appUI.downloadingPage.removed)
		case .cancelled:
			return String.localized(.appUI.downloadingPage.cancelled)
		case .resumable, .failed:
			return String.localized(.appUI.downloadingPage.failed)
		}
	}

	/// "12 MB of 40 MB", or "12 MB" when the size isn't known.
	private var byteProgress: String? {
		guard let download, download.receivedBytes > 0 else { return nil }
		let received = ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file)
		guard download.totalBytes > 0 else { return received }
		let total = ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file)
		return String.localized(.appUI.downloadingPage.bytesOf(received, total))
	}

	private func size(_ bytes: Int64) -> String? {
		bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : nil
	}

	private var icon: NSImage {
		if let download, let target = download.target, download.canOpen {
			return NSWorkspace.shared.icon(forFile: target.path)
		}
		let type = UTType(filenameExtension: (name as NSString).pathExtension)
		return NSWorkspace.shared.icon(for: type ?? .data)
	}
}
