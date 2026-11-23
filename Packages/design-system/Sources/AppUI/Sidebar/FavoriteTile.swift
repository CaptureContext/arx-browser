import AppKit
import SwiftUI

public struct FavoriteTile: View {
	private let item: SidebarItem
	private let selected: Bool
	private let isHidden: Bool
	private let focus: FocusState<SidebarItem.ID?>.Binding?
	private let onAction: (SidebarAction) -> Void

	@FocusState
	private var localFocusedID: SidebarItem.ID?

	@SwiftUI.State
	private var hovered: Bool

	@SwiftUI.State
	private var renaming: Bool

	/// Whether the keyboard moved focus here. A click focuses the tile too, without a ring.
	@SwiftUI.State
	private var isKeyboardFocused: Bool

	@SwiftUI.State
	private var draft: String

	@Environment(\.sidebarTabHoverChanged)
	private var tabHoverChanged

	@Environment(\.sidebarHoverPreviews)
	private var hoverPreviews

	@Environment(\.siteColors)
	private var siteColors

	@Environment(\.colorScheme)
	private var colorScheme

	@Environment(\.arxControlStateOverride)
	private var stateOverride

	public init(
		item: SidebarItem,
		selected: Bool = false,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.init(item: item, selected: selected, isHidden: false, focus: nil, onAction: onAction)
	}

	/// `isHidden` draws nothing while the tile's view stays for its drag.
	internal init(
		item: SidebarItem,
		selected: Bool,
		isHidden: Bool,
		focus: FocusState<SidebarItem.ID?>.Binding?,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.item = item
		self.selected = selected
		self.isHidden = isHidden
		self.focus = focus
		self.onAction = onAction
		self._hovered = .init(initialValue: false)
		self._renaming = .init(initialValue: false)
		self._isKeyboardFocused = .init(initialValue: false)
		self._draft = .init(initialValue: "")
	}

	public var body: some View {
		// A tap rather than a Button, whose mouse tracking would keep the tile from being dragged.
		FavoriteSiteIcon(
			key: item.siteIcon,
			fallback: item.symbol,
			tint: item.tint,
			size: 16,
			showsPlaceholder: true
		)
			.sidebarTabIcon(item, size: 16, onAction: onAction)

			// Marked as a tab row's icon is (DEV-877, DEV-1242).
			.webKitPageBadge(item.usesWebKit)
			.frame(maxWidth: .infinity)
			.frame(height: FavoritesGridLayout.tileHeight)
			.modifier(SidebarControlSurface(fill: background, shape: ArxControlShape()))
			.overlay {
				ArxControlShape()
					.strokeBorder(outline, lineWidth: outlineWidth)
			}

			// What the site has unread, at the tile's corner (DEV-907).
			.overlay(alignment: .topTrailing) {
				if let unread = item.unread {
					SidebarUnreadBadge(unread.badge)
						.padding(4)
				}
			}

			// The site a Peek opened from this tab shows, over the corner (DEV-1224).
			.overlay(alignment: .topTrailing) {
				SidebarPeekBadge(for: item.id, placement: .tile)
					.offset(x: 6, y: -6)
			}
			.opacity(isHidden ? 0 : 1)
			.animation(.easeOut(duration: 0.12), value: isHovered)
		.contentShape(ArxControlShape())
		.onTapGesture(perform: activate)
		.focusable(item.interactions.contains(.select))
		.focusEffectDisabled()
		.focused(focus ?? $localFocusedID, equals: item.id)
		.onKeyPress(.return, action: returnPressed)
		.onKeyPress(.space, phases: .down, action: spacePressed)
		.onKeyPress(characters: .letters, phases: .down, action: letterPressed)
		.onChange(of: isFocused) { _, focused in
			isKeyboardFocused = focused && NSApp.currentEvent?.type == .keyDown
		}
		.contentShape(
			.dragPreview,
			ArxControlShape()
		)
		.modifier(FavoriteDragSource(item: item))
		.dragConfiguration(.init(
			operationsWithinApp: .init(
				allowCopy: false,
				allowMove: item.interactions.contains(.move)
			),
			operationsOutsideApp: .init(allowCopy: false)
		))
		.onHover { isHovered in
			hovered = isHovered
			item.reportHover(isHovered, to: tabHoverChanged)
			pressTargetChanged()
		}
		.onChange(of: selected) { pressTargetChanged() }
		.onChange(of: renaming) { pressTargetChanged() }
		.onDisappear { SidebarPressActivation.leave(item.id) }
		.contextMenu {
			// Built when the menu opens, not each time the tile renders (DEV-1235).
			SidebarDeferred {
				if case let .tab(id) = item.id {
					tabMenu(id)
				}
			}
		}
		.alert(String.localized(.appUI.sidebar.renameFavorite), isPresented: $renaming) {
			TextField(String.localized(.appUI.common.name), text: $draft)
			Button(String.localized(.appUI.common.cancel), role: .cancel) {}
			Button(String.localized(.appUI.common.save), action: commitRename)
				.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
		}

		// The hover preview replaces the tooltip when the window supplies one.
		.help(hoverPreviews == nil ? item.title : "")
		.sidebarHoverPreview(item: item, selected: selected, isSuspended: renaming, onAction: onAction)
		.accessibilityLabel(item.title)
		.accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
		.accessibilityAction(.default, activate)
		.accessibilityAction(named: String.localized(.appUI.common.renameAction), beginRename)
		.accessibilityAction(named: String.localized(.appUI.sidebar.updateSavedURL)) {
			guard item.interactions.contains(.updateSavedURL) else { return }
			onAction(.updateSavedURL(item.id))
		}
		.accessibilityActions {
			SidebarDeferred {
				moveActions
				lifecycleActions
			}
		}
	}

