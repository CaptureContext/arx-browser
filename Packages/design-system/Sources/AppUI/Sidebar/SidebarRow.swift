import BrowserCore
import AppKit
import SwiftUI

public struct SidebarRow: View {
	private let item: SidebarItem
	private let depth: Int

	/// A collapsed folder showing its selected tab beneath it (DEV-1110).
	private let isPartlyRevealed: Bool
	private let selected: Bool
	private let joinedEdges: VerticalEdge.Set
	private let isDropTarget: Bool
	private let showsTooltip: Bool

	/// The sidebar's keyboard focus, which the arrow keys move between rows (DEV-731).
	private let focus: FocusState<SidebarItem.ID?>.Binding?

	/// Whether `focus` is on this row, passed in so a focus move re-renders only two rows.
	private let isFocused: Bool
	private let actions: SidebarActionRelay

	@SwiftUI.State
	private var hovered: Bool

	@SwiftUI.State
	private var renaming: Bool

	@SwiftUI.State
	private var draft: String

	/// The volume popover from the tab's speaker or its menu (DEV-800).
	@SwiftUI.State
	private var showsVolume: Bool

	/// The pointer is over the row's close or speaker button, whose press never selects (DEV-914).
	@SwiftUI.State
	private var controlHovered: Bool

	/// Focus for a row on its own, outside a sidebar.
	@FocusState
	private var localFocusedID: SidebarItem.ID?

	/// Whether the keyboard moved focus here. A click focuses the row too, without a ring.
	@SwiftUI.State
	private var isKeyboardFocused: Bool

