import BrowserCore
import SwiftUI

/// Little Arx's header (DEV-523, DEV-652), which Page PiP's window shares (DEV-1105): the window's
/// buttons or Return to Tab, the history buttons, the centred URL bar with the profile picker in
/// it, and an accessory such as "Open in". The URL bar has the prominent actions, the reading mode
/// button (DEV-1028) and, with a translation offer, a second line (DEV-996). It sits above the
/// page, never over it, and its background is where the window is dragged from.
public struct LittleWindowHeader<
	ProfilePicker: View,
	Accessory: View,
	DragArea: View
>: View {
	/// What sits where a window's close, minimize and zoom buttons are.
	public enum Leading {
		/// Little Arx: the window's own buttons.
		case windowControls

		/// Page PiP: Return to Tab, which moves the page back to its source.
		case returnToTab(() -> Void)
	}

	/// The history buttons after the leading control.
	public enum History {
		/// Little Arx: Back only, and only once there is somewhere to go back to.
		case back((() -> Void)?)

		/// Page PiP: Back and Forward, each disabled while there's nowhere to go, as a browser
		/// window's.
		case backAndForward(back: (() -> Void)?, forward: (() -> Void)?)
	}

	private let leading: Leading
	private let url: URL?
	private let isLoading: Bool
	private let history: History
	private let onActivate: (() -> Void)?
	private let onCopy: () -> Void
	private let readingMode: ReadingModeIndicator?
	private let translation: PageTranslationOfferSource?
	private let profilePicker: ProfilePicker
	private let accessory: Accessory
	private let dragArea: DragArea

	/// - Parameters:
	///   - onActivate: Opens the address for editing; `nil` shows it without editing.
	///   - readingMode: The page's reading mode, when it has an article to show; `nil` keeps
	///     whatever the environment has.
	///   - translation: Translation Available and its popover; `nil` keeps whatever the
	///     environment has.
	///   - dragArea: Fills the header behind its controls, and moves the window.
	public init(
		leading: Leading,
		url: URL?,
		isLoading: Bool,
		history: History,
		onActivate: (() -> Void)?,
		onCopy: @escaping () -> Void,
		readingMode: ReadingModeIndicator? = nil,
		translation: PageTranslationOfferSource? = nil,
		@ViewBuilder profilePicker: () -> ProfilePicker,
		@ViewBuilder accessory: () -> Accessory,
		@ViewBuilder dragArea: () -> DragArea
	) {
		self.leading = leading
		self.url = url
		self.isLoading = isLoading
		self.history = history
		self.onActivate = onActivate
		self.onCopy = onCopy
		self.readingMode = readingMode
		self.translation = translation
		self.profilePicker = profilePicker()
		self.accessory = accessory()
		self.dragArea = dragArea()
	}

	public var body: some View {
		HStack(spacing: 6) {
			leadingControl
			historyButtons
			URLBar(
				url: url,
				height: BrowserMetrics.LittleArx.addressHeight,
				centersAddress: true,
				prominentActions: true,
				isLoading: isLoading,
				leading: AnyView(profilePicker),
				onActivate: onActivate,
				onCopy: onCopy
			)
			.transformEnvironment(\.readingModeIndicator) { if let readingMode { $0 = readingMode } }
			.transformEnvironment(\.pageTranslationOffer) { if let translation { $0 = translation } }
			.frame(minWidth: BrowserMetrics.LittleArx.addressMinimumWidth, maxWidth: .infinity)
			.layoutPriority(1)
			accessory
		}
		.font(.system(size: 12, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, 8)
		.frame(height: BrowserMetrics.LittleArx.toolbarHeight)
		.background { dragArea }
	}

	/// The window's buttons in a slot of their width, or Return to Tab in its own button's width,
	/// where the window's close button starts, with Back after it as Forward is after Back.
	@ViewBuilder
	private var leadingControl: some View {
		switch leading {
		case .windowControls:
			BrowserWindowControls()
				.frame(
					width: BrowserMetrics.Toolbar.windowControlsWidth,
					height: BrowserMetrics.LittleArx.toolbarHeight
				)

		case let .returnToTab(action):
			// Media PiP's own return symbol, as a square icon button (DEV-1105).
			Button(action: action) {
				Image(systemName: "pip.exit").font(.system(size: 13, weight: .semibold))
			}
			.buttonStyle(BrowserToolbarButtonStyle())
			.help(String.localized(.appUI.pagePicture.backToTab))
			.accessibilityLabel(String.localized(.appUI.pagePicture.backToTab))
			.accessibilityIdentifier("page-picture-return-to-tab")
		}
	}

	@ViewBuilder
	private var historyButtons: some View {
		switch history {
		case let .back(onBack):
			if let onBack { historyButton(.back, action: onBack) }

		case let .backAndForward(onBack, onForward):
			historyButton(.back, action: onBack)
			historyButton(.forward, action: onForward)
		}
	}

	private enum Direction {
		case back
		case forward
	}

	private func historyButton(
		_ direction: Direction,
		action: (() -> Void)?
	) -> some View {
		let title = direction == .back
		? String.localized(.appUI.navigation.back)
		: String.localized(.appUI.navigation.forward)
		return Button { action?() } label: {
			Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
				.font(.system(size: 13, weight: .semibold))
		}
		.buttonStyle(BrowserToolbarButtonStyle())
		.disabled(action == nil)
		.help(title)
		.accessibilityLabel(title)
	}
}

extension LittleWindowHeader where DragArea == LittleWindowDragArea {
	/// A header whose background drags the window as AppKit does, as Little Arx's.
	public init(
		leading: Leading,
		url: URL?,
		isLoading: Bool,
		history: History,
		onActivate: (() -> Void)?,
		onCopy: @escaping () -> Void,
		readingMode: ReadingModeIndicator? = nil,
		translation: PageTranslationOfferSource? = nil,
		@ViewBuilder profilePicker: () -> ProfilePicker,
		@ViewBuilder accessory: () -> Accessory
	) {
		self.init(
			leading: leading,
			url: url,
			isLoading: isLoading,
			history: history,
			onActivate: onActivate,
			onCopy: onCopy,
			readingMode: readingMode,
			translation: translation,
			profilePicker: profilePicker,
			accessory: accessory,
			dragArea: { LittleWindowDragArea() }
		)
	}
}

/// The header's background in Little Arx: a drag there moves the window.
public struct LittleWindowDragArea: View {
	public init() {}

	public var body: some View {
		Color.clear.contentShape(.rect).gesture(WindowDragGesture())
	}
}

/// Little Arx's profile picker (DEV-523), which Page PiP's header shares (DEV-1105): the page's
/// profile as a badge in the URL bar, opening a menu of profiles; choosing another reopens the
/// page in it. A profile the page can't move to is disabled.
public struct LittleWindowProfilePicker: View {
	public struct Option: Identifiable, Equatable, Sendable {
		public var id: Profile.ID
		public var name: String
		public var isEnabled: Bool

		public init(
			id: Profile.ID,
			name: String,
			isEnabled: Bool
		) {
			self.id = id
			self.name = name
			self.isEnabled = isEnabled
		}
	}

	private let options: [Option]
	private let currentID: Profile.ID?
	private let onSelect: (Profile.ID) -> Void

	public init(
		options: [Option],
		currentID: Profile.ID?,
		onSelect: @escaping (Profile.ID) -> Void
	) {
		self.options = options
		self.currentID = currentID
		self.onSelect = onSelect
	}

	public var body: some View {
		Menu {
			ForEach(options) { option in
				Button {
					onSelect(option.id)
				} label: {
					if option.id == currentID {
						Label(option.name, systemImage: "checkmark")
					} else {
						Text(option.name)
					}
				}
				.disabled(!option.isEnabled)
			}
		} label: {
			// The name while there's room for it, as Little Arx's, cut shorter as the room
			// narrows; the face alone in a narrow window, such as Page PiP's narrowest (DEV-1153).
			ViewThatFits(in: .horizontal) {
				badge(showsName: true)
					.frame(maxWidth: Self.maximumWidth)
					.fixedSize(horizontal: true, vertical: false)
				badge(showsName: true)
					.frame(maxWidth: Self.compactWidth)
					.fixedSize(horizontal: true, vertical: false)
				badge(showsName: false)
					.fixedSize(horizontal: true, vertical: false)
			}
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize(horizontal: false, vertical: true)

		// The badge takes its room before the address, which cuts itself short first.
		.layoutPriority(1)
		.help(String.localized(.appUI.littleArx.profile))
		.accessibilityLabel(currentName)
	}

	/// The widest the badge gets; a longer name is cut short.
	internal static let maximumWidth: CGFloat = 140

	/// Where there isn't room for that, a long name is cut short at about a short one's width.
	internal static let compactWidth: CGFloat = 96

	private var currentName: String {
		options.first { $0.id == currentID }?.name ?? ""
	}

	private func badge(showsName: Bool) -> some View {
		ProfileBadge(
			name: currentName,
			showsName: showsName,
			height: BrowserMetrics.URLBar.accessoryHeight(forHeight: BrowserMetrics.LittleArx.addressHeight),
			cornerRadius: BrowserMetrics.URLBar.accessoryCornerRadius(forHeight: BrowserMetrics.LittleArx.addressHeight)
		)
	}
}

/// Page PiP's header (DEV-1105): Little Arx's, with Return to Tab for the window's buttons, Back
/// and Forward, Little Arx's profile picker, and no "Open in", since the page already has a place.
/// With `onActivate`, clicking the address edits it, as the main window's does (DEV-1124);
/// without, it only shows.
public struct PagePictureInPictureHeader<ProfilePicker: View, DragArea: View>: View {
	private let url: URL?
	private let isLoading: Bool
	private let onReturnToTab: () -> Void
	private let onBack: (() -> Void)?
	private let onForward: (() -> Void)?
	private let onActivate: (() -> Void)?
	private let onCopy: () -> Void
	private let readingMode: ReadingModeIndicator?
	private let translation: PageTranslationOfferSource?
	private let profilePicker: ProfilePicker
	private let dragArea: DragArea

	/// - Parameters:
	///   - onBack: `nil` while there's nowhere to go back to, which disables Back.
	///   - onForward: `nil` while there's nowhere to go forward to, which disables Forward.
	///   - onActivate: Edits the address, on a click on it; `nil` leaves it showing only.
	///   - readingMode: The page's reading mode, where the window can show the article.
	///   - translation: Translation Available and its popover.
	public init(
		url: URL?,
		isLoading: Bool,
		onReturnToTab: @escaping () -> Void,
		onBack: (() -> Void)?,
		onForward: (() -> Void)?,
		onActivate: (() -> Void)? = nil,
		onCopy: @escaping () -> Void,
		readingMode: ReadingModeIndicator? = nil,
		translation: PageTranslationOfferSource? = nil,
		@ViewBuilder profilePicker: () -> ProfilePicker,
		@ViewBuilder dragArea: () -> DragArea
	) {
		self.url = url
		self.isLoading = isLoading
		self.onReturnToTab = onReturnToTab
		self.onBack = onBack
		self.onForward = onForward
		self.onActivate = onActivate
		self.onCopy = onCopy
		self.readingMode = readingMode
		self.translation = translation
		self.profilePicker = profilePicker()
		self.dragArea = dragArea()
	}

	public var body: some View {
		LittleWindowHeader(
			leading: .returnToTab(onReturnToTab),
			url: url,
			isLoading: isLoading,
			history: .backAndForward(back: onBack, forward: onForward),
			onActivate: onActivate,
			onCopy: onCopy,
			readingMode: readingMode,
			translation: translation,
			profilePicker: { profilePicker },
			accessory: { EmptyView() },
			dragArea: { dragArea }
		)
	}
}
