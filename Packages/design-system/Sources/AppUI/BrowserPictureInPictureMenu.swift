import BrowserCore
import SwiftUI

/// Whether media can be presented in Media PiP (DEV-1106). Media that can't is still offered,
/// disabled, with the reason as its help.
public enum BrowserMediaPictureInPicture: Equatable, Sendable {
	case available
	case unavailable(reason: String)

	public var isAvailable: Bool { self == .available }

	public var reason: String? {
		guard case let .unavailable(reason) = self else { return nil }

		return reason
	}
}

/// What a tab's menu presents in Picture in Picture (DEV-1105, DEV-1106). The window that shows
/// the menu supplies it; without it the menu has no Picture in Picture items.
public struct BrowserPictureInPictureActions: Sendable {
	/// Whether the tab has a page Page PiP can float: a chat tab has none.
	public var canPresentTab: @MainActor @Sendable (UUID) -> Bool

	/// Floats the tab's live page in Page PiP. The tab stays where it is.
	public var presentTab: @MainActor @Sendable (UUID) -> Void

	/// The tab's playing media and whether it can float in Media PiP; `nil` while the tab plays
	/// nothing, which leaves the item out.
	public var media: @MainActor @Sendable (UUID) -> BrowserMediaPictureInPicture?

	/// Floats the tab's video in Media PiP.
	public var presentMedia: @MainActor @Sendable (UUID) -> Void

	/// The tab's own automatic Picture in Picture choice (DEV-1246); `nil` leaves it out, as in
	/// a private window, whose media never floats on its own.
	public var automaticChoice: @MainActor @Sendable (UUID) -> AutomaticPiPPreferences.TabChoice?

	/// Sets the tab's automatic Picture in Picture choice.
	public var setAutomaticChoice: @MainActor @Sendable (UUID, AutomaticPiPPreferences.TabChoice) -> Void

	public init(
		canPresentTab: @escaping @MainActor @Sendable (UUID) -> Bool,
		presentTab: @escaping @MainActor @Sendable (UUID) -> Void,
		media: @escaping @MainActor @Sendable (UUID) -> BrowserMediaPictureInPicture? = { _ in nil },
		presentMedia: @escaping @MainActor @Sendable (UUID) -> Void = { _ in },
		automaticChoice: @escaping @MainActor @Sendable (UUID) -> AutomaticPiPPreferences.TabChoice? = { _ in nil },
		setAutomaticChoice: @escaping @MainActor @Sendable (UUID, AutomaticPiPPreferences.TabChoice) -> Void = { _, _ in }
	) {
		self.canPresentTab = canPresentTab
		self.presentTab = presentTab
		self.media = media
		self.presentMedia = presentMedia
		self.automaticChoice = automaticChoice
		self.setAutomaticChoice = setAutomaticChoice
	}
}

extension EnvironmentValues {
	@Entry
	public var browserPictureInPictureActions: BrowserPictureInPictureActions? = nil
}

/// A tab's Picture in Picture items (DEV-1105, DEV-1106): Present Media in Picture in Picture
/// while it plays, then Present Tab in Picture in Picture. "Present", not "move": the tab keeps
/// its place, and Picture in Picture only shows it. Each is a command too.
///
/// In a tab's context menu they sit in a Picture in Picture submenu (DEV-1250), with the tab's
/// own automatic Picture in Picture choice below them (DEV-1246): whether its media floats on its
/// own when you leave it, and what floats.
public struct BrowserPictureInPictureMenu: View {
	/// One of the menu's items, as it shows.
	public struct Item: Equatable, Sendable {
		public enum Kind: Equatable, Hashable, Sendable {
			case media
			case tab
		}

		public var kind: Kind
		public var title: String
		public var isEnabled: Bool
		public var help: String?
	}

	private let tabID: UUID
	private let nests: Bool

	@Environment(\.browserPictureInPictureActions)
	private var actions

	/// - Parameters:
	///   - nests: whether the items sit in a Picture in Picture submenu with the tab's
	///     automatic choice, as in a tab's context menu (DEV-1250).
	public init(
		tabID: UUID,
		nests: Bool = false
	) {
		self.tabID = tabID
		self.nests = nests
	}

	public var body: some View {
		if let actions {
			let items = Self.items(media: actions.media(tabID), canPresentTab: actions.canPresentTab(tabID))
			let choice = nests ? actions.automaticChoice(tabID) : nil
			if nests, !items.isEmpty || choice != nil {
				Menu(String.localized(.appUI.media.tabPicture.menu)) {
					presentItems(items, actions)
					if let choice {
						if !items.isEmpty { Divider() }
						automaticItems(choice, actions)
					}
				}
			} else if !nests {
				presentItems(items, actions)
			}
		}
	}

	private func presentItems(
		_ items: [Item],
		_ actions: BrowserPictureInPictureActions
	) -> some View {
		ForEach(items, id: \.kind) { item in
			Button(item.title) {
				switch item.kind {
				case .media: actions.presentMedia(tabID)
				case .tab: actions.presentTab(tabID)
				}
			}
			.disabled(!item.isEnabled)
			.help(item.help ?? "")
		}
	}