	private var isFocused: Bool { (focus?.wrappedValue ?? localFocusedID) == item.id }

	private var isHovered: Bool { stateOverride.isHovered ?? hovered }

	/// The open favorite takes the selected row's fill, as a selected tab does; the others the
	/// chrome's quiet control tint, a little stronger on hover.
	private var background: AnyShapeStyle {
		if selected { return AnyShapeStyle(BrowserTheme.selectedRow) }
		return AnyShapeStyle(SidebarControlFill.tint(hovered: isHovered))
	}

	/// Keyboard focus is the accent; the open favorite has a thin ring in its site's color.
	private var outline: AnyShapeStyle {
		if showsFocusRing { return AnyShapeStyle(BrowserTheme.accent) }
		if item.moveSelection.contains(item.id) { return AnyShapeStyle(item.tint.color.opacity(0.6)) }
		if selected { return siteColors.highlight(for: item.siteIcon).style(scheme: colorScheme) }
		return AnyShapeStyle(Color.clear)
	}

	private var showsFocusRing: Bool { stateOverride.isFocused ?? (isFocused && isKeyboardFocused) }

	private var outlineWidth: CGFloat {
		if showsFocusRing { return ArxControlPalette.focusRingWidth }
		return selected && !item.moveSelection.contains(item.id)
		? BrowserMetrics.ControlSurface.selectedRingWidth
		: 1.5
	}