	@FocusState
	private var nameFocused: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.highlightsLocalTabs)
	private var highlightsLocalTabs

	@Environment(\.sidebarSelectsOnFirstClick)
	private var selectsOnFirstClick

	@Environment(\.sidebarRowPolish)
	private var polish

	/// A row on its own, for the tour and tests. Rows in a sidebar come from `BrowserSidebar`,
	/// which also passes them the window's hover and link handlers; a row on its own has none.
	internal init(
		item: SidebarItem,
		depth: Int = 0,
		isPartlyRevealed: Bool = false,
		selected: Bool = false,
		joinedEdges: VerticalEdge.Set = [],
		isDropTarget: Bool = false,
		showsTooltip: Bool = true,
		hover: SidebarRowHover = .none,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.init(
			item: item,
			depth: depth,
			isPartlyRevealed: isPartlyRevealed,
			selected: selected,
			joinedEdges: joinedEdges,
			isDropTarget: isDropTarget,
			showsTooltip: showsTooltip,
			focus: nil,
			isFocused: false,
			actions: .init(onAction)
		)
		self._hovered = .init(initialValue: hover != .none)
		self._controlHovered = .init(initialValue: hover == .control)
	}

	internal init(
		item: SidebarItem,
		depth: Int,
		isPartlyRevealed: Bool,
		selected: Bool,
		joinedEdges: VerticalEdge.Set,
		isDropTarget: Bool,
		showsTooltip: Bool,
		focus: FocusState<SidebarItem.ID?>.Binding?,
		isFocused: Bool,
		actions: SidebarActionRelay
	) {
		self.item = item
		self.depth = depth
		self.isPartlyRevealed = isPartlyRevealed
		self.selected = selected
		self.joinedEdges = joinedEdges
		self.isDropTarget = isDropTarget
		self.showsTooltip = showsTooltip
		self.focus = focus
		self.isFocused = isFocused
		self.actions = actions
		self._hovered = .init(initialValue: false)
		self._renaming = .init(initialValue: false)
		self._draft = .init(initialValue: "")
		self._showsVolume = .init(initialValue: false)
		self._controlHovered = .init(initialValue: false)
		self._isKeyboardFocused = .init(initialValue: false)
	}

	public var body: some View {
		let _ = SidebarRenderTrace.rowBody(item.id)
		rowWithMenu
			.accessibilityElement(children: .contain)
			.accessibilityLabel(item.title)
			.accessibilityValue(item.accessibilityValue(isSelected: selected, depth: depth))
			.accessibilityAddTraits(selected ? .isSelected : [])
			.accessibilityAction(.default, activate)
			.accessibilityAction(named: String.localized(.appUI.common.renameAction), beginRename)
			.accessibilityAction(named: Text(activationTitle), activate)
			.accessibilityActions { SidebarDeferred { rowAccessibilityActions } }

			// The hover preview replaces the tooltip when the window supplies one.
			.modifier(SidebarRowTooltip(title: showsTooltip ? item.title : nil))
			.background {
				// Only a tab with sound has a volume popover to anchor.
				if item.audio != nil, !item.isFolder {
					Color.clear
						.allowsHitTesting(false)
						.accessibilityHidden(true)
						.popover(isPresented: $showsVolume, arrowEdge: .trailing) { volumePopover }
				}
			}
			.sidebarHoverPreview(item: item, selected: selected, isSuspended: renaming, onAction: onAction)
			.padding(.leading, CGFloat(depth) * 17)
	}

	private var rowWithMenu: some View {
		interactiveRow
			.contextMenu {
				// Built when the menu opens, not with every row scrolled into view (DEV-1235).
				SidebarDeferred {
					if let bulkSelection {
						bulkMenu(bulkSelection)
					} else {
						rowMenu
					}
				}
			}
	}

	@ViewBuilder
	private var rowMenu: some View {
		if case let .tab(id) = item.id {
			tabMenu(id)
		} else {
			containerMenu
		}
	}

	/// A tab's menu, in `SidebarTabMenu`'s order (DEV-1250).
	@ViewBuilder
	private func tabMenu(_ id: UUID) -> some View {
		let groups = SidebarTabMenu.groups(
			for: item.isPinned ? .pinned : .tab,
			traits: .init(item)
		)
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

		case .mute:
			if let audio = item.audio {
				Button(
					audio.isMuted
					? String.localized(.appUI.media.unmuteTab)
					: String.localized(.appUI.media.muteTab)
				) { onAction(.setMuted(item.id, !audio.isMuted)) }
			}

		case .volume:
			Button(String.localized(.appUI.media.volumeMenu)) { showsVolume = true }

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

		case .keepAgentTab:
			Button(String.localized(.appUI.automation.keepTab)) { onAction(.keepAgentTab(item.id)) }

		case .addSplit:
			Button(BrowserCommand.newSplit.title) { onAction(.addSplit(item.id)) }

		case .duplicate:
			Button(BrowserCommand.duplicateTab.title) { onAction(.duplicate(item.id)) }

		case .addToNewGroup:
			Button(String.localized(.appUI.sidebar.addTabToNewGroup)) { onAction(.groupTabs([item.id])) }
				.disabled(!item.interactions.contains(.move))

		case .moveTo:
			Button(String.localized(.appUI.move.choose)) { onAction(.chooseMoveDestination(item.id)) }
				.disabled(!item.interactions.contains(.move))

		case .moveToWindow:
			SidebarWindowMenu(ids: [item.id], offersNewWindow: true, onAction: onAction)
				.disabled(!item.interactions.contains(.move))

		case .close:
			Button(tabActionTitle, action: performTabAction)
				.disabled(!item.interactions.contains(.trailingAction))

		case .closeOthers:
			Button(String.localized(.appUI.sidebar.closeOtherTabs)) { onAction(.closeOtherTabs(item.id)) }
				.disabled(!item.interactions.contains(.trailingAction))

		case .closeBelow:
			Button(String.localized(.appUI.sidebar.closeTabsBelow)) { onAction(.closeTabsBelow(item.id)) }
				.disabled(!item.interactions.contains(.trailingAction))

		case .unpin:
			Button(String.localized(.appUI.move.unpin)) { onAction(.move(item.id, .unpinnedRoot)) }
				.disabled(!item.interactions.contains(.move))

		// A selection's and a Favorite's own items; a row's menu doesn't list them.
		case .pin, .archive, .removeFavorite:
			EmptyView()
		}
	}

	/// A folder's or a tab group's menu, as before the tab menus' order (DEV-1250).
	@ViewBuilder
	private var containerMenu: some View {
		Button(String.localized(.appUI.common.rename), action: beginRename)
			.disabled(!item.interactions.contains(.rename))
		if item.isTabGroup {
			tabGroupActions
		} else {
			folderActions
			Divider()
			Button(String.localized(.appUI.sidebar.newSubfolder)) { onAction(.newFolder(item.id)) }
				.disabled(!item.interactions.contains(.createChild))
			Button(disclosureTitle) { onAction(.toggle(item.id)) }
				.disabled(!item.interactions.contains(.disclose))
			moveActions
		}
	}

	/// A group of open tabs (DEV-911): fold it, pin it as a folder, ungroup or archive its tabs.
	@ViewBuilder
	private var tabGroupActions: some View {
		Button(disclosureTitle) { onAction(.toggle(item.id)) }
			.disabled(!item.interactions.contains(.disclose))
		Divider()
		Button(String.localized(.appUI.sidebar.pinTabGroup)) { onAction(.pinTabGroup(item.id)) }
		Button(String.localized(.appUI.sidebar.ungroupTabs)) { onAction(.ungroupTabGroup(item.id)) }
		Divider()
		let tabs = item.children.flatMap(\.groupTabIDs)
		Button(String.localized(.appUI.sidebar.archiveTabs(tabs.count))) { onAction(.archiveTabs(tabs)) }
			.disabled(tabs.isEmpty)
	}

	/// A tab row in a selection of several tabs acts on the whole selection (DEV-883).
	private var bulkSelection: SidebarItem.Selection? {
		guard
			!item.isFolder,
			let selection = item.selection,
			selection.tabCount > 1
		else { return nil }

		return selection
	}

	/// The selection's menu: each action takes every selected tab and is one undo (DEV-883), in
	/// `SidebarTabMenu`'s order (DEV-1250).
	@ViewBuilder
	private func bulkMenu(_ selection: SidebarItem.Selection) -> some View {
		let groups = SidebarTabMenu.groups(
			for: .selection(.init(openTabCount: selection.openTabCount, savedTabCount: selection.savedTabCount))
		)
		ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
			if index > 0 { Divider() }
			ForEach(group, id: \.self) { menuItem in
				bulkMenuItem(menuItem, selection)
			}
		}
	}

	@ViewBuilder
	private func bulkMenuItem(
		_ menuItem: SidebarTabMenu.Item,
		_ selection: SidebarItem.Selection
	) -> some View {
		let ids = selection.tabIDs
		let canMove = item.interactions.contains(.move)
		let canClose = item.interactions.contains(.trailingAction)
		switch menuItem {
		case .copy:
			BrowserLinkMenu(tabIDs: item.linkTabIDs)

		case .duplicate:
			Button(String.localized(.appUI.sidebar.duplicateTabs(selection.tabCount))) {
				onAction(.duplicateTabs(ids))
			}
			.disabled(!canMove)

		case .addToNewGroup:
			Button(String.localized(.appUI.sidebar.groupTabs(selection.openTabCount))) {
				onAction(.groupTabs(ids))
			}
			.disabled(!canMove)

		case .moveTo:
			Button(String.localized(.appUI.move.choose)) { onAction(.chooseMoveDestination(item.id)) }
				.disabled(!canMove)

		case .moveToWindow:
			SidebarWindowMenu(ids: ids, offersNewWindow: false, onAction: onAction)
				.disabled(!canMove)

		case .pin:
			Button(String.localized(.appUI.sidebar.pinTabs(selection.openTabCount))) {
				onAction(.setPinned(ids, true))
			}
			.disabled(!canMove)

		case .unpin:
			Button(String.localized(.appUI.sidebar.unpinTabs(selection.savedTabCount))) {
				onAction(.setPinned(ids, false))
			}
			.disabled(!canMove)

		case .archive:
			Button(String.localized(.appUI.sidebar.archiveTabs(selection.openTabCount))) {
				onAction(.archiveTabs(ids))
			}
			.disabled(!canClose)

		case .close:
			Button(String.localized(.appUI.sidebar.closeTabs(selection.tabCount))) { onAction(.closeTabs(ids)) }
				.disabled(!canClose)

		case .closeOthers:
			Button(String.localized(.appUI.sidebar.closeOtherTabs)) { onAction(.closeOtherTabs(item.id)) }
				.disabled(!canClose)

		// One tab's own items; a selection's menu doesn't list them.
		case .peek, .changeIcon, .rename, .updateSavedURL, .mute, .volume, .pictureInPicture, .badges,
			.keepSiteLoaded, .keepAgentTab, .addSplit, .closeBelow, .removeFavorite:
			EmptyView()
		}
	}

	@ViewBuilder
	private var volumePopover: some View {
		if let audio = item.audio {
			SidebarTabVolumePopover(
				title: item.title,
				audio: audio,
				onMute: { onAction(.setMuted(item.id, !audio.isMuted)) },
				onVolume: { onAction(.setVolume(item.id, $0)) }
			)
		}
	}

	@ViewBuilder
	private var rowAccessibilityActions: some View {
		// The trailing button only appears on hover, so VoiceOver reaches it here.
		if !item.isFolder, item.interactions.contains(.trailingAction) {
			Button(tabActionTitle, action: performTabAction)
		}
		if let audio = item.audio, !item.isFolder {
			Button(audio.isMuted ? String.localized(.appUI.media.unmuteTab) : String.localized(.appUI.media.muteTab)) {
				onAction(.setMuted(item.id, !audio.isMuted))
			}
		}
		lifecycleAccessibilityActions
		moveActions
	}

	private var interactiveRow: some View {
		HStack(spacing: BrowserMetrics.Row.iconSpacing) {
			icon
				.opacity(contentOpacity)
			if renaming {
				TextField(String.localized(.appUI.common.name), text: $draft)
					.textFieldStyle(.plain)
					.focused($nameFocused)
					.onSubmit(commitRename)
					.onExitCommand { cancelRename() }
					.onChange(of: nameFocused) { _, focused in
						if renaming, !focused { commitRename() }
					}
					.accessibilityIdentifier("rename-\(item.title)")
			} else if let localHost {
				VStack(alignment: .leading, spacing: 0) {
					Text(item.title)
						.fontWeight(.semibold)
						.lineLimit(1)
						.truncationMode(.tail)
					Text(verbatim: localHost)
						.font(.system(size: BrowserMetrics.Row.LocalTab.subtitleFontSize))
						.foregroundStyle(BrowserTheme.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
				.opacity(contentOpacity)
				.frame(maxWidth: polish ? .infinity : nil, alignment: .leading)
			} else {
				Text(item.title)
					.fontWeight(titleWeight)
					.lineLimit(1)
					.truncationMode(.tail)
					.opacity(contentOpacity)

					// The close button follows the title one spacing away, not across a spacer's too.
					.frame(maxWidth: polish ? .infinity : nil, alignment: .leading)
			}
			if !polish || renaming {
				Spacer(minLength: 0)
			}
			if let agent = item.agent, !item.isFolder, !renaming {
				SidebarAgentBadge(agent: agent)
			}
			if let audio = item.audio, audio.showsIndicator, !item.isFolder, !renaming {
				SidebarTabAudioButton(
					audio: audio,
					onMute: { onAction(.setMuted(item.id, !audio.isMuted)) },
					onShowVolume: { showsVolume = true }
				)
				.onHover { controlHovered = $0 }
			}
			if !item.isFolder, !renaming, item.interactions.contains(.trailingAction) {
				if polish {
					polishedTabAction
				} else {
					reservedTabAction
				}
			}

			// The site a Peek opened from this tab shows (DEV-1224).
			SidebarPeekBadge(for: item.id, placement: .row)
		}
		.font(.system(size: BrowserMetrics.Row.fontSize))
		.foregroundStyle(isFolderDropTarget ? AnyShapeStyle(BrowserTheme.onAccent) : AnyShapeStyle(BrowserTheme.text))
		.padding(.leading, BrowserMetrics.Row.horizontalPadding)
		.padding(.trailing, BrowserMetrics.Row.horizontalPadding - 4)
		.frame(height: BrowserMetrics.Row.height)
		.background {
			UnevenRoundedRectangle(cornerRadii: backgroundRadii, style: .continuous)
				.fill(background)
				.browserShadow(isRaised ? BrowserMetrics.Row.selectedShadow : .none)

				// Closes the row gap between joined split members.
				.padding(.top, joinedEdges.contains(.top) ? -BrowserMetrics.Row.spacing / 2 : 0)
				.padding(.bottom, joinedEdges.contains(.bottom) ? -BrowserMetrics.Row.spacing / 2 : 0)
		}
		.overlay {
			if localHost != nil, !isDropTarget {
				ConstructionTapeBorder(cornerRadii: backgroundRadii)
			}
		}
		.overlay {
			if showsFocusRing {
				UnevenRoundedRectangle(cornerRadii: backgroundRadii, style: .continuous)
					.strokeBorder(BrowserTheme.accent, lineWidth: 2)
					.allowsHitTesting(false)
			}
		}
		.contentShape(.rect)
		.contentShape(
			.dragPreview,
			.rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
		)
		.modifier(SidebarDraggable(item: item))
		.dragConfiguration(.init(
			operationsWithinApp: .init(
				allowCopy: false,
				allowMove: true
			),
			operationsOutsideApp: .init(allowCopy: false)
		))
		.focusable(!renaming)
		.focusEffectDisabled()
		.focused(focus ?? $localFocusedID, equals: item.id)
		.onChange(of: hasFocus) { _, focused in
			isKeyboardFocused = focused && NSApp.currentEvent?.type == .keyDown
		}

		// One handler for every key a row takes: each handler is a responder of its own, built
		// with the row (DEV-1235).
		.onKeyPress(phases: [.down, .repeat], action: keyPressed)
		.onHover { isHovered in
			hovered = isHovered

			// The close button leaves with the hover, and with it the hover it reported.
			if !isHovered { controlHovered = false }
			item.reportHover(isHovered, to: actions.tabHoverChanged)
			pressTargetChanged()
		}
		.onChange(of: [selected, renaming, controlHovered]) { pressTargetChanged() }
		.onDisappear { SidebarPressActivation.leave(item.id) }
		.modifier(SidebarActivation(
			isFolder: item.isFolder,
			activate: activate,
			rename: beginRename
		))
	}

	/// Return renames, or opens a folder's tabs with ⌘; Delete removes a folder; ⌘⇧M moves and
	/// ⌘⇧G ungroups a folder; Space activates, or selects for moving with Shift. Only Delete repeats.
	private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
		guard !renaming else { return .ignored }

		let isDown: Bool = press.phase == .down
		switch press.key {
		case .return where isDown:
			if press.modifiers.contains(.command), item.isFolder {
				guard item.interactions.contains(.folderLifecycle) else { return .ignored }
				onAction(.openFolder(item.id, includingDescendants: press.modifiers.contains(.shift)))
			} else {
				beginRename()
			}
			return .handled

		case .delete:
			guard
				item.isFolder,
				item.interactions.contains(.folderLifecycle)
			else { return .ignored }
			onAction(.deleteFolder(item.id))
			return .handled

		case .space where isDown:
			if press.modifiers == .shift, item.interactions.contains(.move) {
				onAction(.toggleMoveSelection(item.id))
			} else {
				activate()
			}
			return .handled

		default:
			guard isDown, press.modifiers.contains([.command, .shift]) else { return .ignored }

			switch press.characters.lowercased() {
			case "m" where item.interactions.contains(.move):
				onAction(.chooseMoveDestination(item.id))
				return .handled

			case "g" where item.isFolder && item.interactions.contains(.folderLifecycle):
				onAction(.ungroupFolder(item.id))
				return .handled

			default:
				return .ignored
			}
		}
	}

	@ViewBuilder
	private var lifecycleAccessibilityActions: some View {
		if item.isFolder { folderActions }
		if item.isPinned, !item.isFolder, item.interactions.contains(.updateSavedURL) {
			Button(String.localized(.appUI.sidebar.updateSavedURL)) {
				onAction(.updateSavedURL(item.id))
			}
		}
	}

	private var moveActions: some View {
		Group {
			Button(String.localized(.appUI.move.choose)) { onAction(.chooseMoveDestination(item.id)) }
			if item.isPinned, !item.isFolder {
				Button(String.localized(.appUI.move.unpin)) { onAction(.move(item.id, .unpinnedRoot)) }
			}
		}
		.disabled(!item.interactions.contains(.move))
	}

	private var folderActions: some View {
		Group {
			Button(String.localized(.appUI.sidebar.openFolderTabs)) {
				onAction(.openFolder(item.id, includingDescendants: false))
			}
			Button(String.localized(.appUI.sidebar.openAllFolderTabs)) {
				onAction(.openFolder(item.id, includingDescendants: true))
			}
			Button(String.localized(.appUI.sidebar.ungroupFolder)) { onAction(.ungroupFolder(item.id)) }
			Button(String.localized(.appUI.sidebar.deleteFolder), role: .destructive) {
				onAction(.deleteFolder(item.id))
			}
		}
		.disabled(!item.interactions.contains(.folderLifecycle))
	}

	/// The close button, keeping its room while hidden, as before `SidebarRowPolish`.
	private var reservedTabAction: some View {
		Button(action: performTabAction) {
			SidebarTabActionIcon(isMinus: tabAction == .reset)
				.frame(width: 22, height: 22)
		}
		.buttonStyle(ChromeButtonStyle())
		.opacity(hovered ? 1 : 0)
		.allowsHitTesting(hovered)
		.onHover { controlHovered = $0 }

		// The close button takes the badge's place on hover (DEV-907).
		.overlay(alignment: .trailing) {
			if let unread = item.unread, !hovered {
				SidebarUnreadBadge(unread.badge)
			}
		}
		.help(tabActionTitle)
		.accessibilityLabel(tabActionTitle)
	}

	/// The close button, only while the row is hovered, so the title takes its room otherwise; the
	/// unread badge stands there until then (DEV-907).
	@ViewBuilder
	private var polishedTabAction: some View {
		if hovered {
			Button(action: performTabAction) {
				SidebarTabActionIcon(isMinus: tabAction == .reset)
					.frame(width: 22, height: 22)
			}
			.buttonStyle(ChromeInlineButtonStyle(shapeInset: 0))

			// A row drawn with the pointer on its button (snapshots) shows the button hovered.
			.arxControlState(.init(isHovered: controlHovered ? true : nil))

			// Closer to the title than the row's other spacing.
			.padding(.leading, BrowserMetrics.Row.actionGap - BrowserMetrics.Row.iconSpacing)
			.onHover { controlHovered = $0 }
			.help(tabActionTitle)
			.accessibilityLabel(tabActionTitle)
		} else if let unread = item.unread {
			SidebarUnreadBadge(unread.badge)
		}
	}

	private var titleWeight: Font.Weight {
		guard item.isFolder else { return .regular }
		return polish ? .bold : .medium
	}

	private var tabAction: SidebarItem.TabAction { item.tabAction(isSelected: selected) }

	private var disclosureTitle: String {
		item.isExpanded
		? String.localized(.appUI.sidebar.collapseFolder)
		: String.localized(.appUI.sidebar.expandFolder)
	}

	private var activationTitle: String {
		item.isFolder
		? String.localized(.appUI.sidebar.toggleFolder)
		: String.localized(.appUI.sidebar.selectTab)
	}

	private var tabActionTitle: String {
		switch tabAction {
		case .reset: String.localized(.appUI.sidebar.resetNamedTab(item.title))
		case .removePin: String.localized(.appUI.sidebar.removeNamedPin(item.title))
		case .close: String.localized(.appUI.sidebar.closeNamedTab(item.title))
		}
	}

	private func performTabAction() {
		guard item.interactions.contains(.trailingAction) else { return }
		switch tabAction {
		case .reset: onAction(.reset(item.id))
		case .removePin: onAction(.removePin(item.id))
		case .close: onAction(.close(item.id))
		}
	}

	private var icon: some View {
		ZStack {
			if item.isFolder {
				SidebarFolderIcon(
					isExpanded: item.isExpanded,
					isPartlyRevealed: isPartlyRevealed,
					isOnAccent: isFolderDropTarget
				)
			} else {
				FavoriteSiteIcon(
					key: item.siteIcon,
					fallback: item.symbol,
					tint: item.tint,
					size: BrowserMetrics.Row.iconSize,
					fallbackSize: BrowserMetrics.Row.iconSize - 2,
					fallbackWeight: .medium,
					showsPlaceholder: true
				)
				.sidebarTabIcon(item, size: BrowserMetrics.Row.iconSize, onAction: onAction)
			}
		}
		.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
		.webKitPageBadge(item.usesWebKit && !item.isFolder)
	}

	/// An unloaded tab's icon and title fade until it's shown again (DEV-873). The selected
	/// row is loading already.
	private var contentOpacity: Double {
		item.isUnloaded && !selected ? BrowserMetrics.Row.unloadedOpacity : 1
	}

	private var backgroundRadii: RectangleCornerRadii {
		let radius = BrowserMetrics.Row.cornerRadius
		let top = joinedEdges.contains(.top) ? 0 : radius
		let bottom = joinedEdges.contains(.bottom) ? 0 : radius
		return .init(
			topLeading: top,
			bottomLeading: bottom,
			bottomTrailing: bottom,
			topTrailing: top
		)
	}

	/// The host:port under the title, while local tabs are highlighted and the row isn't renamed.
	private var localHost: String? {
		guard highlightsLocalTabs, !item.isFolder else { return nil }
		return item.localHost
	}

	private var hasFocus: Bool { focus == nil ? localFocusedID == item.id : isFocused }

	/// Keyboard focus draws the accent ring that Favorites use; a click's focus draws none.
	private var showsFocusRing: Bool { hasFocus && isKeyboardFocused && !renaming }

	private var isRaised: Bool { (selected || renaming) && !isDropTarget }

	/// A folder about to take the drop fills with the accent.
	private var isFolderDropTarget: Bool { isDropTarget && item.isFolder }

	private var background: AnyShapeStyle {
		if isFolderDropTarget { return AnyShapeStyle(BrowserTheme.accent) }
		if isDropTarget { return AnyShapeStyle(BrowserTheme.accent.opacity(0.35)) }
		if selected || renaming { return AnyShapeStyle(BrowserTheme.selectedRow) }
		return AnyShapeStyle(hovered || item.moveSelection.contains(item.id) ? BrowserTheme.rowHover : .clear)
	}

	private func onAction(_ action: SidebarAction) {
		actions.send(action)
	}

	/// A plain press on a tab that isn't selected switches as the button goes down (DEV-914, DEV-994),
	/// unless `ARX_SIDEBAR_PRESS_SELECTS` is off. A folder, the selected tab, a renaming row and the
	/// row's buttons always wait for release.
	private func pressTargetChanged() {
		let selectsOnPress = hovered
		&& !selected
		&& !item.isFolder
		&& !renaming
		&& !controlHovered
		&& selectsOnFirstClick
		&& item.interactions.contains(.select)

		if selectsOnPress {
			SidebarPressActivation.hover(item.id, activate: selectOnPress)
		} else {
			SidebarPressActivation.leave(item.id)
		}
	}

	/// The press selects the tab and leaves the move selection, which a drag starting now still
	/// carries; the click that completes the press clears it.
	private func selectOnPress() {
		guard !renaming, item.interactions.contains(.select) else { return }
		withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
			onAction(.selectOnPress(item.id))
		}
	}

	private func activate() {
		if SidebarPressActivation.consume(item.id) {
			if !item.moveSelection.isEmpty { onAction(.clearMoveSelection) }
			onAction(.pressCompleted(item.id))
			return
		}
		guard
			!renaming,
			item.interactions.contains(item.isFolder ? .disclose : .select)
		else { return }

		let isSelectingForMove = !NSEvent.actionModifierFlags.isDisjoint(with: [.shift, .command])
		if isSelectingForMove, item.interactions.contains(.move) {
			onAction(.toggleMoveSelection(item.id))
			return
		}
		if !item.moveSelection.isEmpty { onAction(.clearMoveSelection) }
		withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
			onAction(item.isFolder ? .toggle(item.id) : .select(item.id))
		}
	}

	private func beginRename() {
		guard item.interactions.contains(.rename) else { return }
		draft = item.title
		renaming = true
		nameFocused = true
	}

	private func commitRename() {
		guard renaming else { return }
		let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
		renaming = false
		nameFocused = false
		takeFocus()
		if !name.isEmpty, name != item.title { onAction(.rename(item.id, name)) }
	}

	private func takeFocus() {
		if let focus {
			focus.wrappedValue = item.id
		} else {
			localFocusedID = item.id
		}
	}

	private func cancelRename() {
		renaming = false
		nameFocused = false
		takeFocus()
	}
}

