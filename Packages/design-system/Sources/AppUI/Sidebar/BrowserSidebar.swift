import AppKit
import BrowserCore
import SwiftUI

public struct BrowserSidebar: View {
	/// A space in the pager, or a column of the Library's Spaces section.
	public enum Style {
		case page

		/// The column's icon opens its picker, which `pickingIcon` presents beneath it.
		/// `onPickIcon` gets nil from the picker's reset button (DEV-1251).
		case column(pickingIcon: Binding<Bool>, onPickIcon: (SpaceIcon?) -> Void, profile: AnyView)
	}

	private let spaceName: String
	private let spaceSymbol: String
	private let isExpanded: Bool
	private let savedItems: [SidebarItem]
	private let unpinnedTabs: [SidebarItem]
	private let selectedID: SidebarItem.ID?
	private let splitIDs: Set<SidebarItem.ID>
	private let isNewTabPending: Bool
	private let canClearTabs: Bool
	private let pinnedHeight: CGFloat
	private let onAction: (SidebarAction) -> Void
	private let onDragAtEdge: (SidebarDragEdge) -> Void
	private let spaceMenu: AnyView?
	private let showsPinnedHint: Bool
	private let canRenameSpace: Bool
	private let style: Style

	@Environment(\.sidebarInteraction)
	private var interaction

	@SwiftUI.State
	private var rootTarget: SidebarDropTarget?

	/// How far rows have scrolled under the header and the footer. Kept outside view state and
	/// read only by the edges themselves: as state here, every frame of a scroll near either end
	/// ran this whole body again (DEV-1235).
	@SwiftUI.State
	private var scrollEdges: SidebarScrollEdges

	/// Whether fingers or their momentum are scrolling the rows, read only by the modifier that
	/// takes the rows out of hit-testing meanwhile (DEV-1310).
	@SwiftUI.State
	private var scrollLatch: SidebarScrollLatch

	@SwiftUI.State
	private var viewportHeight: CGFloat

	@SwiftUI.State
	private var headingHovered: Bool

	@SwiftUI.State
	private var menuHovered: Bool

	@SwiftUI.State
	private var isRenamingSpace: Bool

	@SwiftUI.State
	private var spaceNameDraft: String

	@FocusState
	private var spaceNameFocused: Bool

	@SwiftUI.State
	private var sidebarHovered: Bool

	@SwiftUI.State
	private var rowFrames: [SidebarItem.ID: CGRect]

	@SwiftUI.State
	private var newTabFrame: CGRect

	@SwiftUI.State
	private var dropPlacement: SidebarDropPlacement?

	@SwiftUI.State
	private var dragEdge: SidebarDragEdge?

	@SwiftUI.State
	private var listWidth: CGFloat

	@SwiftUI.State
	private var listFrame: CGRect

	@SwiftUI.State
	private var dropOwner: UUID

	/// Whether a drop session is over the rows, which measures their frames.
	@SwiftUI.State
	private var isDropTargeted: Bool

	/// The drop session's latest location, kept outside view state since it changes on every move.
	@SwiftUI.State
	private var dropSession: SidebarDropSession

	/// Keyboard focus among the rows, so the arrow keys can move it (DEV-731).
	@FocusState
	private var focusedRow: SidebarItem.ID?

	/// Rows send through this, so a new `onAction` reaches them without making them look changed.
	@SwiftUI.State
	private var rowActions: SidebarActionRelay

	/// Tabs a collapsed folder just stopped showing, kept while a double-click on the row the
	/// pointer pressed could still land, so the rows don't move under it (DEV-1110).
	@SwiftUI.State
	private var lingeringRevealedIDs: Set<SidebarItem.ID>

	/// The folders and tab groups shown open at the last change, and those that closed since and
	/// are still folding their rows away (DEV-1249).
	@SwiftUI.State
	private var openFolderIDs: Set<SidebarItem.ID>

	@SwiftUI.State
	private var foldingFolderIDs: Set<SidebarItem.ID>

	@Environment(\.sidebarDragPreview)
	private var dragPreview

	@Namespace
	private var dropCoordinateSpace

	/// Off for a sidebar that isn't on screen, so it can't take a drop meant for the page (DEV-793).
	@Environment(\.sidebarAcceptsDrops)
	private var acceptsDrops

	@Environment(\.reorderHapticsEnabled)
	private var reorderHapticsEnabled

	/// Resets of pins, which shake their rows (DEV-1225).
	@Environment(\.sidebarResetPulses)
	private var resetPulses: [SidebarItem.ID: Int]

