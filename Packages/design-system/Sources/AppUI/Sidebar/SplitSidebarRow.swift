import AppKit
import BrowserCore
import SwiftUI

/// A Split View group: one row with a segment per member (favicon and title). Each segment
/// focuses its pane, shows its own close button on hover, and drags out on its own. The row looks
/// the same in the open tabs, Pinned or a folder (DEV-1006).
public struct SplitSidebarRow: View {
	private let item: SidebarItem
	private let split: SidebarItem.Split

	/// How deep in folders the row is, indented as a tab row there is (DEV-1006).
	private let depth: Int
	private let selected: Bool
	private let isDropTarget: Bool

	/// Whether the window offers link copying and sharing; the handlers come through `actions`.
	private let offersLinks: Bool
	private let actions: SidebarActionRelay

	@SwiftUI.State
	private var hovered: Bool

	@SwiftUI.State
	private var hoveredMember: SidebarItem.ID?

	@SwiftUI.State
	private var renaming: Bool

	@SwiftUI.State
	private var draft: String

	@SwiftUI.State
	private var pickingIcon: Bool

	@FocusState
	private var nameFocused: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// A group's row on its own, without the window's link handlers; `BrowserSidebar` passes them.
	internal init(
		item: SidebarItem,
		split: SidebarItem.Split,
		depth: Int = 0,
		selected: Bool,
		isDropTarget: Bool = false,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.init(
			item: item,
			split: split,
			depth: depth,
			selected: selected,
			isDropTarget: isDropTarget,
			offersLinks: false,
			actions: .init(onAction)
		)
	}

	internal init(
		item: SidebarItem,
		split: SidebarItem.Split,
		depth: Int,
		selected: Bool,
		isDropTarget: Bool,
		offersLinks: Bool,
		actions: SidebarActionRelay
	) {
		self.item = item
		self.split = split
		self.depth = depth
		self.selected = selected
		self.isDropTarget = isDropTarget
		self.offersLinks = offersLinks
		self.actions = actions
		self._hovered = .init(initialValue: false)
		self._hoveredMember = .init(initialValue: nil)
		self._renaming = .init(initialValue: false)
		self._draft = .init(initialValue: "")
		self._pickingIcon = .init(initialValue: false)
	}

	public var body: some View {
		let _ = SidebarRenderTrace.rowBody(item.id)
		HStack(spacing: selected ? 4 : 0) {
			if let icon = split.icon {
				SpaceIconImage(rawValue: icon)
					.font(.system(size: BrowserMetrics.Row.iconSize - 4, weight: .medium))
					.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
					.padding(.leading, 6)
					.accessibilityHidden(true)
			}
			if let title = split.title, !renaming {
				Text(title)
					.fontWeight(.medium)
					.lineLimit(1)
					.padding(.leading, split.icon == nil ? BrowserMetrics.Row.horizontalPadding : 0)
					.layoutPriority(1)
			}
			if renaming {
				TextField(String.localized(.appUI.common.name), text: $draft)
					.textFieldStyle(.plain)
					.focused($nameFocused)
					.onSubmit(commitRename)
					.onExitCommand { renaming = false }
					.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
			} else {
				ForEach(Array(split.members.enumerated()), id: \.element.id) { index, member in
					if index > 0, !selected {
						Rectangle()
							.fill(BrowserTheme.divider.opacity(BrowserMetrics.Section.dividerOpacity))
							.frame(width: 1, height: BrowserMetrics.Row.iconSize)
							.accessibilityHidden(true)
					}
					segment(member)
				}
			}
		}
		.font(.system(size: BrowserMetrics.Row.fontSize))
		.foregroundStyle(BrowserTheme.text)
		.padding(selected ? 3 : 0)
		.frame(height: BrowserMetrics.Row.height)
		.background {
			RoundedRectangle(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
				.fill(background)
				.browserShadow(selected && !isDropTarget ? BrowserMetrics.Row.selectedShadow : .none)
		}
		.contentShape(.rect)
		.onHover { hovered = $0 }
		.contextMenu { menu }
		.popover(isPresented: $pickingIcon, arrowEdge: .trailing) {
			SpaceIconPicker(
				selection: split.icon.flatMap(SpaceIcon.init(rawValue:)),
				onReset: {
					pickingIcon = false
					onAction(.splitGroup(.changeIcon(split.id, nil)))
				}
			) { icon in
				pickingIcon = false
				onAction(.splitGroup(.changeIcon(split.id, icon.rawValue)))
			}
		}
		.onChange(of: nameFocused) { _, focused in
			if renaming, !focused { commitRename() }
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.split.row(accessibilityTitle)))
		.accessibilityAddTraits(selected ? .isSelected : [])
		.help(accessibilityTitle)
		.padding(.leading, CGFloat(depth) * 17)
	}

