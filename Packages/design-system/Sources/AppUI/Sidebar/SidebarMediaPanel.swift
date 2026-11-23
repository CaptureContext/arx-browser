import BrowserCore
import SwiftUI

/// One playing page as the Library's Media page lists it.
public struct SidebarMediaItem: Identifiable, Equatable, Sendable {
	public enum Playback: Equatable, Sendable {
		case playing
		case paused
		case inactive
		case pictureInPicture
	}

	public var id: BrowserMediaSource.ID
	public var title: String

	/// The site, such as `youtube.com`.
	public var subtitle: String

	/// The page's Media Session artist, empty when it names none (DEV-906).
	public var artist: String

	/// The page's Media Session artwork as PNG bytes; the site's icon stands in without it.
	public var artwork: Data?
	public var siteIcon: SidebarItem.SiteIcon?
	public var playback: Playback
	public var canPlay: Bool
	public var canPause: Bool
	public var canPreviousTrack: Bool
	public var canNextTrack: Bool
	public var isMuted: Bool

	/// The tab's volume, 0 to 1, or nil when the engine can't turn a tab down (DEV-800).
	public var volume: Double?
	public var canReturn: Bool

	/// Nil unless the page is in a call (DEV-948).
	public var call: Call?

	/// A call's controls, as its site offers them, and its microphone and camera as the site
	/// reports them (nil when it doesn't).
	public struct Call: Equatable, Sendable {
		public var isMicrophoneOn: Bool?
		public var isCameraOn: Bool?
		public var canToggleMicrophone: Bool
		public var canToggleCamera: Bool
		public var canHangUp: Bool

		public init(
			isMicrophoneOn: Bool? = nil,
			isCameraOn: Bool? = nil,
			canToggleMicrophone: Bool = false,
			canToggleCamera: Bool = false,
			canHangUp: Bool = false
		) {
			self.isMicrophoneOn = isMicrophoneOn
			self.isCameraOn = isCameraOn
			self.canToggleMicrophone = canToggleMicrophone
			self.canToggleCamera = canToggleCamera
			self.canHangUp = canHangUp
		}
	}

	/// A call control on a row.
	public enum CallControl: Equatable, Sendable {
		case microphone
		case camera
		case hangUp
	}

	public init(
		id: BrowserMediaSource.ID,
		title: String,
		subtitle: String,
		artist: String = "",
		artwork: Data? = nil,
		siteIcon: SidebarItem.SiteIcon? = nil,
		playback: Playback,
		canPlay: Bool = false,
		canPause: Bool = false,
		canPreviousTrack: Bool = false,
		canNextTrack: Bool = false,
		isMuted: Bool = false,
		volume: Double? = nil,
		canReturn: Bool = true,
		call: Call? = nil
	) {
		self.id = id
		self.title = title
		self.subtitle = subtitle
		self.artist = artist
		self.artwork = artwork
		self.siteIcon = siteIcon
		self.playback = playback
		self.canPlay = canPlay
		self.canPause = canPause
		self.canPreviousTrack = canPreviousTrack
		self.canNextTrack = canNextTrack
		self.isMuted = isMuted
		self.volume = volume
		self.canReturn = canReturn
		self.call = call
	}
}

/// The Library's Media page: what plays in the window's profile, with play or pause, mute,
/// the tab's volume, and a click on the row to go back to its tab.
public struct SidebarMediaPanel<RowMenu: View>: View {
	private let items: [SidebarMediaItem]
	private let notice: String?
	private let isBusy: Bool
	private let onPlayPause: (SidebarMediaItem) -> Void
	private let onMute: (SidebarMediaItem) -> Void
	private let onVolume: (SidebarMediaItem, Double) -> Void
	private let onReturn: (SidebarMediaItem) -> Void
	private let onCall: (SidebarMediaItem, SidebarMediaItem.CallControl) -> Void
	private let rowMenu: (SidebarMediaItem) -> RowMenu