extension SidebarRow: Equatable {
	/// Rows compare by what they show, so an unchanged row skips its body when the sidebar
	/// refreshes. The relay compares by identity: it always reaches the sidebar's latest handlers.
	/// Rows read no window handlers from the environment for the same reason: the window sets
	/// new closures on every pass, and each one ran every row's body again. The focus binding
	/// always points at the sidebar's one `FocusState`; `isFocused` carries what it says.
	public nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.item == rhs.item
		&& lhs.depth == rhs.depth
		&& lhs.isPartlyRevealed == rhs.isPartlyRevealed
		&& lhs.selected == rhs.selected
		&& lhs.joinedEdges == rhs.joinedEdges
		&& lhs.isDropTarget == rhs.isDropTarget
		&& lhs.showsTooltip == rhs.showsTooltip
		&& lhs.isFocused == rhs.isFocused
		&& (lhs.focus == nil) == (rhs.focus == nil)
		&& lhs.actions === rhs.actions
	}
}

private struct SidebarDraggable: ViewModifier {
	private let item: SidebarItem

	@Environment(\.sidebarTabDragChanged)
	private var dragChanged

	@Environment(\.sidebarTabDroppedOutside)
	private var droppedOutside

	fileprivate init(item: SidebarItem) {
		self.item = item
	}