	private var accessibilityTitle: String {
		split.title ?? split.members.map(\.title).formatted(.list(type: .and))
	}

	private var background: AnyShapeStyle {
		if isDropTarget { return AnyShapeStyle(BrowserTheme.accent.opacity(0.35)) }
		if selected { return AnyShapeStyle(BrowserTheme.selectedRow) }
		return AnyShapeStyle(hovered ? BrowserTheme.rowHover : .clear)
	}

	private func segment(_ member: SidebarItem) -> some View {
		let isHovered = hoveredMember == member.id
		let showsClose = isHovered || (hovered && split.members.count <= 2)
		return HStack(spacing: 6) {
			FavoriteSiteIcon(
				key: member.siteIcon,
				fallback: member.symbol,
				tint: member.tint,
				size: BrowserMetrics.Row.iconSize,
				fallbackSize: BrowserMetrics.Row.iconSize - 2,
				fallbackWeight: .medium,
				showsPlaceholder: true
			)

			// A member keeps the icon chosen for its tab (DEV-1251).
			.sidebarTabIcon(member, size: BrowserMetrics.Row.iconSize, onAction: onAction)
			.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
			if split.title == nil, !isHovered || split.members.count <= 2 {
				Text(member.title)
					.lineLimit(1)
					.truncationMode(.tail)
			}
			Spacer(minLength: 0)
			if showsClose {
				let action = member.tabAction(isSelected: false)
				Button { perform(action, on: member) } label: {
					SidebarTabActionIcon(isMinus: action == .removePin)
						.frame(width: 18, height: 18)
				}
				.sidebarRowControlButtonStyle()
				.help(title(of: action, for: member))
				.accessibilityLabel(title(of: action, for: member))
			}

			// The site a Peek opened from this member shows (DEV-1224).
			SidebarPeekBadge(for: member.id, placement: .segment)
		}
		.padding(.horizontal, 7)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background {
			if selected {
				RoundedRectangle(cornerRadius: BrowserMetrics.Row.cornerRadius - 3, style: .continuous)
					.fill(isHovered ? BrowserTheme.hover : BrowserTheme.text.opacity(0.06))
			}
		}
		.contentShape(.rect)
		.onHover { inside in
			if inside {
				hoveredMember = member.id
			} else if hoveredMember == member.id {
				hoveredMember = nil
			}
		}

		// The double-click runs alongside the click rather than ahead of it: as rivals, every click
		// waited out the system's double-click interval before showing the member (DEV-914).
		.onTapGesture { activate(member) }
		.simultaneousGesture(TapGesture(count: 2).onEnded { beginRename() })

		// Keyboard use as on a tab row: Space shows the pane, ⇧Space selects for moving, Return renames.
		.focusable(!renaming)
		.onKeyPress(.space, phases: .down) { press in
			if press.modifiers == .shift, member.interactions.contains(.move) {
				onAction(.toggleMoveSelection(member.id))
			} else {
				onAction(.splitGroup(.focus(group: split.id, tab: member.tabUUID)))
			}
			return .handled
		}
		.onKeyPress(.return, phases: .down) { _ in
			beginRename()
			return .handled
		}
		.modifier(SplitSegmentDraggable(member: member, split: split))
		.accessibilityElement(children: .combine)
		.accessibilityLabel(member.title)
		.accessibilityAddTraits(.isButton)
		.accessibilityAction(named: String.localized(.appUI.split.focusMember(member.title))) {
			onAction(.splitGroup(.focus(group: split.id, tab: member.tabUUID)))
		}
		.accessibilityAction(named: String.localized(.appUI.split.separate)) {
			onAction(.splitGroup(.separate(group: split.id, tab: member.tabUUID)))
		}
	}