	@Environment(\.splitPaneLimits)
	private var splitPaneLimits

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.sidebarHoverPreviews)
	private var hoverPreviews

	@Environment(\.sidebarRowMotion)
	private var rowMotion

	/// Where the pager keeps this space's scroll position while the space isn't mounted.
	@Environment(\.sidebarScrollSlot)
	private var scrollSlot

	public init(
		spaceName: String,
		spaceSymbol: String = "square.stack",
		isExpanded: Bool = true,
		savedItems: [SidebarItem],
		unpinnedTabs: [SidebarItem],
		selectedID: SidebarItem.ID?,
		splitIDs: Set<SidebarItem.ID> = [],
		isNewTabPending: Bool = false,
		canClearTabs: Bool = true,
		pinnedHeight: CGFloat = 0,
		spaceMenu: AnyView? = nil,
		showsPinnedHint: Bool = true,
		canRenameSpace: Bool = true,
		style: Style = .page,
		onDragAtEdge: @escaping (SidebarDragEdge) -> Void = { _ in },
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.spaceName = spaceName
		self.spaceSymbol = spaceSymbol
		self.isExpanded = isExpanded
		self.savedItems = savedItems
		self.unpinnedTabs = unpinnedTabs
		self.selectedID = selectedID
		self.splitIDs = splitIDs
		self.isNewTabPending = isNewTabPending
		self.canClearTabs = canClearTabs
		self.pinnedHeight = pinnedHeight
		self.onAction = onAction
		self.onDragAtEdge = onDragAtEdge
		self.spaceMenu = spaceMenu
		self.showsPinnedHint = showsPinnedHint
		self.canRenameSpace = canRenameSpace
		self.style = style
		self._scrollEdges = .init(initialValue: .init())
		self._scrollLatch = .init(initialValue: .init())
		self._viewportHeight = .init(initialValue: 0)
		self._headingHovered = .init(initialValue: false)
		self._menuHovered = .init(initialValue: false)
		self._isRenamingSpace = .init(initialValue: false)
		self._spaceNameDraft = .init(initialValue: "")
		self._sidebarHovered = .init(initialValue: false)
		self._rowFrames = .init(initialValue: [:])
		self._newTabFrame = .init(initialValue: .zero)
		self._listWidth = .init(initialValue: 0)
		self._listFrame = .init(initialValue: .zero)
		self._dropOwner = .init(initialValue: UUID())
		self._isDropTargeted = .init(initialValue: false)
		self._dropSession = .init(initialValue: .init())
		self._rowActions = .init(initialValue: .init())
		self._lingeringRevealedIDs = .init(initialValue: [])
		self._openFolderIDs = .init(initialValue: SidebarTreeRow.expandedFolderIDs(in: savedItems + unpinnedTabs))
		self._foldingFolderIDs = .init(initialValue: [])
	}

	public var body: some View {
		let _ = SidebarRenderTrace.sidebarBody(spaceName)
		let _ = rowActions.handler = onAction

		// Rows only measure their frames while a drag needs them to place a drop.
		let measuresRows: Bool = isDropTargeted || dragPreview?.item != nil
		ScrollView {
			ScrollViewReader { proxy in

				// Lazy, so a space builds only the rows on screen, however many tabs it holds. Each
				// item carries the space below it, so a folded row takes its space with it (DEV-1249).
				LazyVStack(spacing: 0) {
					savedRows(measured: measuresRows)
					if isExpanded, savedItems.isEmpty, showsPinnedHint, !isColumn {
						pinnedHint.padding(.bottom, BrowserMetrics.Row.spacing)
					}

					if !unpinnedTabs.isEmpty { tabsDivider.padding(.bottom, BrowserMetrics.Row.spacing) }

					Group {
						if isColumn {
							// Columns offer no New Tab, but dropping still needs the line between saved and open.
							Color.clear.frame(height: 1)
						} else {
							Button { onAction(.newTab) } label: {
								Label(String.localized(.appUI.sidebar.newTab), systemImage: "plus")
									.labelStyle(SidebarRowLabelStyle())
									.font(.system(size: BrowserMetrics.Row.fontSize))
									.frame(maxWidth: .infinity, alignment: .leading)
									.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
									.frame(height: BrowserMetrics.Row.height)
							}
							.buttonStyle(SidebarNewTabStyle(isPending: isNewTabPending))
							.foregroundStyle(isNewTabPending ? BrowserTheme.text : BrowserTheme.secondary)
						}
					}
					.onGeometryChange(for: CGRect.self) { [dropCoordinateSpace] geometry in
						geometry.frame(in: .named(dropCoordinateSpace))
					} action: { newTabFrame = $0 }

					// Off screen the lazy stack drops it, and the rows around it may move meanwhile.
					.onDisappear { newTabFrame = .zero }
					.padding(.bottom, BrowserMetrics.Row.spacing)

					ForEach(SidebarTreeRow.flatten(unpinnedTabs, revealing: revealedIDs, folding: folding)) { row in
						shownRow(row, measured: measuresRows)
					}
				}

				// Tabs coming, going and moving slide on a spring (DEV-1187).
				.sidebarRowMotion(shownRows)
				.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
				.padding(.bottom, 12)
				.frame(minHeight: viewportHeight, alignment: .top)
				.contentShape(.rect)
				.coordinateSpace(name: dropCoordinateSpace)
				.onPreferenceChange(SidebarRowFrames.self) { rowFrames = $0 }
				.onChange(of: rowFrames) {
					// Frames measured after a drag arrived place it where it already is.
					guard let location = dropSession.location else { return }
					dropPlacement = dropLayout.placement(at: location)
				}
				.overlay(alignment: .topLeading) { insertionIndicator }
				.background {
					if scrollSlot != nil { SidebarScrollRestorer(slot: scrollSlot) }
				}
				.modifier(SidebarScrollLatched(latch: scrollLatch))
				.sidebarDragFrame { listFrame = $0 }
				.sidebarDropArea(isEnabled: acceptsDrops) { area in
					area
						.dropDestination(for: SidebarTransfer.self, action: rowsDropped)
						.dropConfiguration { session in
							let placement = dropLayout.placement(at: session.location)
							let refused = placement == nil
							|| placement?.exceedsSplit(limits: splitPaneLimits, in: splitRows) == true
							return .init(operation: refused ? .forbidden : .move)
						}
						.onDropSessionUpdated(rowsDropUpdated)
				}
				.task(id: targetedFolderID) { await expandHoveredFolder() }
				.task(id: dragEdge) { await pageToHoveredEdge() }
				.onChange(of: selectionRevealedIDs) { old, new in
					lingeringRevealedIDs = SidebarFolderReveal.lingering(
						after: old,
						now: new,
						pointerInSidebar: sidebarHovered
					)
				}
				.task(id: lingeringRevealedIDs) { await endLingeringReveal() }
				.onChange(of: SidebarTreeRow.expandedFolderIDs(in: savedItems + unpinnedTabs)) { old, new in
					openFolderIDs = new
					guard rowMotion, !reduceMotion else { return }

					// A folder open again stops folding, so closing it once more starts its wait over.
					foldingFolderIDs = foldingFolderIDs.subtracting(new).union(old.subtracting(new))
				}
				.task(id: foldingFolderIDs) { await endFolding() }
				.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
				.onKeyPress(
					keys: [.upArrow, .downArrow, .leftArrow, .rightArrow],
					phases: [.down, .repeat]
				) { arrowPressed($0, proxy: proxy) }
				.onChange(of: focusedRow) { _, id in
					guard let id else { return }
					withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
						proxy.scrollTo(id)
					}
				}
			}
		}
		.scrollIndicators(.hidden)

		// Selecting in a Library column closes the Library, so its rows wait to see whether a
		// click is the start of a double-click, which renames.
		.environment(\.sidebarSelectsOnFirstClick, !isColumn)
		.scrollBounceBehavior(.always, axes: .vertical)
		.scrollEdgeEffectHidden(true)

		// AppKit still gives the scroll view a pocket under the header and the title bar, which
		// blurs with a hard cut and a line even with the edge effect hidden (DEV-826).
		.background { ArxScrollPocketSeparator.Hider(hiddenPockets: .all) }
		.background { SidebarRelayEnvironment(relay: rowActions) }
		.scrollClipDisabled()
		.defaultScrollAnchor(.top, for: .initialOffset)
		.modifier(SidebarScrollRecording(slot: scrollSlot))
		.onScrollPhaseChange { [scrollLatch] _, phase in
			scrollLatch.phaseChanged(phase)
		}
		.onScrollGeometryChange(for: CGFloat.self) { geometry in
			min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0) / 24, 1)
		} action: { [scrollEdges] _, progress in
			scrollEdges.header = progress
		}
		.onScrollGeometryChange(for: CGFloat.self) { geometry in
			max(
				geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom,
				0
			)
		} action: { _, height in
			viewportHeight = height
		}
		.onScrollGeometryChange(for: CGFloat.self) { geometry in
			let contentBottom = geometry.contentSize.height + geometry.contentInsets.bottom
			let visibleBottom = geometry.contentOffset.y + geometry.containerSize.height
			let remaining = contentBottom - visibleBottom
			return min(max(remaining / 24, 0), 1)
		} action: { [scrollEdges] _, progress in
			scrollEdges.footer = progress
		}
		.safeAreaInset(edge: .top, spacing: 0) { pinnedHeader }
		.clipped()
		.onHover { sidebarHovered = $0 }
		.background { SidebarFooterOverlapReport(edges: scrollEdges) }
		.animation(reduceMotion ? nil : .smooth(duration: 0.22), value: isExpanded)
	}

	private var pinnedHeader: some View {
		VStack(spacing: 0) {
			// Room for the URL bar and Favorites, which stay still above the sliding spaces.
			Color.clear.frame(height: pinnedHeight)

			heading
				.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
				.padding(.bottom, 4)
		}
		.background {
			// Arx's progressive edge, as Settings' bars (DEV-826): rows scrolling up under the URL
			// bar, Favorites and the space's name blur and melt into the chrome's tint, at full
			// strength under them and easing out just below the name, rather than crossfading
			// into a material, which ghosted and tinted (DEV-807). The sidebar's denser veil also
			// fades rows passing under the window's toolbar row, above the edge; a Library column
			// keeps the standard one, as the Library's other pages.
			SidebarHeaderEdge(edges: scrollEdges, isColumn: isColumn)
		}
	}

	private var isColumn: Bool {
		if case .column = style { return true }
		return false
	}

	/// A column names its space for editing rather than folding it.
	@ViewBuilder
	private func columnHeading(
		pickingIcon: Binding<Bool>,
		onPickIcon: @escaping (SpaceIcon?) -> Void,
		profile: AnyView
	) -> some View {
		HStack(spacing: BrowserMetrics.Row.iconSpacing) {
			Button { pickingIcon.wrappedValue = true } label: {
				SpaceIconImage(rawValue: spaceSymbol)
					.font(.system(size: 11, weight: .semibold))
					.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
					.contentShape(.rect)
			}
			.buttonStyle(.plain)
			.disabled(!canRenameSpace)
			.spaceIconPicker(
				isPresented: pickingIcon,
				selection: SpaceIcon(rawValue: spaceSymbol).flatMap { $0 == .dot ? nil : $0 },
				edge: .bottom,
				onReset: { onPickIcon(nil) },
				onSelect: onPickIcon
			)
			if isRenamingSpace {
				spaceNameField
			} else {
				Text(spaceName)
					.font(.system(size: BrowserMetrics.Section.headerFontSize, weight: .semibold))
					.lineLimit(1)
					.onTapGesture(perform: beginSpaceRename)
			}
			Spacer(minLength: 4)
			profile
		}
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
		.frame(height: BrowserMetrics.Section.headerHeight)
		.background(
			rootTarget == .savedRoot ? AnyShapeStyle(BrowserTheme.accent.opacity(0.25)) : AnyShapeStyle(Color.clear),
			in: .rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
		)
		.sidebarDropArea(isEnabled: acceptsDrops) { area in
			area
				.dropDestination(for: SidebarTransfer.self) { transfers, _ in
					onAction(.moveItems(SidebarTransfer.orderedIDs(transfers), .savedRoot))
				}
				.onDropSessionUpdated { updateRootTarget($0, target: .savedRoot) }
		}
	}

	private var spaceNameField: some View {
		TextField(String.localized(.appUI.common.name), text: $spaceNameDraft)
			.textFieldStyle(.plain)
			.font(.system(size: BrowserMetrics.Section.headerFontSize, weight: .semibold))
			.foregroundStyle(BrowserTheme.text)
			.focused($spaceNameFocused)
			.onSubmit(commitSpaceRename)
			.onExitCommand(perform: cancelSpaceRename)
			.onChange(of: spaceNameFocused) { _, focused in
				if !focused { commitSpaceRename() }
			}
	}

	@ViewBuilder
	private var heading: some View {
		switch style {
		case .page:
			workspaceHeading
		case let .column(pickingIcon, onPickIcon, profile):
			columnHeading(pickingIcon: pickingIcon, onPickIcon: onPickIcon, profile: profile)
		}
	}

	private var workspaceHeading: some View {
		HStack(spacing: 0) {
			if isRenamingSpace {
				HStack(spacing: BrowserMetrics.Row.iconSpacing) {
					SpaceIconImage(rawValue: spaceSymbol)
						.font(.system(size: 11, weight: .semibold))
						.frame(width: BrowserMetrics.Row.iconSize)
					spaceNameField
				}
			} else {
				Button { onAction(.toggleSpace) } label: {
					HStack(spacing: BrowserMetrics.Row.iconSpacing) {
						SpaceIconImage(rawValue: headingHovered || !isExpanded ? "chevron.right" : spaceSymbol)
							.font(.system(size: 11, weight: .semibold))
							.rotationEffect(.degrees(headingHovered && isExpanded ? 90 : 0))
							.frame(width: BrowserMetrics.Row.iconSize)
						Text(spaceName)
							.font(.system(size: BrowserMetrics.Section.headerFontSize, weight: .semibold))

							// Single clicks on the title wait out the double click; the rest of the heading doesn't.
							.onTapGesture(count: 2, perform: beginSpaceRename)
							.onTapGesture { onAction(.toggleSpace) }
						Spacer(minLength: 0)
					}
					.contentShape(.rect)
				}
				.buttonStyle(.plain)
				.accessibilityAction(named: String.localized(.appUI.common.renameAction), beginSpaceRename)
				.accessibilityLabel(String.localized(.appUI.sidebar.space(spaceName)))
				.accessibilityValue(
					isExpanded
					? String.localized(.appUI.sidebar.expanded)
					: String.localized(.appUI.sidebar.collapsed)
				)
				.accessibilityHint(String.localized(.appUI.sidebar.disclosureHint))
			}
			Menu { spaceActions } label: {
				Image(systemName: "ellipsis")
					.frame(
						width: BrowserMetrics.Section.menuButtonSize,
						height: BrowserMetrics.Section.menuButtonSize
					)
					.background(
						menuHovered ? BrowserTheme.hover : .clear,
						in: ArxControlShape()
					)
					.contentShape(.rect)
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize()
			.onHover { menuHovered = $0 }
			.opacity(sidebarHovered ? 1 : 0)
			.accessibilityLabel(String.localized(.appUI.sidebar.spaceActions))
		}
		.contextMenu { spaceActions }
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.leading, BrowserMetrics.Row.horizontalPadding)
		.padding(.trailing, BrowserMetrics.Row.horizontalPadding - 4)
		.frame(height: BrowserMetrics.Section.headerHeight)
		.background(
			workspaceHeadingBackground,
			in: .rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
		)
		.onHover { headingHovered = $0 }
		.sidebarDropArea(isEnabled: acceptsDrops) { area in
			area
				.dropDestination(for: SidebarTransfer.self) { transfers, _ in
					onAction(.moveItems(SidebarTransfer.orderedIDs(transfers), .savedRoot))
				}
				.onDropSessionUpdated { updateRootTarget($0, target: .savedRoot) }
		}
	}

	private var workspaceHeadingBackground: AnyShapeStyle {
		if rootTarget == .savedRoot { return AnyShapeStyle(BrowserTheme.accent.opacity(0.25)) }
		return AnyShapeStyle(headingHovered && !menuHovered && !isRenamingSpace ? BrowserTheme.hover : .clear)
	}

	private func beginSpaceRename() {
		guard canRenameSpace else { return }
		spaceNameDraft = spaceName
		isRenamingSpace = true
		spaceNameFocused = true
	}

	private func commitSpaceRename() {
		guard isRenamingSpace else { return }
		isRenamingSpace = false
		let name = spaceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
		if !name.isEmpty, name != spaceName { onAction(.renameSpace(name)) }
	}

	private func cancelSpaceRename() {
		isRenamingSpace = false
	}

	@ViewBuilder
	private var spaceActions: some View {
		if let spaceMenu {
			spaceMenu
		} else {
			Button(String.localized(.appUI.sidebar.newFolder)) { onAction(.newFolder(nil)) }
			Button(String.localized(.appUI.sidebar.newTab)) { onAction(.newTab) }
		}
	}

	private var pinnedHint: some View {
		Text(localized: .appUI.sidebar.pinnedEmpty)
			.font(.system(size: BrowserMetrics.Section.headerFontSize))
			.foregroundStyle(BrowserTheme.secondary)
			.lineLimit(1)
			.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
			.frame(
				maxWidth: .infinity,
				minHeight: BrowserMetrics.Section.emptyHintHeight,
				alignment: .leading
			)
			.contentShape(.rect)
			.sidebarDropArea(isEnabled: acceptsDrops) { area in
				area
					.dropDestination(for: SidebarTransfer.self) { transfers, _ in
						onAction(.moveItems(SidebarTransfer.orderedIDs(transfers), .savedRoot))
					}
			}
	}

	private var tabsDivider: some View {
		HStack(spacing: 8) {
			Rectangle()
				.fill(BrowserTheme.divider.opacity(BrowserMetrics.Section.dividerOpacity))
				.frame(height: BrowserMetrics.Section.dividerThickness)
			if canClearTabs, !unpinnedTabs.isEmpty, sidebarHovered {
				Button { onAction(.clearTabs) } label: {
					Label(String.localized(.appUI.sidebar.clear), systemImage: "arrow.down")
						.font(.system(size: BrowserMetrics.Section.actionFontSize, weight: .medium))
				}
				.buttonStyle(.plain)
				.foregroundStyle(BrowserTheme.secondary)
				.help(String.localized(.appUI.sidebar.clearHelp))
			}
		}

		// Clear comes and goes on hover without moving the rows below.
		.frame(height: BrowserMetrics.Section.dividerRowHeight)
		.padding(.horizontal, BrowserMetrics.Row.horizontalPadding)
		.padding(.vertical, BrowserMetrics.Section.dividerSpacing - BrowserMetrics.Row.spacing)
	}

	/// A pending new tab takes over the highlight until the command bar resolves it.
	private var highlightedID: SidebarItem.ID? { isNewTabPending ? nil : selectedID }

	private var highlightedSplitIDs: Set<SidebarItem.ID> { isNewTabPending ? [] : splitIDs }

	private func isHighlighted(_ item: SidebarItem) -> Bool {
		if let split = item.split {
			return split.memberIDs.contains { $0 == highlightedID || highlightedSplitIDs.contains($0) }
		}
		return highlightedID == item.id || highlightedSplitIDs.contains(item.id)
	}

	/// Which edges of a split member touch another member, so adjacent rows read as one group.
	private func joinedEdges(of item: SidebarItem) -> VerticalEdge.Set {
		guard highlightedSplitIDs.contains(item.id) else { return [] }

		let openItems = self.openItems
		guard let index = openItems.firstIndex(where: { $0.id == item.id })
		else { return [] }
		var edges: VerticalEdge.Set = []
		if index > 0, highlightedSplitIDs.contains(openItems[index - 1].id) {
			edges.insert(.top)
		}
		if index < openItems.count - 1, highlightedSplitIDs.contains(openItems[index + 1].id) {
			edges.insert(.bottom)
		}
		return edges
	}

	private var visibleSavedRows: [SidebarTreeRow] {
		if isExpanded { return SidebarTreeRow.flatten(savedItems, revealing: revealedIDs) }
		guard
			let selectedID,
			let item = SidebarTreeRow.find(selectedID, in: savedItems)
		else { return [] }
		return [.init(item: item, depth: 0)]
	}

	private func savedRows(measured: Bool) -> some View {
		ForEach(shownSavedRows) { row in
			shownRow(row, measured: measured)
		}

		// A collapsed space shows only its selected tab, and selecting expands the space, which
		// moves the row before a double-click's second click could land on it.
		.environment(\.sidebarSelectsOnFirstClick, isExpanded && !isColumn)
	}

	/// The rows the saved section draws: those a person sees, and while a folder closes, the rows it
	/// is folding away (DEV-1249).
	private var shownSavedRows: [SidebarTreeRow] {
		guard isExpanded, !folding.isEmpty else { return visibleSavedRows }
		return SidebarTreeRow.flatten(savedItems, revealing: revealedIDs, folding: folding)
	}

	/// Folders that may be closing: those open at the last change, which a change that closes them
	/// finds still listed here, and those folding since.
	private var folding: Set<SidebarItem.ID> {
		guard rowMotion, !reduceMotion else { return [] }
		return openFolderIDs.union(foldingFolderIDs)
	}

	/// A row as the list draws it. A lazy stack lays out only the rows it lists: a row it no
	/// longer lists plays its removal where it last was while the rows below already close up
	/// over it. So a closing folder keeps its rows listed, folding to no height on the same
	/// spring, until `endFolding` drops them (DEV-1249).
	private func shownRow(
		_ row: SidebarTreeRow,
		measured: Bool
	) -> some View {
		measuredRow(row.item, depth: row.depth, isPartlyRevealed: row.isPartlyRevealed, measured: measured && !row.isFolded)

			// The space below it, which folds with it.
			.padding(.bottom, BrowserMetrics.Row.spacing)
			.modifier(SidebarRowReveal(progress: row.isFolded ? 0 : 1))
			.allowsHitTesting(!row.isFolded)

			// Out of keyboard focus and its keys too, which hit testing doesn't cover.
			.disabled(row.isFolded)
			.accessibilityHidden(row.isFolded)
			.transition(.sidebarRow(isEnabled: rowMotion))
	}

	/// Drops a closed folder's folded rows once its spring has settled, at once: they have no
	/// height left to lose.
	private func endFolding() async {
		guard !foldingFolderIDs.isEmpty else { return }
		do {
			try await Task.sleep(for: SidebarRowMotion.foldDuration)
		} catch {
			return
		}
		var transaction = Transaction(animation: nil)
		transaction.disablesAnimations = true
		withTransaction(transaction) {
			foldingFolderIDs = []
		}
	}

	private func measuredRow(
		_ item: SidebarItem,
		depth: Int,
		isPartlyRevealed: Bool,
		measured: Bool
	) -> some View {
		Group {
			if let split = item.split {
				SplitSidebarRow(
					item: item,
					split: split,
					depth: depth,
					selected: isHighlighted(item),
					isDropTarget: isSplitDropTarget(item),
					// The relay has the window's link actions, if it offers any, when the menu opens.
					offersLinks: true,
					actions: rowActions
				)
				.equatable()
			} else {
				SidebarRow(
					item: item,
					depth: depth,
					isPartlyRevealed: isPartlyRevealed,
					selected: isHighlighted(item),
					joinedEdges: joinedEdges(of: item),
					isDropTarget: isSplitDropTarget(item)
					|| dropPlacement?.target == .inside(item.id) && dropPlacement?.lineY == nil,
					showsTooltip: hoverPreviews?.covers(item) != true,
					focus: $focusedRow,
					isFocused: focusedRow == item.id,
					actions: rowActions
				)
				.equatable()
			}
		}

		// Outside the row, which compares as equal while it shakes: a pin in the Pinned section or a
		// folder shakes when it's reset (DEV-1225).
		.sidebarResetShake(resetPulse(of: item))
		.background {
			if measured {
				GeometryReader { geometry in
					let _ = SidebarRenderTrace.rowFrame()
					Color.clear.preference(
						key: SidebarRowFrames.self,
						value: [item.id: geometry.frame(in: .named(dropCoordinateSpace))]
					)
				}
			}
		}
	}

	/// How many times the row's pin was reset, or each of a Split View row's members, since the row
	/// takes its first member's ID (DEV-1225). Every item is listed, at 0 before its first reset,
	/// so a first reset counts as one going up.
	///
	/// Nil for a row nothing can reset, an open tab, which then carries no shake at all.
	private func resetPulse(of item: SidebarItem) -> [SidebarItem.ID: Int]? {
		let members: [SidebarItem] = item.split?.members ?? [item]
		guard item.isFolder || members.contains(where: \.isPinned) else { return nil }

		let ids: [SidebarItem.ID] = item.split?.members.map(\.id) ?? [item.id]
		return Dictionary(ids.map { ($0, resetPulses[$0] ?? 0) }, uniquingKeysWith: { first, _ in first })
	}

	/// The rows the arrow keys move through, in reading order. Split View rows are left out: each
	/// of their members takes focus on its own, and Tab still reaches them.
	private var keyboardRows: [SidebarTreeRow] {
		(visibleSavedRows + openRows)
			.filter { $0.item.split == nil }
	}

	/// The open tabs' rows, with an expanded tab group's tabs under it (DEV-911).
	private var openRows: [SidebarTreeRow] { SidebarTreeRow.flatten(unpinnedTabs, revealing: revealedIDs) }

	/// The rows a collapsed folder or tab group still shows beneath it (DEV-1110).
	private var revealedIDs: Set<SidebarItem.ID> {
		selectionRevealedIDs.union(lingeringRevealedIDs)
	}

	/// The selected tab and the rest of its split.
	private var selectionRevealedIDs: Set<SidebarItem.ID> {
		guard SidebarFolderReveal.isEnabled, let selectedID else { return [] }
		return splitIDs.union([selectedID])
	}

	private func endLingeringReveal() async {
		guard !lingeringRevealedIDs.isEmpty else { return }
		do {
			try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
		} catch {
			return
		}
		withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
			lingeringRevealedIDs = []
		}
	}

	private var openItems: [SidebarItem] { openRows.map(\.item) }

	/// Every row on screen, Pinned's and folders' then the open tabs', for `SidebarRowMotion`.
	private var shownRows: SidebarRowMotion.Rows {
		.init(
			sections: [visibleSavedRows, openRows].map { rows in rows.map { .init(id: $0.id, depth: $0.depth) } },
			isExpanded: isExpanded
		)
	}

	/// Every row a split can be dropped on: Pinned's, folders' and the open tabs' (DEV-1006).
	private var splitRows: [SidebarItem] { visibleSavedRows.map(\.item) + openItems }

	private func arrowPressed(
		_ press: KeyPress,
		proxy: ScrollViewProxy
	) -> KeyPress.Result {
		// ⌘, ⌥ and ⌃ arrows belong to menu commands; a renaming row's field keeps its arrows.
		guard
			press.modifiers.isDisjoint(with: [.command, .option, .control]),
			let focusedRow
		else { return .ignored }

		let key: SidebarKeyboardNavigation.Key
		switch press.key {
		case .upArrow: key = .up
		case .downArrow: key = .down
		case .leftArrow: key = .left
		case .rightArrow: key = .right
		default: return .ignored
		}

		switch SidebarKeyboardNavigation.outcome(of: key, from: focusedRow, in: keyboardRows) {
		case let .focus(id):
			// The rows are lazy, so a row far off screen, such as a folder's parent, may not exist
			// yet to take focus. Scrolling to it first builds it.
			withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
				proxy.scrollTo(id)
			}
			self.focusedRow = id
		case let .toggle(id):
			withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
				onAction(.toggle(id))
			}
		case nil:
			break
		}

		// Handled even at either end, so the list doesn't scroll away from the focused row.
		return .handled
	}

	/// A split forms only where it would still fit; a full one never lights up.
	private func isSplitDropTarget(_ item: SidebarItem) -> Bool {
		guard let dropPlacement, dropPlacement.target == .split(item.id)
		else { return false }
		return !dropPlacement.exceedsSplit(limits: splitPaneLimits, in: splitRows)
	}

	private var dropLayout: SidebarDropLayout {
		.init(
			savedRows: visibleSavedRows,
			regularTabs: openItems,
			frames: rowFrames,
			newTabFrame: newTabFrame
		)
	}

	private var insertionIndicator: some View {
		GeometryReader { geometry in
			if let placement = dropPlacement, let y = placement.lineY {
				// A line: a ring at the leading end, then a rule to the row's trailing edge.
				let leading = 12 + CGFloat(placement.depth) * 17
				let ring: CGFloat = 7
				HStack(spacing: 0) {
					Circle()
						.strokeBorder(BrowserTheme.accent, lineWidth: 1.5)
						.frame(width: ring, height: ring)
					Capsule(style: .continuous)
						.fill(BrowserTheme.accent)
						.frame(height: 2)
				}
				.frame(width: max(0, geometry.size.width - leading - BrowserMetrics.Sidebar.horizontalPadding))
				.offset(x: leading, y: y - ring / 2)
			}
		}
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}

	private func rowsDropUpdated(_ session: DropSession) {
		switch session.phase {
		case .entering, .active:
			dropSession.location = session.location
			if !isDropTargeted { isDropTargeted = true }
			let placement = dropLayout.placement(at: session.location)

			// One tick each time the dragged rows would land somewhere new.
			if reorderHapticsEnabled, let placement, placement.target != dropPlacement?.target {
				NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
			}
			dropPlacement = placement
			dragEdge = SidebarDragEdge(x: session.location.x, width: listWidth)
			dragPreview?.update(
				owner: dropOwner,
				location: CGPoint(x: listFrame.minX + session.location.x, y: listFrame.minY + session.location.y),
				shape: .row(width: max(0, listWidth - 2 * BrowserMetrics.Sidebar.horizontalPadding))
			)

		default:
			dropSession.location = nil

			// A drop still needs the frames: `rowsDropped` places it after these phases.
			let dropFollows: Bool = switch session.phase {
			case .dataTransferCompleted: true
			case let .ended(operation): operation != .cancel && operation != .forbidden
			default: false
			}
			if !dropFollows, isDropTargeted { isDropTargeted = false }
			dropPlacement = nil
			dragEdge = nil
			dragPreview?.leave(owner: dropOwner)
		}
	}

	private func rowsDropped(
		_ transfers: [SidebarTransfer],
		session: DropSession
	) {
		let placement = dropLayout.placement(at: session.location)
		dropSession.location = nil
		isDropTargeted = false
		dropPlacement = nil
		dragEdge = nil
		dragPreview?.drop(settlingInto: nil, reduceMotion: reduceMotion)
		guard
			let placement,
			!placement.exceedsSplit(limits: splitPaneLimits, in: splitRows)
		else { return }
		withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
			onAction(.moveItems(SidebarTransfer.orderedIDs(transfers), placement.target))
		}
	}

	private var targetedFolderID: SidebarItem.ID? {
		guard
			let dropPlacement,
			dropPlacement.lineY == nil,
			case let .inside(id) = dropPlacement.target
		else { return nil }
		return id
	}

	private func pageToHoveredEdge() async {
		guard let edge = dragEdge else { return }
		do {
			try await Task.sleep(for: interaction.spaceHoverDelay)
		} catch {
			return
		}
		guard !Task.isCancelled, dragEdge == edge else { return }
		onDragAtEdge(edge)
	}

	private func expandHoveredFolder() async {
		guard
			let id = targetedFolderID,
			let folder = SidebarTreeRow.find(id, in: savedItems),
			!folder.isExpanded
		else { return }
		do {
			try await Task.sleep(for: interaction.folderHoverDelay)
		} catch {
			return
		}
		guard !Task.isCancelled, targetedFolderID == id else { return }
		onAction(.toggle(id))
	}

	private func updateRootTarget(
		_ session: DropSession,
		target: SidebarDropTarget
	) {
		switch session.phase {
		case .entering, .active: rootTarget = target
		default: rootTarget = nil
		}
	}
}