	@ViewBuilder
	fileprivate func body(content: Content) -> some View {
		if item.interactions.contains(.move) {
			content.modifier(SidebarDragSource(item: item, fromFavorites: false) { phase in

				// Only a single tab can become a pane; the page offers zones for it alone. A pinned
				// one becomes an open tab when it joins (DEV-992).
				let isMultiple = item.moveSelection.contains(item.id) && item.moveSelection.count > 1
				guard case let .tab(id) = item.id, !isMultiple else { return }
				switch phase {
				case .initial, .active:
					dragChanged?(id)

				case let .ended(operation):
					dragChanged?(nil)

					// Outside every Arx window, an open tab moves into Little Arx (DEV-793).
					if !item.isPinned, let point = SidebarTabTearOff.droppedOutside(operation) { droppedOutside?(id, point) }

				default:
					dragChanged?(nil)
				}
			})
		} else {
			content
		}
	}
}

extension EnvironmentValues {
	/// Whether local-network tabs show the construction-tape border and their host:port, from
	/// Settings › Developer (DEV-786).
	@Entry
	public var highlightsLocalTabs: Bool = true

	/// Whether a tab's first click selects it at once. Where selecting takes the row away, as in
	/// the Library's columns, a click waits to see whether it starts a double-click instead.
	@Entry
	public var sidebarSelectsOnFirstClick: Bool = true
}