	@ViewBuilder
	private var menu: some View {
		if let linkActions {
			Button(String.localized(.appUI.split.share)) { linkActions.share(split.paneTabIDs) }
		}
		Divider()
		Button(String.localized(.appUI.split.separateAll)) { onAction(.splitGroup(.separateAll(split.id))) }
		Button(String.localized(.appUI.split.addTab)) { onAction(.splitGroup(.addTab(split.id))) }
			.disabled(split.paneIDs.count >= SplitLayout.maximumPanes)
		Button(String.localized(split.isVertical ? .appUI.split.toHorizontal : .appUI.split.toVertical)) {
			onAction(.splitGroup(.toggleOrientation(split.id)))
		}
		Divider()

		// The whole group moves as one block, between the open tabs, Pinned and folders (DEV-1006).
		if split.members.contains(where: \.isPinned) {
			Button(String.localized(.appUI.split.unpin)) { onAction(.setPinned(split.memberIDs, false)) }
		} else {
			Button(String.localized(.appUI.split.pin)) { onAction(.setPinned(split.memberIDs, true)) }
		}
		Button(String.localized(.appUI.move.choose)) { onAction(.splitGroup(.chooseMoveDestination(split.id))) }
		Divider()
		Section(String.localized(.appUI.split.tabOptions)) {
			ForEach(split.members) { member in
				Menu(member.title) { memberMenu(member) }
			}
		}
		Divider()
		Button(String.localized(.appUI.split.changeIcon)) { pickingIcon = true }
		if split.icon != nil {
			Button(String.localized(.appUI.split.clearIcon)) { onAction(.splitGroup(.changeIcon(split.id, nil))) }
		}
		Button(String.localized(.appUI.split.rename), action: beginRename)
		Button(String.localized(.appUI.split.duplicate)) { onAction(.splitGroup(.duplicate(split.id))) }
	}

	@ViewBuilder
	private func memberMenu(_ member: SidebarItem) -> some View {
		let tabID = member.tabUUID
		let nestsCopies = CopySubmenuFeatureFlag.isOn()
		Button(String.localized(.appUI.split.separate)) {
			onAction(.splitGroup(.separate(group: split.id, tab: tabID)))
		}

		// Shares the proxy link, so only where a proxy link rule matches (DEV-1262).
		if let linkActions, !nestsCopies, linkActions.proxies([tabID]) {
			Button(String.localized(.appUI.split.shareTab)) { linkActions.share([tabID]) }
		}
		Button(String.localized(.appUI.split.mute)) { onAction(.splitGroup(.toggleMute(tab: tabID))) }
		if let linkActions, nestsCopies {
			// The same Copy ▸ as a tab row's, Share Proxy Link last (DEV-1162).
			BrowserLinkMenu(tabIDs: [tabID], nestsCopies: true)
				.environment(\.browserLinkActions, linkActions)
		} else if let linkActions {
			Button(String.localized(.appUI.split.copyLink)) { linkActions.copy(.original, [tabID], false) }
			Button(String.localized(.appUI.split.copyLinkMarkdown)) {
				linkActions.copy(.markdownOriginal, [tabID], false)
			}
		}
		Divider()
		BrowserPeekMenu(tabID: tabID)
		BrowserPictureInPictureMenu(tabID: tabID)
		Button(BrowserCommand.duplicateTab.title) { onAction(.splitGroup(.duplicateTab(tabID))) }
		Button(String.localized(.appUI.move.choose)) { onAction(.chooseMoveDestination(member.id)) }
		switch member.tabAction(isSelected: false) {
		case .close:
			Button(String.localized(.appUI.sidebar.closeNamedTab(member.title))) { onAction(.close(member.id)) }
		case .reset:
			Button(String.localized(.appUI.sidebar.resetNamedTab(member.title))) { onAction(.reset(member.id)) }
		case .removePin:
			// Separate, above, is what − does here.
			EmptyView()
		}
	}