private struct SidebarNewTabStyle: ButtonStyle {
	private let isPending: Bool

	@SwiftUI.State
	private var hovered: Bool

	internal init(isPending: Bool) {
		self.isPending = isPending
		self._hovered = .init(initialValue: false)
	}

	internal func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(
				background(isPressed: configuration.isPressed),
				in: .rect(cornerRadius: BrowserMetrics.Row.cornerRadius, style: .continuous)
			)
			.onHover { hovered = $0 }
	}

	private func background(isPressed: Bool) -> Color {
		if isPending { return BrowserTheme.selection }
		return hovered || isPressed ? BrowserTheme.rowHover : .clear
	}
}

/// Aligns a symbol and title with tab rows' icon column.
private struct SidebarRowLabelStyle: LabelStyle {
	internal func makeBody(configuration: Configuration) -> some View {
		HStack(spacing: BrowserMetrics.Row.iconSpacing) {
			configuration.icon
				.font(.system(size: BrowserMetrics.Row.iconSize - 4, weight: .medium))
				.frame(width: BrowserMetrics.Row.iconSize, height: BrowserMetrics.Row.iconSize)
			configuration.title
		}
	}
}

/// Where a drop session over the rows last was. Rows measured after it arrived place it again.
@MainActor
private final class SidebarDropSession {
	fileprivate var location: CGPoint?

