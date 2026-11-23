import AppKit
import AppUI
import BrowserCore
import BrowserSurfaceClient
import SwiftUI
import _ComposableArchitecture

/// Gets the page a press or a swipe says is about to be shown drawing ahead of time, so
/// selecting it shows its last frame at once instead of an empty card.
///
/// A hover alone stages nothing (DEV-941). A staged page is in the window, so Chromium treats
/// it as shown: it unfreezes, runs its timers at full rate and moves to the front of the
/// recently used tabs that are protected from freezing. Staging a hovered page let a pointer
/// sweep down the sidebar wake every page it crossed. A sidebar row selects its tab when the
/// click ends, so a left mouse down on the hovered row stages its page instead, which gives
/// the page the length of the press to draw before the click shows it.
///
/// It works outside SwiftUI: a press or a swipe frame changes nothing the window renders.
/// While the sidebar settles on a space after a swipe, it shows that space's page, which the
/// window selects only once the sidebar lands, until the page card takes it.
@MainActor
internal final class MainPageStaging {
	internal let controller: BrowserSurfaceStageController
	private let store: StoreOf<MainFeature>

	/// The sidebar tab under the pointer. Nothing is staged for it until it's pressed.
	private var hoveredTabID: BrowserCore.Tab.ID?

	/// The hovered tab a left mouse down landed on, whose page is staged for the click.
	private var pressedTabID: BrowserCore.Tab.ID?

	/// Watches for that mouse down only while a tab is hovered.
	private var pressMonitor: Any?

	/// The space a swipe is uncovering, or settling on.
	private var revealedSpaceID: Space.ID?

	/// Whether the sidebar is settling on `revealedSpaceID`, which is selected as it lands.
	private var isLanding: Bool

	internal init(
		store: StoreOf<MainFeature>,
		surface: BrowserSurfaceClient
	) {
		self.store = store
		self.controller = .init(client: surface)
		self.hoveredTabID = nil
		self.pressedTabID = nil
		self.pressMonitor = nil
		self.revealedSpaceID = nil
		self.isLanding = false
	}

	isolated deinit {
		if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
	}

	internal func hover(_ id: UUID?) {
		let hovered = id.map(BrowserCore.Tab.ID.init(rawValue:))
		guard hovered != hoveredTabID else { return }

		hoveredTabID = hovered
		updatePressMonitor()
		guard pressedTabID != nil else { return }

		pressedTabID = nil
		update()
	}

	/// A left mouse down on the hovered tab's row: its click is about to show it.
	internal func pressHoveredTab() {
		guard let hoveredTabID, pressedTabID != hoveredTabID else { return }

		pressedTabID = hoveredTabID
		update()
	}

	private func updatePressMonitor() {
		if hoveredTabID == nil {
			if let pressMonitor { NSEvent.removeMonitor(pressMonitor) }
			pressMonitor = nil
			return
		}
		guard pressMonitor == nil else { return }

		pressMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in

			// Shift, Command and Control clicks select for moving or open a menu, not the tab.
			guard
				let self,
				let window = event.window,
				window === self.controller.window,
				event.modifierFlags.isDisjoint(with: [.shift, .command, .control])
			else { return event }

			self.pressHoveredTab()
			return event
		}
	}

	internal func reveal(
		_ id: UUID?,
		isLanding: Bool
	) {
		let spaceID = id.map(Space.ID.init(rawValue:))
		guard revealedSpaceID != spaceID || self.isLanding != isLanding else { return }
		revealedSpaceID = spaceID
		self.isLanding = isLanding
		update()
	}

	/// A space selected some other way than the landing ends it, so its page isn't shown later.
	internal func spaceSelected(_ id: Space.ID) {
		guard isLanding, let revealedSpaceID, revealedSpaceID != id else { return }
		self.revealedSpaceID = nil
		isLanding = false
		update()
	}

	private func update() {
		let shown = store.viewer.item.tab?.id
		var revealed = revealedSpaceID.flatMap { store.sidebar.organization.spaces[id: $0]?.selectedTabID }

		// The page card has taken the landed page, so the landing is over.
		if isLanding, revealed == shown {
			revealedSpaceID = nil
			isLanding = false
			revealed = nil
		}
		let staged = Self.stagedTab(
			isSplit: store.viewer.isSplit,
			revealed: revealed,
			isLanding: isLanding,
			pressed: pressedTabID,
			shown: shown
		)
		controller.stage(staged.id, isPresented: staged.isPresented)
	}

	/// The page to keep drawing on the stage, and whether the stage shows it over the page card.
	///
	/// Only a landing space's page that the card hasn't taken yet is shown. A pressed tab never
	/// is: the page it stages leaves the stage a moment after the hover ends, so showing the
	/// stage then would show that page over the card (DEV-787).
	internal static func stagedTab(
		isSplit: Bool,
		revealed: BrowserCore.Tab.ID?,
		isLanding: Bool,
		pressed: BrowserCore.Tab.ID?,
		shown: BrowserCore.Tab.ID?
	) -> (id: BrowserCore.Tab.ID?, isPresented: Bool) {
		guard !isSplit else { return (nil, false) }
		if let revealed, revealed != shown {
			// Held until the page card has taken it.
			if isLanding { return (revealed, true) }
			return (revealed, false)
		}
		guard let pressed, pressed != shown else { return (nil, false) }
		return (pressed, false)
	}
}

/// The stage over the page card, with the card's corners and border while it shows a page.
internal struct MainPageStage: View {
	private let staging: MainPageStaging

	internal init(staging: MainPageStaging) {
		self.staging = staging
	}

	internal var body: some View {
		let shape = RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
		BrowserSurfaceStage(controller: staging.controller)
			.clipShape(shape)
			.accessibilityHidden(true)
			.allowsHitTesting(false)
	}
}