	/// A member's own button, as on a tab row: × closes an open tab, and resets a pinned one to its
	/// saved page; then, as −, it separates the pinned tab from the split rather than removing it
	/// (DEV-1006).
	private func perform(
		_ action: SidebarItem.TabAction,
		on member: SidebarItem
	) {
		switch action {
		case .close: onAction(.close(member.id))
		case .reset: onAction(.reset(member.id))
		case .removePin: onAction(.splitGroup(.separate(group: split.id, tab: member.tabUUID)))
		}
	}

	private func title(
		of action: SidebarItem.TabAction,
		for member: SidebarItem
	) -> String {
		switch action {
		case .close: String.localized(.appUI.split.closeMember(member.title))
		case .reset: String.localized(.appUI.sidebar.resetNamedTab(member.title))
		case .removePin: String.localized(.appUI.split.separate)
		}
	}

	private var linkActions: BrowserLinkActions? {
		offersLinks ? actions.linkActions : nil
	}

	private func onAction(_ action: SidebarAction) {
		actions.send(action)
	}

	/// As a tab row: ⇧ or ⌘ adds the member to the move selection, and a plain click clears it.
	private func activate(_ member: SidebarItem) {
		let isSelectingForMove = !NSEvent.actionModifierFlags.isDisjoint(with: [.shift, .command])
		if isSelectingForMove, member.interactions.contains(.move) {
			onAction(.toggleMoveSelection(member.id))
			return
		}
		if !member.moveSelection.isEmpty { onAction(.clearMoveSelection) }
		withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
			onAction(.splitGroup(.focus(group: split.id, tab: member.tabUUID)))
		}
	}

	private func beginRename() {
		draft = split.title ?? ""
		renaming = true
		nameFocused = true
	}

	private func commitRename() {
		guard renaming else { return }
		let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		renaming = false
		nameFocused = false
		onAction(.splitGroup(.rename(split.id, name.isEmpty ? nil : name)))
	}
}

extension SplitSidebarRow: Equatable {
	/// See `SidebarRow`'s conformance: unchanged groups skip their body when the sidebar refreshes.
	public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.item == rhs.item
		&& lhs.split == rhs.split
		&& lhs.depth == rhs.depth
		&& lhs.selected == rhs.selected
		&& lhs.isDropTarget == rhs.isDropTarget
		&& lhs.offersLinks == rhs.offersLinks
		&& lhs.actions === rhs.actions
	}
}

extension SidebarItem {
	fileprivate var tabUUID: UUID {
		switch id {
		case let .tab(id), let .folder(id): id
		}
	}
}

/// Dragging a segment moves the whole group in the sidebar, as one block between the open tabs,
/// Pinned and folders (DEV-1006), unless the segment is part of a larger selection, which moves as
/// it is. Onto the page or out of the window it takes only that tab, into a pane or Little Arx.
private struct SplitSegmentDraggable: ViewModifier {
	private let member: SidebarItem
	private let split: SidebarItem.Split

	@Environment(\.sidebarTabDragChanged)
	private var dragChanged

	@Environment(\.sidebarTabDroppedOutside)
	private var droppedOutside

	fileprivate init(
		member: SidebarItem,
		split: SidebarItem.Split
	) {
		self.member = member
		self.split = split
	}

	fileprivate func body(content: Content) -> some View {
		content.modifier(SidebarDragSource(item: member, fromFavorites: false, group: split.memberIDs) { phase in

			// A multi-tab selection isn't one pane, so the page offers no zones for it.
			guard !(member.moveSelection.contains(member.id) && member.moveSelection.count > 1)
			else { return }
			switch phase {
			case .initial, .active:
				dragChanged?(member.tabUUID)

			case let .ended(operation):
				dragChanged?(nil)

				// Outside every Arx window, the tab leaves its group for Little Arx (DEV-793).
				if !member.isPinned, let point = SidebarTabTearOff.droppedOutside(operation) {
					droppedOutside?(member.tabUUID, point)
				}

			default:
				dragChanged?(nil)
			}
		})
	}
}
