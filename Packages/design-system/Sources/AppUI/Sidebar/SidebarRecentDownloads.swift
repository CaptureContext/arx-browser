import AppKit
import BrowserCore
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The window's recent downloads, which the Library button fans out above the footer on hover (DEV-758).
public struct SidebarRecentDownloads {
	/// How many rows fan out at most.
	public static let limit: Int = 5

	/// The window profile's downloads. Read while the rows draw, so only they redraw as downloads change.
	public var downloads: @MainActor () -> [BrowserDownload]

	/// Opens a download, as a click in the Library's Downloads panel does.
	public var open: @MainActor (BrowserDownload.ID) -> Void

	/// `true` while the button or its rows are hovered: the app keeps the downloads current only then.
	public var watchingChanged: @MainActor (Bool) -> Void

	public init(
		downloads: @escaping @MainActor () -> [BrowserDownload],
		open: @escaping @MainActor (BrowserDownload.ID) -> Void,
		watchingChanged: @escaping @MainActor (Bool) -> Void = { _ in }
	) {
		self.downloads = downloads
		self.open = open
		self.watchingChanged = watchingChanged
	}

	/// The rows to fan out: finished files that can still be opened, newest first.
	public static func recent(_ downloads: [BrowserDownload]) -> [BrowserDownload] {
		Array(
			downloads
				.filter(\.canOpen)
				.sorted { $0.startedAt > $1.startedAt }
				.prefix(limit)
		)
	}
}

/// The rows over the footer: newest nearest the button, each on the hover previews' material.
/// `isFanned` false tucks them down into the button, faded, so they fan out and collapse.
internal struct SidebarRecentDownloadsList: View {
	private let downloads: [BrowserDownload]
	private let now: Date
	private let isFanned: Bool
	private let open: (BrowserDownload.ID) -> Void

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(
		downloads: [BrowserDownload],
		now: Date,
		isFanned: Bool,
		open: @escaping (BrowserDownload.ID) -> Void
	) {
		self.downloads = downloads
		self.now = now
		self.isFanned = isFanned
		self.open = open
	}

	internal var body: some View {
		// Newest last, so it sits nearest the button.
		let rows = Array(downloads.reversed().enumerated())
		VStack(alignment: .leading, spacing: Metrics.spacing) {
			ForEach(rows, id: \.element.id) { index, download in
				let distance = rows.count - 1 - index
				SidebarRecentDownloadRow(download: download, now: now) { open(download.id) }
					.opacity(isFanned ? 1 : 0)
					.scaleEffect(isFanned || reduceMotion ? 1 : 0.92, anchor: .bottomLeading)
					.offset(y: isFanned || reduceMotion ? 0 : CGFloat(distance + 1) * Metrics.tuck)
					.animation(animation(distance: distance), value: isFanned)
			}
		}
		.padding(Metrics.inset)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.downloads.recent))
	}

	/// The nearest row moves first and the farther ones follow, so the stack fans out from the button.
	private func animation(distance: Int) -> Animation? {
		guard !reduceMotion else { return .easeOut(duration: 0.12) }
		let delay = isFanned ? Double(distance) * 0.035 : 0
		return .spring(response: 0.3, dampingFraction: 0.78).delay(delay)
	}

	private enum Metrics {
		internal static let spacing: CGFloat = 6

		/// Room round the rows for their shadow.
		internal static let inset: CGFloat = 8

		/// How far down each row tucks per step from the button while collapsed.
		internal static let tuck: CGFloat = 14
	}
}

/// One download: its thumbnail or icon, its name and how long ago it arrived. Hovering shows the full name.
internal struct SidebarRecentDownloadRow: View {
	private let download: BrowserDownload
	private let now: Date
	private let thumbnail: NSImage?
	private let open: () -> Void

	@SwiftUI.State
	private var isHovered: Bool

	internal init(
		download: BrowserDownload,
		now: Date,
		thumbnail: NSImage? = nil,
		open: @escaping () -> Void
	) {
		self.download = download
		self.now = now
		self.thumbnail = thumbnail
		self.open = open
		self._isHovered = .init(initialValue: false)
	}