/// A row's plain tooltip, where it has one. A row whose hover preview stands in for it carries
/// no tooltip at all, not an empty one.
private struct SidebarRowTooltip: ViewModifier {
	private let title: String?

	fileprivate init(title: String?) {
		self.title = title
	}

	@ViewBuilder
	fileprivate func body(content: Content) -> some View {
		if let title {
			content.help(title)
		} else {
			content
		}
	}
}

/// Content built when SwiftUI asks for it, as a menu does when it opens, not when the view
/// holding it is.
internal struct SidebarDeferred<Content: View>: View {
	private let content: () -> Content

	internal init(@ViewBuilder _ content: @escaping () -> Content) {
		self.content = content
	}

	internal var body: some View {
		content()
	}
}

/// Clicks select or disclose at once; a tab's double-click renames it.
internal struct SidebarActivation: ViewModifier {
	private let isFolder: Bool
	private let activate: () -> Void
	private let rename: () -> Void

	@Environment(\.sidebarSelectsOnFirstClick)
	private var selectsOnFirstClick

	internal init(
		isFolder: Bool,
		activate: @escaping () -> Void,
		rename: @escaping () -> Void
	) {
		self.isFolder = isFolder
		self.activate = activate
		self.rename = rename
	}

	@ViewBuilder
	internal func body(content: Content) -> some View {
		if isFolder {
			content.onTapGesture(perform: activate)
		} else if !selectsOnFirstClick {
			content
				.onTapGesture(count: 2, perform: rename)
				.onTapGesture(perform: activate)
		} else {
			// The double-click runs alongside the click rather than ahead of it: as rivals, every
			// click waited out the system's double-click interval before selecting the tab. Its
			// second click selects the same tab again, which changes nothing, and then renames.
			content
				.onTapGesture(perform: activate)
				.simultaneousGesture(TapGesture(count: 2).onEnded(rename))
		}
	}
}

