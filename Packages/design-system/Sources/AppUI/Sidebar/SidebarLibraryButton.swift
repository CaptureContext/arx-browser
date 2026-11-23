import BrowserCore
import SwiftUI

/// The Library button at the footer's leading edge: the icon lifts a little on hover and
/// dips on press, and resting on it shows the command's name and shortcut in the footer's hint pill.
/// With recent downloads, hovering fans them out above the footer instead (DEV-758).
public struct SidebarLibraryButton: View {
	/// How long the pointer rests on the button before recent downloads fan out: shorter than the hint's wait.
	public static let fanOutDelay: Duration = .milliseconds(350)

	/// How long the rows take to tuck away before their panel closes.
	internal static let collapseDuration: Duration = .milliseconds(160)

	private let isOpen: Bool
	private let title: String
	private let shortcut: [String]
	private let recentDownloads: SidebarRecentDownloads?
	private let action: () -> Void

	@Environment(\.sidebarFooterHintTimer)
	private var footerHintTimer

	@Environment(\.sidebarInteraction)
	private var interaction

	@SwiftUI.State
	private var ownHintTimer: SidebarSpaceHintTimer

	@SwiftUI.State
	private var isHovered: Bool

	/// Whether the recent downloads' panel is up, fanned out or tucking away.
	@SwiftUI.State
	private var downloadsPresented: Bool

	@SwiftUI.State
	private var downloadsFanned: Bool

	@SwiftUI.State
	private var downloadsHovered: Bool

	/// Whether the app was asked to keep the downloads current.
	@SwiftUI.State
	private var isWatching: Bool

	@SwiftUI.State
	private var pending: Task<Void, Never>?

	/// - Parameters:
	///   - title: The command's name, shown in the hint.
	///   - shortcut: The keys bound to the command, such as ["⇧", "⌘", "L"], read from the shortcut registry.
	///   - recentDownloads: The window's downloads, fanned out on hover. `nil` shows only the hint.
	public init(
		isOpen: Bool,
		title: String,
		shortcut: [String],
		recentDownloads: SidebarRecentDownloads? = nil,
		action: @escaping () -> Void
	) {
		self.isOpen = isOpen
		self.title = title
		self.shortcut = shortcut
		self.recentDownloads = recentDownloads
		self.action = action
		self._ownHintTimer = .init(initialValue: .init())
		self._isHovered = .init(initialValue: false)
		self._downloadsPresented = .init(initialValue: false)
		self._downloadsFanned = .init(initialValue: false)
		self._downloadsHovered = .init(initialValue: false)
		self._isWatching = .init(initialValue: false)
		self._pending = .init(initialValue: nil)
	}

	private var hintTimer: SidebarSpaceHintTimer {
		footerHintTimer ?? ownHintTimer
	}

	private var hintEntry: SidebarSpacePickerEntry {
		.init(
			id: SidebarSpaceHintTimer.libraryHintID,
			name: title,
			symbol: BrowserCommand.toggleLibrary.symbol,
			shortcut: shortcut
		)
	}

	public var body: some View {
		Button {
			hintTimer.hide()
			closeDownloads()
			action()
		} label: {
			Image(systemName: isOpen ? "archivebox.fill" : "archivebox")
				.foregroundStyle(isOpen || isHovered ? BrowserTheme.text : BrowserTheme.secondary)
		}
		.buttonStyle(SidebarLibraryButtonStyle(isHovered: isHovered))
		.onContinuousHover { phase in
			switch phase {
			case .active:
				if !isHovered {
					isHovered = true
					pointerEntered()
				}

				// Every movement counts: before the first hint, it starts the rest over. The fanned
				// out downloads take the hint's place.
				if !downloadsPresented {
					hintTimer.pointerMoved(over: SidebarSpaceHintTimer.libraryHintID)
				}

			case .ended:
				isHovered = false
				hintTimer.pointerLeft(SidebarSpaceHintTimer.libraryHintID)
				scheduleCollapse()
			}
		}
		.anchorPreference(key: SidebarSpaceHintKey.self, value: .bounds) { item in
			hintTimer.hinted == SidebarSpaceHintTimer.libraryHintID ? .init(space: hintEntry, item: item) : nil
		}

		// One of the window's hover previews (DEV-1288), held while the pointer is on its rows;
		// another preview replacing them closes them as a click does.
		.sidebarHoverPanel(
			isPresented: $downloadsPresented,
			edge: .top,
			drawsCard: false,
			exclusivity: .init(isHeld: downloadsHovered, refused: { closeDownloads() })
		) {
			if let recentDownloads {
				SidebarRecentDownloadsPanel(
					recentDownloads: recentDownloads,
					isFanned: downloadsFanned,
					open: { id in
						closeDownloads()
						recentDownloads.open(id)
					}
				)
				.onHover(perform: downloadsHoverChanged)
			}
		}

		// A floating sidebar stays revealed while the rows are out.
		.preference(key: SidebarHoverPreviewOpen.self, value: downloadsPresented)
		.onDisappear(perform: closeDownloads)
		.accessibilityLabel(title)
		.accessibilityAddTraits(isOpen ? .isSelected : [])
	}