	fileprivate init() {
		self.location = nil
	}
}

/// The sidebar's progressive edges under its header and over its footer (DEV-826).
internal enum SidebarScrollEdgeMetrics {
	/// How far they ease out, ending ``overhang`` past the header or the footer.
	internal static let ramp: CGFloat = 32

	/// How far past the header or footer they reach, so its last row stays over full strength.
	internal static let overhang: CGFloat = 16
}

/// How far a sidebar's rows have scrolled under its header and its footer, from 0 at rest to 1.
/// Only the views that draw the edges read it, so a scroll re-renders them alone.
@MainActor
@Observable
internal final class SidebarScrollEdges {
	internal var header: CGFloat
	internal var footer: CGFloat

	internal init() {
		self.header = 0
		self.footer = 0
	}
}

/// Whether a sidebar's rows are being scrolled by fingers or their momentum.
///
/// The pointer stays where it is while the rows pass under it, so every frame of a scroll
/// AppKit hit-tested all the rows for the scroll event and SwiftUI worked out again which row
/// the pointer was over, entering and leaving one after another: about a quarter of the main
/// thread in a recording of the list scrolling (DEV-1310). While this says so the rows take no
/// hit-testing; the scroll view under them still takes the scroll.
@MainActor
@Observable
internal final class SidebarScrollLatch {
	internal private(set) var isScrolling: Bool