	public init(
		items: [SidebarMediaItem],
		notice: String? = nil,
		isBusy: Bool = false,
		onPlayPause: @escaping (SidebarMediaItem) -> Void,
		onMute: @escaping (SidebarMediaItem) -> Void,
		onVolume: @escaping (SidebarMediaItem, Double) -> Void = { _, _ in },
		onReturn: @escaping (SidebarMediaItem) -> Void,
		onCall: @escaping (SidebarMediaItem, SidebarMediaItem.CallControl) -> Void = { _, _ in },
		@ViewBuilder rowMenu: @escaping (SidebarMediaItem) -> RowMenu
	) {
		self.items = items
		self.notice = notice
		self.isBusy = isBusy
		self.onPlayPause = onPlayPause
		self.onMute = onMute
		self.onVolume = onVolume
		self.onReturn = onReturn
		self.onCall = onCall
		self.rowMenu = rowMenu
	}

	public var body: some View {
		VStack(spacing: 0) {
			if items.isEmpty {
				title
				SidebarMediaEmptyState()
					.padding(.horizontal, BrowserMetrics.Library.headerInset)
					.padding(.top, BrowserMetrics.Library.groupTopPadding)
			} else {
				ScrollView {
					LazyVStack(spacing: 0) {
						ForEach(items) { item in
							SidebarMediaRow(
								item: item,
								isBusy: isBusy,
								onPlayPause: { onPlayPause(item) },
								onMute: { onMute(item) },
								onVolume: { onVolume(item, $0) },
								onReturn: { onReturn(item) },
								onCall: { onCall(item, $0) }
							)
							.contextMenu { rowMenu(item) }
						}
					}
					.padding(.bottom, 12)
				}
				.scrollIndicators(.hidden)
				.scrollBounceBehavior(.basedOnSize, axes: .vertical)

				// Media scrolls under the title into Arx's progressive edge, with no line (DEV-807, DEV-826).
				.arxScrollBar(background: nil) { title }
			}

			Spacer(minLength: 0)

			if let notice {
				Text(notice)
					.font(.system(size: BrowserMetrics.Library.fontSize))
					.foregroundStyle(BrowserTheme.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(BrowserMetrics.Library.headerInset)
			}
		}
	}

	private var title: some View {
		Text(LibrarySection.media.title)
			.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .semibold))
			.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
			.frame(maxWidth: .infinity, minHeight: BrowserMetrics.Library.fieldHeight, alignment: .leading)
			.padding(.horizontal, BrowserMetrics.Library.headerInset + BrowserMetrics.Library.groupInset / 2)
			.padding(.bottom, BrowserMetrics.Library.headerBottomPadding)
			.accessibilityAddTraits(.isHeader)
	}
}

extension SidebarMediaPanel where RowMenu == EmptyView {
	public init(
		items: [SidebarMediaItem],
		notice: String? = nil,
		isBusy: Bool = false,
		onPlayPause: @escaping (SidebarMediaItem) -> Void,
		onMute: @escaping (SidebarMediaItem) -> Void,
		onVolume: @escaping (SidebarMediaItem, Double) -> Void = { _, _ in },
		onReturn: @escaping (SidebarMediaItem) -> Void,
		onCall: @escaping (SidebarMediaItem, SidebarMediaItem.CallControl) -> Void = { _, _ in }
	) {
		self.init(
			items: items,
			notice: notice,
			isBusy: isBusy,
			onPlayPause: onPlayPause,
			onMute: onMute,
			onVolume: onVolume,
			onReturn: onReturn,
			onCall: onCall,
			rowMenu: { _ in EmptyView() }
		)
	}
}