extension SidebarItem {
	/// What VoiceOver reads after the title: the kind of row, its selected or expanded state,
	/// and how deep it sits in nested folders, which the sidebar shows only as indentation.
	internal func accessibilityValue(
		isSelected: Bool,
		depth: Int
	) -> String {
		let state: String = if isFolder {
			isExpanded
			? .localized(.appUI.sidebar.expandedFolder)
			: .localized(.appUI.sidebar.collapsedFolder)
		} else if isSelected {
			.localized(.appUI.sidebar.selectedTab)
		} else if isUnloaded {
			.localized(.appUI.sidebar.unloadedTab)
		} else {
			.localized(.appUI.sidebar.tab)
		}
		guard depth > 0 else { return state }

		return .localized(.appUI.sidebar.nestingLevel(state, depth + 1))
	}
}

/// A cross whose two strokes fold together into a minus, rather than swapping one symbol for another.
internal struct SidebarTabActionIcon: View {
	private let isMinus: Bool

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(isMinus: Bool) {
		self.isMinus = isMinus
	}

	internal var body: some View {
		ZStack {
			stroke(angle: 45)
			stroke(angle: -45)
		}
		.animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isMinus)
	}

	private func stroke(angle: Double) -> some View {
		Capsule()
			.frame(
				width: BrowserMetrics.Row.actionStrokeLength,
				height: BrowserMetrics.Row.actionStrokeWidth
			)
			.rotationEffect(.degrees(isMinus ? 0 : angle))
	}
}