	internal var body: some View {
		Button(action: open) {
			HStack(spacing: Metrics.spacing) {
				SidebarDownloadThumbnail(download: download, side: Metrics.thumbnail, thumbnail: thumbnail)
				VStack(alignment: .leading, spacing: 1) {
					Text(download.filename)
						.font(.system(size: 12, weight: .medium))
						.foregroundStyle(BrowserTheme.text)
						.lineLimit(1)
						.truncationMode(.middle)
					Text(Self.age(of: download.startedAt, now: now))
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
						.lineLimit(1)
				}
				Spacer(minLength: 0)
			}
			.padding(.horizontal, Metrics.padding)
			.frame(width: Metrics.width, height: Metrics.height)
			.background {
				ZStack {
					ArxControlShape().fill(.regularMaterial)
					if isHovered { ArxControlShape().fill(BrowserTheme.hover) }
				}
				.shadow(color: .black.opacity(0.1), radius: 6, y: 2)
			}
			.overlay {
				ArxControlShape()
					.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
			}
			.contentShape(ArxControlShape())
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
		.help(download.filename)
		.accessibilityLabel(download.filename)
		.accessibilityValue(Self.age(of: download.startedAt, now: now))
	}

	/// "5 minutes ago", "yesterday".
	internal static func age(
		of date: Date,
		now: Date
	) -> String {
		let formatter = RelativeDateTimeFormatter()
		formatter.dateTimeStyle = .named
		formatter.unitsStyle = .full
		return formatter.localizedString(for: min(date, now), relativeTo: now)
	}

	private enum Metrics {
		internal static let width: CGFloat = 240
		internal static let height: CGFloat = 44
		internal static let thumbnail: CGFloat = 30
		internal static let spacing: CGFloat = 9
		internal static let padding: CGFloat = 7
	}
}

/// A file's Quick Look thumbnail when it has one, as for pictures and PDFs, or else its icon.
internal struct SidebarDownloadThumbnail: View {
	private let download: BrowserDownload
	private let side: CGFloat

	/// A picture given up front, as snapshots do, in place of Quick Look's.
	private let preset: NSImage?

	@Environment(\.displayScale)
	private var displayScale

	@SwiftUI.State
	private var thumbnail: NSImage?

	/// `side` is the square the thumbnail fills; a wide or tall picture is cropped to it.
	internal init(
		download: BrowserDownload,
		side: CGFloat,
		thumbnail: NSImage? = nil
	) {
		self.download = download
		self.side = side
		self.preset = thumbnail
		self._thumbnail = .init(initialValue: nil)
	}

	internal var body: some View {
		Group {
			if let thumbnail = preset ?? thumbnail {
				Image(nsImage: thumbnail)
					.resizable()
					.scaledToFill()

					// The square first, so the clip crops the overflow of a wide or tall picture.
					.frame(width: side, height: side)
					.clipShape(.rect(cornerRadius: 5, style: .continuous))
			} else {
				Image(nsImage: icon)
					.resizable()
					.scaledToFit()
					.frame(width: side, height: side)
			}
		}
		.accessibilityHidden(true)
		.task(id: download.target) {
			guard preset == nil else { return }
			await loadThumbnail()
		}
	}

	private var icon: NSImage {
		if let target = download.target, download.canOpen {
			return NSWorkspace.shared.icon(forFile: target.path)
		}
		let type = UTType(filenameExtension: (download.filename as NSString).pathExtension)
		return NSWorkspace.shared.icon(for: type ?? .data)
	}

	private func loadThumbnail() async {
		guard let target = download.target, download.canOpen else {
			thumbnail = nil
			return
		}
		let request = QLThumbnailGenerator.Request(
			fileAt: target,
			size: .init(width: side, height: side),
			scale: displayScale,
			// Only a real picture of the file: anything else keeps its icon.
			representationTypes: .thumbnail
		)
		thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
	}
}