	/// Opens Automatically: Site Setting, Always or Never; then Shows: Automatic, Video or Page.
	@ViewBuilder
	private func automaticItems(
		_ choice: AutomaticPiPPreferences.TabChoice,
		_ actions: BrowserPictureInPictureActions
	) -> some View {
		Picker(
			String.localized(.appUI.media.tabPicture.automatic),
			selection: Binding(
				get: { choice.isAutomatic },
				set: { isAutomatic in
					var choice = choice
					choice.isAutomatic = isAutomatic
					actions.setAutomaticChoice(tabID, choice)
				}
			)
		) {
			Text(String.localized(.appUI.media.tabPicture.siteSetting)).tag(Bool?.none)
			Text(String.localized(.appUI.media.tabPicture.always)).tag(Bool?.some(true))
			Text(String.localized(.appUI.media.tabPicture.never)).tag(Bool?.some(false))
		}
		.pickerStyle(.inline)
		Picker(
			String.localized(.appUI.media.tabPicture.shows),
			selection: Binding(
				get: { choice.kind },
				set: { kind in
					var choice = choice
					choice.kind = kind
					actions.setAutomaticChoice(tabID, choice)
				}
			)
		) {
			Text(String.localized(.appUI.media.tabPicture.automaticKind)).tag(AutomaticPiPPreferences.Kind?.none)
			Text(String.localized(.appUI.media.tabPicture.video)).tag(AutomaticPiPPreferences.Kind?.some(.video))
			Text(String.localized(.appUI.media.tabPicture.page)).tag(AutomaticPiPPreferences.Kind?.some(.page))
		}
		.pickerStyle(.inline)
	}

	/// The items for a tab whose media is `media` (`nil` while it plays nothing).
	public static func items(
		media: BrowserMediaPictureInPicture?,
		canPresentTab: Bool
	) -> [Item] {
		var items: [Item] = []
		if let media {
			items.append(.init(
				kind: .media,
				title: BrowserCommand.mediaPictureInPicture.title,
				isEnabled: media.isAvailable,
				help: media.reason
			))
		}
		if canPresentTab {
			items.append(.init(
				kind: .tab,
				title: BrowserCommand.pagePictureInPicture.title,
				isEnabled: true,
				help: nil
			))
		}
		return items
	}
}

/// A media cell's menu (DEV-1106), in the Library's media list and the sidebar's player:
/// Present in Picture in Picture (or Exit Picture in Picture while it's there), then the cell's
/// own actions, Play or Pause, Mute or Unmute, and Return to Tab.
public struct SidebarMediaMenu: View {
	private let item: SidebarMediaItem
	private let pictureInPicture: BrowserMediaPictureInPicture?
	private let onPresent: () -> Void
	private let onExitPictureInPicture: (() -> Void)?

	/// Pauses with `true`, plays with `false`.
	private let onPlayPause: (Bool) -> Void
	private let onMute: (() -> Void)?
	private let onReturn: () -> Void

	/// - Parameters:
	///   - pictureInPicture: Whether the media can float; `nil` leaves the item out.
	///   - onExitPictureInPicture: Shows Exit Picture in Picture instead, while it floats.
	///   - onMute: `nil` leaves Mute out, as for a cell that can't mute.
	public init(
		item: SidebarMediaItem,
		pictureInPicture: BrowserMediaPictureInPicture?,
		onPresent: @escaping () -> Void,
		onExitPictureInPicture: (() -> Void)? = nil,
		onPlayPause: @escaping (Bool) -> Void,
		onMute: (() -> Void)?,
		onReturn: @escaping () -> Void
	) {
		self.item = item
		self.pictureInPicture = pictureInPicture
		self.onPresent = onPresent
		self.onExitPictureInPicture = onExitPictureInPicture
		self.onPlayPause = onPlayPause
		self.onMute = onMute
		self.onReturn = onReturn
	}

	public var body: some View {
		if let onExitPictureInPicture {
			Button(String.localized(.appUI.media.exitPicture), action: onExitPictureInPicture)
			Divider()
		} else if let pictureInPicture {
			Button(String.localized(.appUI.media.presentInPicture), action: onPresent)
				.disabled(!pictureInPicture.isAvailable)
				.help(pictureInPicture.reason ?? "")
			Divider()
		}
		if item.canPlay || item.canPause {
			let pauses = pauses
			Button(
				pauses ? String.localized(.appUI.media.pause) : String.localized(.appUI.media.play)
			) { onPlayPause(pauses) }
		}
		if let onMute {
			Button(
				item.isMuted ? String.localized(.appUI.media.unmute) : String.localized(.appUI.media.mute),
				action: onMute
			)
		}
		Button(String.localized(.appUI.media.returnToTab), action: onReturn)
			.disabled(!item.canReturn)
	}

	/// Pause while it plays, in the page or in Picture in Picture, as the media rows' button.
	private var pauses: Bool {
		item.playback == .paused ? !item.canPlay && item.canPause : item.canPause
	}
}