	internal init() {
		self.isScrolling = false
	}

	/// Only fingers and their momentum hold the rows: a scroll made for the keyboard or to
	/// reveal a row leaves them to the pointer.
	internal static func holdsRows(during phase: ScrollPhase) -> Bool {
		switch phase {
		case .tracking, .interacting, .decelerating: true
		case .idle, .animating: false
		@unknown default: false
		}
	}

	internal func phaseChanged(_ phase: ScrollPhase) {
		let isScrolling: Bool = Self.holdsRows(during: phase)
		if self.isScrolling != isScrolling { self.isScrolling = isScrolling }
	}
}

/// Takes the rows out of hit-testing while they scroll. A view of its own, so the change runs
/// no sidebar body.
private struct SidebarScrollLatched: ViewModifier {
	private let latch: SidebarScrollLatch

	fileprivate init(latch: SidebarScrollLatch) {
		self.latch = latch
	}

	fileprivate func body(content: Content) -> some View {
		content.allowsHitTesting(!latch.isScrolling)
	}
}

/// The progressive edge under a sidebar's header, as strong as its rows have scrolled under it.
private struct SidebarHeaderEdge: View {
	private let edges: SidebarScrollEdges
	private let isColumn: Bool

	fileprivate init(
		edges: SidebarScrollEdges,
		isColumn: Bool
	) {
		self.edges = edges
		self.isColumn = isColumn
	}

	fileprivate var body: some View {
		ArxProgressiveEdge(
			veil: .chrome,
			ramp: SidebarScrollEdgeMetrics.ramp,
			style: isColumn ? .standard : .sidebar
		)
		.padding(.bottom, -SidebarScrollEdgeMetrics.overhang)
		.opacity(edges.header)
	}
}

/// Reports how far a sidebar's rows have scrolled under the footer to the pager, which draws
/// that edge.
private struct SidebarFooterOverlapReport: View {
	private let edges: SidebarScrollEdges

	fileprivate init(edges: SidebarScrollEdges) {
		self.edges = edges
	}

	fileprivate var body: some View {
		Color.clear
			.allowsHitTesting(false)
			.accessibilityHidden(true)
			.preference(key: SidebarFooterOverlapKey.self, value: edges.footer)
	}
}

/// Shares the active space's scroll treatment with the pager's footer.
internal struct SidebarFooterOverlapKey: PreferenceKey {
	internal static let defaultValue: CGFloat = 0

	internal static func reduce(
		value: inout CGFloat,
		nextValue: () -> CGFloat
	) {
		value = max(value, nextValue())
	}
}