	/// A Favorite's menu, in `SidebarTabMenu`'s order (DEV-1250).
	@ViewBuilder
	private func tabMenu(_ id: UUID) -> some View {
		let groups = SidebarTabMenu.groups(for: .favorite, traits: .init(item))
		ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
			if index > 0 { Divider() }
			ForEach(group, id: \.self) { menuItem in
				tabMenuItem(menuItem, id)
			}
		}
	}

	@ViewBuilder
	private func tabMenuItem(
		_ menuItem: SidebarTabMenu.Item,
		_ id: UUID
	) -> some View {
		switch menuItem {
		case .copy:
			BrowserLinkMenu(
				tabIDs: item.linkTabIDs,
				offersSavedLink: item.isPinned,
				savedTabID: id
			)

		case .peek:
			BrowserPeekMenu(tabID: id)

		case .changeIcon:
			// The tab's own icon, in place of its site's (DEV-1251).
			Button(String.localized(.appUI.sidebar.changeIcon)) { onAction(.changeIcon(item.id)) }

		case .rename:
			Button(String.localized(.appUI.common.rename), action: beginRename)
				.disabled(!item.interactions.contains(.rename))

		case .updateSavedURL:
			Button(String.localized(.appUI.sidebar.updateSavedURL)) { onAction(.updateSavedURL(item.id)) }
				.disabled(!item.interactions.contains(.updateSavedURL))

		case .pictureInPicture:
			BrowserPictureInPictureMenu(tabID: id, nests: true)

		case .badges:
			// The tab's level of the unread badge choice (DEV-1258); a chat tab has none.
			if let unreadBadges = item.unreadBadges {
				UnreadBadgeVisibilityPicker(
					String.localized(.appUI.unreadBadges.tabMenu),
					selection: Binding(
						get: { unreadBadges.tab },
						set: { onAction(.setTabUnreadBadges(item.id, $0)) }
					),
					inherited: unreadBadges.inherited
				)
			}

		case .keepSiteLoaded:
			if let keepLoaded = item.keepLoaded {
				Toggle(
					String.localized(.appUI.sidebar.keepSiteLoaded),
					isOn: Binding(
						get: { keepLoaded.isKept },
						set: { onAction(.setSiteKeptLoaded(item.id, $0)) }
					)
				)
			}

		case .moveTo:
			Button(String.localized(.appUI.move.choose)) { onAction(.chooseMoveDestination(item.id)) }
				.disabled(!item.interactions.contains(.move))

		case .close:
			Button(String.localized(.appUI.sidebar.closeResetFavorite)) { onAction(.reset(item.id)) }
				.disabled(!item.interactions.contains(.trailingAction))

		case .unpin:
			Button(String.localized(.appUI.move.unpin)) { onAction(.move(item.id, .unpinnedRoot)) }
				.disabled(!item.interactions.contains(.move))

		case .removeFavorite:
			Button(String.localized(.appUI.sidebar.removeFavorite), role: .destructive) {
				onAction(.removePin(item.id))
			}
			.disabled(!item.interactions.contains(.trailingAction))

		// A tile's menu leaves out what a Favorite doesn't have.
		case .mute, .volume, .keepAgentTab, .addSplit, .duplicate, .addToNewGroup, .moveToWindow,
			.closeOthers, .closeBelow, .pin, .archive:
			EmptyView()
		}
	}

	private var lifecycleActions: some View {
		Group {
			Button(String.localized(.appUI.sidebar.closeResetFavorite)) { onAction(.reset(item.id)) }
			Button(String.localized(.appUI.sidebar.removeFavorite), role: .destructive) {
				onAction(.removePin(item.id))
			}
		}
		.disabled(!item.interactions.contains(.trailingAction))
	}

	private var moveActions: some View {
		Group {
			Button(String.localized(.appUI.move.choose)) { onAction(.chooseMoveDestination(item.id)) }
			Button(String.localized(.appUI.move.unpin)) { onAction(.move(item.id, .unpinnedRoot)) }
		}
		.disabled(!item.interactions.contains(.move))
	}

	/// A plain press on a Favorite that isn't the current tab switches as the button goes down
	/// (DEV-914, DEV-994), unless `ARX_SIDEBAR_PRESS_SELECTS` is off.
	private func pressTargetChanged() {
		if hovered, !selected, !renaming, item.interactions.contains(.select) {
			SidebarPressActivation.hover(item.id, activate: selectOnPress)
		} else {
			SidebarPressActivation.leave(item.id)
		}
	}

	/// The press selects the Favorite; the window remembers the tab shown before it (DEV-994).
	private func selectOnPress() {
		guard item.interactions.contains(.select) else { return }
		onAction(.selectOnPress(item.id))
	}

	private func activate() {
		if SidebarPressActivation.consume(item.id) {
			onAction(.pressCompleted(item.id))
			return
		}
		guard item.interactions.contains(.select) else { return }

		let isCommandPressed = NSEvent.actionModifierFlags.contains(.command)
		onAction(isCommandPressed ? .toggleMoveSelection(item.id) : .select(item.id))
	}

	private func returnPressed() -> KeyPress.Result {
		guard item.interactions.contains(.rename) else { return .ignored }
		beginRename()
		return .handled
	}

	private func spacePressed(_ press: KeyPress) -> KeyPress.Result {
		guard press.modifiers.contains(.shift) else {
			guard item.interactions.contains(.select) else { return .ignored }
			activate()
			return .handled
		}
		guard item.interactions.contains(.move) else { return .ignored }
		onAction(.toggleMoveSelection(item.id))
		return .handled
	}

	private func letterPressed(_ press: KeyPress) -> KeyPress.Result {
		guard
			press.characters.lowercased() == "m",
			press.modifiers.contains([.command, .shift]),
			item.interactions.contains(.move)
		else { return .ignored }
		onAction(.chooseMoveDestination(item.id))
		return .handled
	}

	private func beginRename() {
		guard item.interactions.contains(.rename) else { return }
		draft = item.title
		renaming = true
	}

	private func commitRename() {
		let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !name.isEmpty else { return }
		onAction(.rename(item.id, name))
		renaming = false
	}
}

private struct FavoriteDragSource: ViewModifier {
	internal let item: SidebarItem

	@ViewBuilder
	internal func body(content: Content) -> some View {
		if item.interactions.contains(.move) {
			content.modifier(SidebarDragSource(item: item, fromFavorites: true))
		} else {
			content
		}
	}
}