	private func pointerEntered() {
		guard let recentDownloads else { return }

		pending?.cancel()
		if downloadsPresented {
			// Back on the button while the rows tuck away: they fan out again.
			downloadsFanned = true
			return
		}
		setWatching(true)
		pending = Task { @MainActor in
			try? await Task.sleep(for: Self.fanOutDelay)
			guard !Task.isCancelled, isHovered else { return }

			// Nothing to show leaves the button its hint.
			guard !SidebarRecentDownloads.recent(recentDownloads.downloads()).isEmpty
			else { return }
			hintTimer.hide()
			downloadsPresented = true
			downloadsFanned = true
		}
	}

	private func downloadsHoverChanged(_ hovering: Bool) {
		downloadsHovered = hovering
		if hovering {
			pending?.cancel()
			if downloadsPresented { downloadsFanned = true }
		} else {
			scheduleCollapse()
		}
	}

	/// The rows wait briefly, so the pointer can cross the gap between the button and them.
	private func scheduleCollapse() {
		guard recentDownloads != nil else { return }

		pending?.cancel()
		pending = Task { @MainActor in
			if downloadsPresented {
				try? await Task.sleep(for: interaction.hoverPreviewDismissDelay)
				guard !Task.isCancelled, !isHovered, !downloadsHovered else { return }
				downloadsFanned = false
				try? await Task.sleep(for: Self.collapseDuration)
				guard !Task.isCancelled, !isHovered, !downloadsHovered else { return }
				downloadsPresented = false
			}
			guard !isHovered, !downloadsHovered else { return }
			setWatching(false)
		}
	}

	/// Closes the rows at once, as a click on the button or a row does.
	private func closeDownloads() {
		pending?.cancel()
		pending = nil
		downloadsFanned = false
		downloadsHovered = false
		if downloadsPresented { downloadsPresented = false }
		setWatching(false)
	}

	private func setWatching(_ watching: Bool) {
		guard let recentDownloads, isWatching != watching else { return }

		isWatching = watching
		recentDownloads.watchingChanged(watching)
	}
}

/// The fanned out rows as their panel holds them: they fan out once drawn, and redraw with the downloads.
private struct SidebarRecentDownloadsPanel: View {
	internal let recentDownloads: SidebarRecentDownloads
	internal let isFanned: Bool
	internal let open: (BrowserDownload.ID) -> Void

	/// Off for the first frame, so the rows fan out of the button rather than appearing in place.
	@SwiftUI.State
	private var hasAppeared: Bool = false

	internal var body: some View {
		TimelineView(.periodic(from: .now, by: 30)) { context in
			SidebarRecentDownloadsList(
				downloads: SidebarRecentDownloads.recent(recentDownloads.downloads()),
				now: context.date,
				isFanned: isFanned && hasAppeared,
				open: open
			)
		}
		.task { hasAppeared = true }
	}
}

/// The icon's spring: a small lift and tilt on hover, a dip on press. Reduce Motion keeps it still.
internal struct SidebarLibraryButtonStyle: ButtonStyle {
	internal var isHovered: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal func makeBody(configuration: Configuration) -> some View {
		let motion = SidebarLibraryIconMotion(
			isHovered: isHovered,
			isPressed: configuration.isPressed,
			reducesMotion: reduceMotion
		)
		configuration.label
			.rotationEffect(.degrees(motion.tilt), anchor: .bottomTrailing)
			.offset(y: motion.lift)
			.scaleEffect(motion.scale, anchor: .bottom)
			.contentShape(.rect)
			.animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: motion)
	}
}

/// Where the Library icon rests for a hover and press state.
internal struct SidebarLibraryIconMotion: Equatable {
	/// Points up, so negative.
	internal var lift: CGFloat
	internal var tilt: Double
	internal var scale: CGFloat

	internal init(
		isHovered: Bool,
		isPressed: Bool,
		reducesMotion: Bool
	) {
		guard !reducesMotion else {
			self.lift = 0
			self.tilt = 0
			self.scale = 1
			return
		}
		if isPressed {
			self.lift = 0
			self.tilt = 0
			self.scale = 0.88
		} else if isHovered {
			self.lift = -1.5
			self.tilt = -8
			self.scale = 1
		} else {
			self.lift = 0
			self.tilt = 0
			self.scale = 1
		}
	}
}
