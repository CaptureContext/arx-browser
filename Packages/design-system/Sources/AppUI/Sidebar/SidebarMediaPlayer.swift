import BrowserCore
import SwiftUI

/// What a tab in the window plays, at the bottom of the sidebar (DEV-906): the page's artwork (or
/// the site's icon), the title Media Session gives (or the tab's), play or pause, and the next
/// track when the page has one. Hovering grows it to show the artist (or the site), the previous
/// track, and where playback is, as a bar that seeks when the page allows it. Clicking it opens
/// the tab. Right-clicking it shows `menu` (DEV-1106).
public struct SidebarMediaPlayer<Menu: View>: View {
	public typealias Progress = SidebarMediaPlayerProgress

	private let item: SidebarMediaItem
	private let canSeek: Bool
	private let progress: @MainActor () -> Progress?
	private let onPlayPause: () -> Void
	private let onPreviousTrack: () -> Void
	private let onNextTrack: () -> Void
	private let onSeek: (Double) -> Void
	private let onOpen: () -> Void

	/// Cast… the tab (DEV-927); nil hides it, as when the engine can't cast.
	private let onCast: (() -> Void)?
	private let menu: Menu

	@SwiftUI.State
	private var isPointerInside: Bool

	@Environment(\.sidebarMediaHover)
	private var hoverOverride

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	public init(
		item: SidebarMediaItem,
		canSeek: Bool,
		progress: @escaping @MainActor () -> Progress?,
		onPlayPause: @escaping () -> Void,
		onPreviousTrack: @escaping () -> Void = {},
		onNextTrack: @escaping () -> Void = {},
		onSeek: @escaping (Double) -> Void,
		onOpen: @escaping () -> Void,
		onCast: (() -> Void)? = nil,
		@ViewBuilder menu: () -> Menu
	) {
		self.item = item
		self.canSeek = canSeek
		self.progress = progress
		self.onPlayPause = onPlayPause
		self.onPreviousTrack = onPreviousTrack
		self.onNextTrack = onNextTrack
		self.onSeek = onSeek
		self.onOpen = onOpen
		self.onCast = onCast
		self.menu = menu()
		self._isPointerInside = .init(initialValue: false)
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: BrowserMetrics.Row.iconSpacing) {
				SidebarMediaPlayerArtwork(artwork: item.artwork, siteIcon: item.siteIcon)
				VStack(alignment: .leading, spacing: 0) {
					Text(item.title)
						.font(.system(size: BrowserMetrics.Row.fontSize, weight: .medium))
						.lineLimit(1)
					if hovered, !detail.isEmpty {
						Text(detail)
							.font(.system(size: BrowserMetrics.Row.fontSize - 2))
							.foregroundStyle(BrowserTheme.secondary)
							.lineLimit(1)
							.transition(hoverContent)
					}
				}
				Spacer(minLength: 0)
				if hovered, let onCast {
					control(
						"tv.badge.wifi",
						title: String.localized(.appUI.cast.mediaButton),
						action: onCast
					)
					.transition(hoverContent)
				}
				if hovered, item.canPreviousTrack {
					control(
						"backward.fill",
						title: String.localized(.appUI.media.previousTrack),
						action: onPreviousTrack
					)
					.transition(hoverContent)
				}
				control(
					item.playback == .playing ? "pause.fill" : "play.fill",
					title: playPauseTitle,
					action: onPlayPause
				)
				.disabled(!(item.playback == .playing ? item.canPause : item.canPlay))
				if item.canNextTrack {
					control(
						"forward.fill",
						title: String.localized(.appUI.media.nextTrack),
						action: onNextTrack
					)
				}
			}
			if hovered {
				TimelineView(.periodic(from: .now, by: 1)) { _ in
					SidebarMediaPlayerBar(progress: progress(), canSeek: canSeek, onSeek: onSeek)
				}
				.transition(hoverContent)
			}
		}
		.foregroundStyle(BrowserTheme.text)
		.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
		.padding(.vertical, 6)
		.background(BrowserTheme.hover, in: Self.shape)

		// What hovering adds is laid out at once where it ends up, while the background's frame
		// grows to it over the animation, so it showed outside the background (DEV-1244). The
		// clip keeps every frame inside the background, and the content fades in as it fills.
		.clipShape(Self.shape)
		.contentShape(.rect)
		.onTapGesture(perform: onOpen)
		.contextMenu { menu }
		.onHover { isHovered in
			withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isPointerInside = isHovered }
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(item.title)
		.accessibilityAction(named: Text(localized: .appUI.media.returnToTab), onOpen)
		.accessibilityAction(named: Text(localized: .appUI.cast.mediaButton)) { onCast?() }
	}

	private static var shape: RoundedRectangle {
		.rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
	}

	/// What hovering adds fades in once the background is most of the way to its frame, and goes
	/// at once on the way out, so it's never seen outside the background (DEV-1244). With Reduce
	/// Motion it comes and goes at once, as the hover itself does.
	private var hoverContent: AnyTransition {
		guard !reduceMotion else { return .identity }
		return .asymmetric(
			insertion: .opacity.animation(.easeOut(duration: 0.12).delay(0.08)),
			removal: .opacity.animation(.easeOut(duration: 0.06))
		)
	}

	private var hovered: Bool {
		hoverOverride ?? isPointerInside
	}

	/// The artist when the page names one, the site otherwise.
	private var detail: String {
		item.artist.isEmpty ? item.subtitle : item.artist
	}

	private func control(
		_ symbol: String,
		title: String,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 12, weight: .semibold))
				.frame(width: 24, height: 24)
		}
		.buttonStyle(ChromeButtonStyle())
		.help(title)
		.accessibilityLabel(title)
	}

	private var playPauseTitle: String {
		item.playback == .playing
		? String.localized(.appUI.media.pause)
		: String.localized(.appUI.media.play)
	}
}