/// Yellow and black construction tape around a local-network tab's row (DEV-786): a black
/// stroke with yellow dashes over it. The colors stay the same in light and dark appearance,
/// like real tape, and the stroke sits inside the row so it never covers its neighbours.
internal struct ConstructionTapeBorder: View {
	internal static let yellow: Color = .init(red: 1, green: 0.8, blue: 0.1)
	internal static let black: Color = .init(red: 0.1, green: 0.1, blue: 0.1)

	private let cornerRadii: RectangleCornerRadii

	internal init(cornerRadii: RectangleCornerRadii) {
		self.cornerRadii = cornerRadii
	}

	internal var body: some View {
		let shape = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
		let width = BrowserMetrics.Row.LocalTab.tapeWidth
		let dash = BrowserMetrics.Row.LocalTab.tapeDash
		ZStack {
			shape.strokeBorder(Self.black, lineWidth: width)
			shape.strokeBorder(Self.yellow, style: StrokeStyle(lineWidth: width, dash: [dash, dash]))
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

extension SidebarItem {
	/// The tabs a tab group's row stands for: each tab, or each member of a Split View row.
	fileprivate var groupTabIDs: [SidebarItem.ID] {
		split?.memberIDs ?? [id]
	}
}

/// Where the pointer rests on a row on its own, for snapshots.
internal enum SidebarRowHover: Equatable {
	case none
	case row

	/// On the row's close button.
	case control
}
