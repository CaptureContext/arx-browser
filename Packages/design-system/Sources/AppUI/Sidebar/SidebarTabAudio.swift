import AppKit
import SwiftUI

/// Sizes of a tab's speaker and its volume controls (DEV-800).
public enum SidebarTabAudioMetrics {
	/// The speaker button, as wide as the row's trailing close button.
	public static let indicatorSize: CGFloat = 22
	public static let indicatorSymbolSize: CGFloat = 11
	public static let popoverWidth: CGFloat = 232
	public static let popoverPadding: CGFloat = 12
	public static let sliderSpacing: CGFloat = 6

	/// Room for "100%".
	public static let percentWidth: CGFloat = 36
	public static let percentFontSize: CGFloat = 11
}

/// A volume slider, 0 to 100%, with the speaker that mutes in front of it when `onMute` is set.
/// The tab's speaker popover and the Media page's rows share it (DEV-800).
public struct BrowserTabVolumeSlider: View {
	private let isMuted: Bool
	private let volume: Double
	private let onMute: (() -> Void)?
	private let onVolume: (Double) -> Void

	public init(
		isMuted: Bool,
		volume: Double,
		onMute: (() -> Void)? = nil,
		onVolume: @escaping (Double) -> Void
	) {
		self.isMuted = isMuted
		self.volume = volume
		self.onMute = onMute
		self.onVolume = onVolume
	}

	public var body: some View {
		HStack(spacing: SidebarTabAudioMetrics.sliderSpacing) {
			if let onMute {
				let title = isMuted
				? String.localized(.appUI.media.unmuteTab)
				: String.localized(.appUI.media.muteTab)
				Button(action: onMute) {
					Image(systemName: SidebarItem.Audio.symbol(isMuted: isMuted, volume: volume))
						.font(.system(size: SidebarTabAudioMetrics.indicatorSymbolSize, weight: .semibold))
						.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
						.frame(
							width: SidebarTabAudioMetrics.indicatorSize,
							height: SidebarTabAudioMetrics.indicatorSize
						)
						.contentShape(.rect)
				}
				.buttonStyle(ChromeButtonStyle())
				.help(title)
				.accessibilityLabel(title)
			}
			Slider(
				value: Binding(get: { volume }, set: { onVolume(min(max($0, 0), 1)) }),
				in: 0...1
			)
			.controlSize(.mini)
			.accessibilityLabel(String.localized(.appUI.media.volume))
			.accessibilityValue(Text(volume, format: .percent.precision(.fractionLength(0))))
			Text(volume, format: .percent.precision(.fractionLength(0)))
				.font(.system(size: SidebarTabAudioMetrics.percentFontSize).monospacedDigit())
				.foregroundStyle(BrowserTheme.text.opacity(isMuted ? 0.4 : BrowserMetrics.Library.subtitleOpacity))
				.frame(width: SidebarTabAudioMetrics.percentWidth, alignment: .trailing)
				.accessibilityHidden(true)
		}
		.opacity(isMuted ? 0.7 : 1)
	}
}

/// The popover from a tab's speaker: its title and the volume slider.
public struct SidebarTabVolumePopover: View {
	private let title: String
	private let audio: SidebarItem.Audio
	private let onMute: () -> Void
	private let onVolume: (Double) -> Void

	public init(
		title: String,
		audio: SidebarItem.Audio,
		onMute: @escaping () -> Void,
		onVolume: @escaping (Double) -> Void
	) {
		self.title = title
		self.audio = audio
		self.onMute = onMute
		self.onVolume = onVolume
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(String.localized(.appUI.media.volume))
				.font(.system(size: BrowserMetrics.Library.fontSize, weight: .semibold))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.titleOpacity))
			Text(title)
				.font(.system(size: BrowserMetrics.Library.fontSize))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.subtitleOpacity))
				.lineLimit(1)
				.truncationMode(.tail)
			BrowserTabVolumeSlider(
				isMuted: audio.isMuted,
				volume: audio.volume ?? 1,
				onMute: onMute,
				onVolume: onVolume
			)
		}
		.padding(SidebarTabAudioMetrics.popoverPadding)
		.frame(width: SidebarTabAudioMetrics.popoverWidth, alignment: .leading)
	}
}

/// A tab row's speaker. When the engine can turn a tab down, a click opens the tab's volume popover
/// (its mute toggle and slider) and an Option-click mutes or unmutes at once; otherwise a click mutes
/// or unmutes.
internal struct SidebarTabAudioButton: View {
	private let audio: SidebarItem.Audio
	private let onMute: () -> Void
	private let onShowVolume: () -> Void

	internal init(
		audio: SidebarItem.Audio,
		onMute: @escaping () -> Void,
		onShowVolume: @escaping () -> Void
	) {
		self.audio = audio
		self.onMute = onMute
		self.onShowVolume = onShowVolume
	}

	internal var body: some View {
		let title = audio.isMuted
		? String.localized(.appUI.media.unmuteTab)
		: String.localized(.appUI.media.muteTab)
		Button {
			if audio.volume == nil || NSEvent.actionModifierFlags.contains(.option) {
				onMute()
			} else {
				onShowVolume()
			}
		} label: {
			Image(systemName: audio.symbol)
				.font(.system(size: SidebarTabAudioMetrics.indicatorSymbolSize, weight: .semibold))
				.foregroundStyle(BrowserTheme.text.opacity(audio.isMuted ? 0.5 : BrowserMetrics.Library.labelOpacity))
				.frame(width: SidebarTabAudioMetrics.indicatorSize, height: SidebarTabAudioMetrics.indicatorSize)
				.contentShape(.rect)
		}
		.buttonStyle(ChromeButtonStyle())
		.help(audio.volume == nil ? title : String.localized(.appUI.media.volumeHelp))

		// The default action is what a click does: the volume popover when there's volume, else mute.
		.accessibilityLabel(audio.volume == nil ? title : String.localized(.appUI.media.volume))
		.accessibilityActions {
			if audio.volume != nil {
				Button(title, action: onMute)
			}
		}
	}
}