/// Nothing plays: a quiet line where the rows would be, as the Library's other pages say they're empty.
private struct SidebarMediaEmptyState: View {
	fileprivate var body: some View {
		VStack(spacing: 6) {
			Image(systemName: BrowserCommand.media.symbol)
				.font(.system(size: BrowserMetrics.Library.fieldFontSize, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
			Text(String.localized(.appUI.media.empty))
				.font(.system(size: BrowserMetrics.Row.fontSize, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
			Text(String.localized(.appUI.media.emptyDescription))
				.font(.system(size: BrowserMetrics.Library.fontSize))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, BrowserMetrics.Library.groupTopPadding)
		.background(
			BrowserTheme.libraryTint.opacity(BrowserMetrics.Library.fieldOpacity),
			in: .rect(cornerRadius: BrowserMetrics.Library.tileCornerRadius, style: .continuous)
		)
		.accessibilityElement(children: .combine)
	}
}

/// A Library row with the sidebar's toolbar buttons at its end. The row itself goes back to the tab.
private struct SidebarMediaRow: View {
	private let item: SidebarMediaItem
	private let isBusy: Bool
	private let onPlayPause: () -> Void
	private let onMute: () -> Void
	private let onVolume: (Double) -> Void
	private let onReturn: () -> Void
	private let onCall: (SidebarMediaItem.CallControl) -> Void

	@SwiftUI.State
	private var isHovered: Bool

	fileprivate init(
		item: SidebarMediaItem,
		isBusy: Bool,
		onPlayPause: @escaping () -> Void,
		onMute: @escaping () -> Void,
		onVolume: @escaping (Double) -> Void,
		onReturn: @escaping () -> Void,
		onCall: @escaping (SidebarMediaItem.CallControl) -> Void
	) {
		self.item = item
		self.isBusy = isBusy
		self.onPlayPause = onPlayPause
		self.onMute = onMute
		self.onVolume = onVolume
		self.onReturn = onReturn
		self.onCall = onCall
		self._isHovered = .init(initialValue: false)
	}

	fileprivate var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			controls
			if let volume = item.volume {
				// Under the title, past the site icon; the row's speaker already mutes.
				BrowserTabVolumeSlider(isMuted: item.isMuted, volume: volume, onVolume: onVolume)
					.padding(.leading, BrowserMetrics.Library.rowIconSize + BrowserMetrics.Library.rowIconSpacing)
					.padding(.bottom, 6)
			}
		}
		.padding(.leading, BrowserMetrics.Row.horizontalPadding)
		.padding(.trailing, BrowserMetrics.Toolbar.spacing * 2)
		.frame(minHeight: BrowserMetrics.Library.rowHeight)
		.background(
			isHovered ? BrowserTheme.hover : .clear,
			in: .rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
		)
		.onHover { isHovered = $0 }
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		.accessibilityElement(children: .contain)
	}

	private var controls: some View {
		HStack(spacing: BrowserMetrics.Toolbar.spacing) {
			Button(action: onReturn) {
				HStack(spacing: BrowserMetrics.Library.rowIconSpacing) {
					SidebarLibrarySiteIcon(key: item.siteIcon)
						.frame(
							width: BrowserMetrics.Library.rowIconSize,
							height: BrowserMetrics.Library.rowIconSize
						)
					VStack(alignment: .leading, spacing: 2) {
						Text(item.title)
							.font(.system(size: BrowserMetrics.Library.rowFontSize))
							.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
							.lineLimit(1)
							.truncationMode(.tail)
						Text(subtitle)
							.font(.system(size: BrowserMetrics.Library.fontSize))
							.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
							.lineLimit(1)
					}
					Spacer(minLength: 0)
				}
				.contentShape(.rect)
			}
			.buttonStyle(.plain)
			.focusEffectDisabled()
			.disabled(!item.canReturn || isBusy)
			.help(String.localized(.appUI.media.returnToTab))
			.accessibilityLabel(item.title)
			.accessibilityValue(subtitle)
			.accessibilityHint(String.localized(.appUI.media.returnToTab))

			if item.canPlay || item.canPause {
				let title = item.canPause
				? String.localized(.appUI.media.pause)
				: String.localized(.appUI.media.play)
				Button(action: onPlayPause) {
					Image(systemName: item.canPause ? "pause.fill" : "play.fill")
						.font(.system(size: BrowserMetrics.Toolbar.symbolSize - 3, weight: .semibold))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
				}
				.buttonStyle(BrowserToolbarButtonStyle())
				.disabled(isBusy)
				.help(title)
				.accessibilityLabel(title)
			}

			if let call = item.call {
				SidebarMediaCallControls(call: call, isBusy: isBusy, onCall: onCall)
			}

			let muteTitle = item.isMuted
			? String.localized(.appUI.media.unmute)
			: String.localized(.appUI.media.mute)
			Button(action: onMute) {
				Image(systemName: SidebarItem.Audio.symbol(isMuted: item.isMuted, volume: item.volume ?? 1))
					.font(.system(size: BrowserMetrics.Toolbar.symbolSize - 3, weight: .semibold))
					.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
			}
			.buttonStyle(BrowserToolbarButtonStyle())
			.help(muteTitle)
			.accessibilityLabel(muteTitle)
		}
		.frame(minHeight: BrowserMetrics.Library.rowHeight)
	}

	/// The site, then how it plays: "youtube.com · Paused".
	private var subtitle: String {
		let status: String = switch item.playback {
		case .playing where item.call != nil: String.localized(.appUI.media.inCall)
		case .playing: String.localized(.appUI.media.playing)
		case .paused: String.localized(.appUI.media.paused)
		case .inactive: String.localized(.appUI.media.inactive)
		case .pictureInPicture: String.localized(.appUI.media.inPicture)
		}
		return [item.subtitle, status].filter { !$0.isEmpty }.joined(separator: " · ")
	}
}

/// A call's microphone, camera and Leave Call, at the end of its row (DEV-948). Each shows the
/// state the site reports, and a plain symbol when it doesn't report one.
private struct SidebarMediaCallControls: View {
	internal let call: SidebarMediaItem.Call
	internal let isBusy: Bool
	internal let onCall: (SidebarMediaItem.CallControl) -> Void

	internal var body: some View {
		if call.canToggleMicrophone {
			button(
				symbol: call.isMicrophoneOn == false ? "mic.slash.fill" : "mic.fill",
				title: microphoneTitle,
				control: .microphone
			)
		}
		if call.canToggleCamera {
			button(
				symbol: call.isCameraOn == false ? "video.slash.fill" : "video.fill",
				title: cameraTitle,
				control: .camera
			)
		}
		if call.canHangUp {
			button(
				symbol: "phone.down.fill",
				title: String.localized(.appUI.media.hangUp),
				control: .hangUp,
				tint: .red
			)
		}
	}

	private var microphoneTitle: String {
		switch call.isMicrophoneOn {
		case true?: String.localized(.appUI.media.muteMicrophone)
		case false?: String.localized(.appUI.media.unmuteMicrophone)
		case nil: String.localized(.appUI.media.microphone)
		}
	}

	private var cameraTitle: String {
		switch call.isCameraOn {
		case true?: String.localized(.appUI.media.turnOffCamera)
		case false?: String.localized(.appUI.media.turnOnCamera)
		case nil: String.localized(.appUI.media.camera)
		}
	}

	private func button(
		symbol: String,
		title: String,
		control: SidebarMediaItem.CallControl,
		tint: Color? = nil
	) -> some View {
		Button { onCall(control) } label: {
			Image(systemName: symbol)
				.font(.system(size: BrowserMetrics.Toolbar.symbolSize - 3, weight: .semibold))
				.foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(
					BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity)
				))
				.contentTransition(.symbolEffect(.replace))
		}
		.buttonStyle(BrowserToolbarButtonStyle())
		.disabled(isBusy)
		.help(title)
		.accessibilityLabel(title)
	}
}