/// Where the sidebar player's playback is, read as the bar draws: seconds in, and the length
/// when it's known.
public struct SidebarMediaPlayerProgress: Equatable, Sendable {
	public var position: Double
	public var duration: Double

	public init(
		position: Double,
		duration: Double
	) {
		self.position = position
		self.duration = duration
	}
}

extension SidebarMediaPlayer where Menu == EmptyView {
	public init(
		item: SidebarMediaItem,
		canSeek: Bool,
		progress: @escaping @MainActor () -> Progress?,
		onPlayPause: @escaping () -> Void,
		onPreviousTrack: @escaping () -> Void = {},
		onNextTrack: @escaping () -> Void = {},
		onSeek: @escaping (Double) -> Void,
		onOpen: @escaping () -> Void,
		onCast: (() -> Void)? = nil
	) {
		self.init(
			item: item,
			canSeek: canSeek,
			progress: progress,
			onPlayPause: onPlayPause,
			onPreviousTrack: onPreviousTrack,
			onNextTrack: onNextTrack,
			onSeek: onSeek,
			onOpen: onOpen,
			onCast: onCast,
			menu: { EmptyView() }
		)
	}
}

/// The page's artwork, cropped to fill the icon's square, or the site's icon without it.
private struct SidebarMediaPlayerArtwork: View {
	internal let artwork: Data?
	internal let siteIcon: SidebarItem.SiteIcon?

	internal var body: some View {
		Group {
			if let image = artwork.flatMap(NSImage.init(data:)) {
				Image(nsImage: image)
					.resizable()
					.interpolation(.high)
					.aspectRatio(contentMode: .fill)
					.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
					.clipShape(.rect(cornerRadius: 3, style: .continuous))
					.accessibilityHidden(true)
			} else {
				FavoriteSiteIcon(
					key: siteIcon,
					fallback: "music.note",
					tint: .lavender,
					size: BrowserMetrics.Row.iconSize,
					fallbackSize: BrowserMetrics.Row.iconSize - 2,
					fallbackWeight: .medium,
					showsPlaceholder: true
				)
			}
		}
		.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
	}
}

/// Where playback is: elapsed time, a bar, and the length.
private struct SidebarMediaPlayerBar: View {
	internal let progress: SidebarMediaPlayerProgress?
	internal let canSeek: Bool
	internal let onSeek: (Double) -> Void

	internal var body: some View {
		HStack(spacing: 6) {
			Text(verbatim: Self.time(progress?.position))
			GeometryReader { geometry in
				ZStack(alignment: .leading) {
					Capsule().fill(BrowserTheme.secondary.opacity(0.3))
					Capsule()
						.fill(BrowserTheme.accent)
						.frame(width: geometry.size.width * fraction)
				}
				.frame(height: 3)
				.frame(maxHeight: .infinity)
				.contentShape(.rect)
				.onTapGesture { location in
					guard
						canSeek,
						let progress,
						progress.duration > 0,
						geometry.size.width > 0
					else { return }
					onSeek(progress.duration * min(max(location.x / geometry.size.width, 0), 1))
				}
			}
			.frame(height: 12)
			Text(verbatim: Self.time(progress?.duration))
		}
		.font(.system(size: 10).monospacedDigit())
		.foregroundStyle(BrowserTheme.secondary)
		.accessibilityElement(children: .ignore)
		.accessibilityValue(Text(verbatim: "\(Self.time(progress?.position)) / \(Self.time(progress?.duration))"))
	}

	private var fraction: CGFloat {
		guard let progress, progress.duration > 0 else { return 0 }
		return CGFloat(min(max(progress.position / progress.duration, 0), 1))
	}

	private static func time(_ seconds: Double?) -> String {
		guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
		let total = Int(seconds.rounded(.down))
		let hours = total / 3600
		let minutes = total / 60 % 60
		let rest = total % 60
		return hours > 0
		? String(format: "%d:%02d:%02d", hours, minutes, rest)
		: String(format: "%d:%02d", minutes, rest)
	}
}
