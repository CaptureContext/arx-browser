import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// What a hover preview shows about one tab. The feature reads it from live state when the card opens.
public struct SidebarTabPreview: Equatable, Sendable {
	public var title: String
	public var url: URL
	public var lastUsed: Date?

	/// Whether the tab has a live page, so a picture of it can be taken.
	public var isLoaded: Bool

	public init(
		title: String,
		url: URL,
		lastUsed: Date? = nil,
		isLoaded: Bool = false
	) {
		self.title = title
		self.url = url
		self.lastUsed = lastUsed
		self.isLoaded = isLoaded
	}

	/// The site shown under the title: the host, or the whole address when there is none.
	public var site: String {
		guard let host = url.host(), !host.isEmpty else { return url.absoluteString }
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}
}

/// Supplies hover previews for sidebar tabs and folders. Without one, rows keep their plain tooltips.
public struct SidebarHoverPreviews: Sendable {
	public var tabs: @MainActor @Sendable ([UUID]) -> [UUID: SidebarTabPreview]

	/// A picture of the page: a live one when it's loaded, otherwise a saved one, the site's own
	/// or one taken off screen (DEV-730); nil when there's none.
	public var thumbnail: @MainActor @Sendable (UUID) async -> CGImage?

	/// Shift + hover loads the page instantly (DEV-1029): a fresh picture of a page that isn't
	/// loaded, loaded now for a card Shift opened; nil when it can't be had, and the card falls
	/// back to `thumbnail`. Nil while the setting is off.
	public var livePage: (@MainActor @Sendable (UUID) async -> CGImage?)?

	/// What the site says about a page that isn't loaded (DEV-730), or nil.
	public var summary: @MainActor @Sendable (UUID) async -> String?

	/// Whether folders list their tabs. Without it, folders keep their plain tooltips.
	public var showsFolders: Bool

	/// What a favorite's card adds for its site (unread mail, recent pages), or nil for nothing.
	public var site: @MainActor @Sendable (UUID) async -> SidebarSitePreview?

	/// Live Calendar (DEV-804): a calendar favorite's day, shown instead of its card; nil for
	/// every other tab.
	public var calendar: @MainActor @Sendable (UUID) -> SidebarLiveCalendar?

	public init(
		tabs: @escaping @MainActor @Sendable ([UUID]) -> [UUID: SidebarTabPreview],
		thumbnail: @escaping @MainActor @Sendable (UUID) async -> CGImage? = { _ in nil },
		livePage: (@MainActor @Sendable (UUID) async -> CGImage?)? = nil,
		summary: @escaping @MainActor @Sendable (UUID) async -> String? = { _ in nil },
		showsFolders: Bool = true,
		site: @escaping @MainActor @Sendable (UUID) async -> SidebarSitePreview? = { _ in nil },
		calendar: @escaping @MainActor @Sendable (UUID) -> SidebarLiveCalendar? = { _ in nil }
	) {
		self.tabs = tabs
		self.thumbnail = thumbnail
		self.livePage = livePage
		self.summary = summary
		self.showsFolders = showsFolders
		self.site = site
		self.calendar = calendar
	}

	/// Whether this item opens a preview rather than its plain tooltip.
	public func covers(_ item: SidebarItem) -> Bool {
		item.isFolder ? showsFolders : true
	}
}

private enum SidebarHoverPreviewsKey: EnvironmentKey {
	internal static var defaultValue: SidebarHoverPreviews? { nil }
}

extension EnvironmentValues {
	public var sidebarHoverPreviews: SidebarHoverPreviews? {
		get { self[SidebarHoverPreviewsKey.self] }
		set { self[SidebarHoverPreviewsKey.self] = newValue }
	}
}

// MARK: - Folder contents

/// Every tab inside a folder, at any depth, grouped by the folders that hold it.
public struct SidebarFolderPreview: Equatable, Sendable {
	public struct Entry: Identifiable, Equatable, Sendable {
		public let id: UUID
		public var title: String
		public var siteIcon: SidebarItem.SiteIcon?
		public var symbol: String
		public var tint: SidebarTint

		/// Folder names below the hovered folder; empty for its direct children.
		public var path: [String]

		/// The folders those names belong to, so same-named folders stay apart.
		public var folderIDs: [UUID]
		public var preview: SidebarTabPreview?

		/// A Split View's panes in this folder, when the row stands for one (DEV-1275).
		public var splitPanes: Int?

		/// The panes' own titles, which the search matches too.
		public var paneTitles: [String]

		public init(
			id: UUID,
			title: String,
			siteIcon: SidebarItem.SiteIcon? = nil,
			symbol: String = "globe",
			tint: SidebarTint = .white,
			path: [String] = [],
			folderIDs: [UUID] = [],
			preview: SidebarTabPreview? = nil,
			splitPanes: Int? = nil,
			paneTitles: [String] = []
		) {
			self.id = id
			self.title = title
			self.siteIcon = siteIcon
			self.symbol = symbol
			self.tint = tint
			self.path = path
			self.folderIDs = folderIDs
			self.preview = preview
			self.splitPanes = splitPanes
			self.paneTitles = paneTitles
		}
	}

	public struct Group: Identifiable, Equatable, Sendable {
		public var path: [String]
		public var folderIDs: [UUID]
		public var entries: [Entry]

		public init(
			path: [String],
			folderIDs: [UUID],
			entries: [Entry]
		) {
			self.path = path
			self.folderIDs = folderIDs
			self.entries = entries
		}

		public var id: [UUID] { folderIDs }
	}

	public var entries: [Entry]

	public init(entries: [Entry]) {
		self.entries = entries
	}

	public init(
		folder: SidebarItem,
		tabs: [UUID: SidebarTabPreview]
	) {
		self.entries = Self.collect(folder.children, path: [], folderIDs: [], tabs: tabs)
	}

	/// The tab IDs a folder holds at any depth, in sidebar order.
	public static func tabIDs(in folder: SidebarItem) -> [UUID] {
		folder.children.flatMap { child -> [UUID] in
			switch child.id {
			case let .tab(id): [id]
			case .folder: tabIDs(in: child)
			}
		}
	}

	/// Groups keep the sidebar's order: a folder's own tabs first, then each subfolder where it first appears.
	public func groups(matching query: String = "") -> [Group] {
		let terms = query
			.split(whereSeparator: \.isWhitespace)
			.map(String.init)

		var groups: [Group] = []
		for entry in entries where Self.matches(entry, terms: terms) {
			if let index = groups.firstIndex(where: { $0.folderIDs == entry.folderIDs }) {
				groups[index].entries.append(entry)
			} else {
				groups.append(.init(path: entry.path, folderIDs: entry.folderIDs, entries: [entry]))
			}
		}
		return groups.filter(\.folderIDs.isEmpty) + groups.filter { !$0.folderIDs.isEmpty }
	}

	/// The matching tabs in the order the list shows them, for the keyboard's selection.
	public func resultIDs(matching query: String = "") -> [UUID] {
		groups(matching: query).flatMap { $0.entries.map(\.id) }
	}

	private static func collect(
		_ items: [SidebarItem],
		path: [String],
		folderIDs: [UUID],
		tabs: [UUID: SidebarTabPreview]
	) -> [Entry] {
		items.flatMap { item -> [Entry] in
			switch item.id {
			case let .tab(id):
				// A Split View's row names its panes, rather than only its first tab (DEV-1275).
				if let split = item.split, split.members.count > 1 {
					let titles = split.members.map(\.title)
					return [
						.init(
							id: id,
							title: split.title ?? titles.joined(separator: " | "),
							symbol: split.isVertical ? "rectangle.split.1x2" : "rectangle.split.2x1",
							tint: item.tint,
							path: path,
							folderIDs: folderIDs,
							preview: tabs[id],
							splitPanes: split.members.count,
							paneTitles: titles
						)
					]
				}
				return [
					.init(
						id: id,
						title: item.title,
						siteIcon: item.siteIcon,
						symbol: item.symbol,
						tint: item.tint,
						path: path,
						folderIDs: folderIDs,
						preview: tabs[id]
					)
				]

			case let .folder(folderID):
				return collect(
					item.children,
					path: path + [item.title],
					folderIDs: folderIDs + [folderID],
					tabs: tabs
				)
			}
		}
	}

	private static func matches(
		_ entry: Entry,
		terms: [String]
	) -> Bool {
		guard !terms.isEmpty else { return true }
		let fields = [entry.title, entry.preview?.title, entry.preview?.url.absoluteString]
			.compactMap(\.self) + entry.path + entry.paneTitles

		return terms.allSatisfy { term in
			fields.contains { $0.localizedStandardContains(term) }
		}
	}
}

// MARK: - Presentation

/// Whether any hover preview in the sidebar is open, so a floating sidebar stays revealed under it.
internal struct SidebarHoverPreviewOpen: PreferenceKey {
	internal static let defaultValue: Bool = false

	internal static func reduce(
		value: inout Bool,
		nextValue: () -> Bool
	) {
		value = value || nextValue()
	}
}

extension View {
	/// Opens a tab's preview card or a folder's contents after the pointer rests on the item.
	public func sidebarHoverPreview(
		item: SidebarItem,
		selected: Bool,
		isSuspended: Bool = false,
		onAction: @escaping (SidebarAction) -> Void
	) -> some View {
		modifier(SidebarHoverPreviewModifier(
			item: item,
			selected: selected,
			isSuspended: isSuspended,
			onAction: onAction
		))
	}
}

/// How long the pointer rests on an item before its preview opens: at once with Shift down
/// (DEV-1029, while `shiftOpensPreviews`) or right after another preview closed, otherwise the
/// sidebar's hover delay.
internal enum SidebarHoverPreviewDelay {
	internal static func delay(
		isShiftDown: Bool,
		isWarm: Bool,
		interaction: SidebarInteractionConfiguration
	) -> Duration {
		(isShiftDown && interaction.shiftOpensPreviews) || isWarm ? .zero : interaction.hoverPreviewDelay
	}

	/// Whether a preview opened this way has settled (DEV-1288): Shift opened it, or the pointer
	/// rested for the whole delay. One opened at once only because another just closed hasn't,
	/// so it doesn't replace a preview that's held.
	internal static func isSettled(
		isShiftDown: Bool,
		isWarm: Bool,
		interaction: SidebarInteractionConfiguration
	) -> Bool {
		(isShiftDown && interaction.shiftOpensPreviews) || !isWarm
	}
}

/// Watches Shift while the pointer is on an item, so pressing it there opens the preview at once
/// (DEV-1029). It runs only while an item is hovered.
@MainActor
internal final class SidebarShiftKeyMonitor {
	private var monitor: Any?

	internal init(_ changed: @escaping @MainActor (Bool) -> Void) {
		self.monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
			let isShiftDown: Bool = event.modifierFlags.contains(.shift)
			MainActor.assumeIsolated { changed(isShiftDown) }
			return event
		}
	}

	/// Whether Shift is down now, wherever the keyboard is.
	internal static var isShiftDown: Bool {
		NSEvent.modifierFlags.contains(.shift)
	}

	internal func stop() {
		if let monitor { NSEvent.removeMonitor(monitor) }
		monitor = nil
	}
}

/// After one preview closes, the next item's opens at once, like tooltips.
@MainActor
private enum SidebarHoverPreviewWarmth {
	internal static var coolsAt: ContinuousClock.Instant = .now

	internal static var isWarm: Bool { ContinuousClock.now < coolsAt }

	internal static func warm() {
		coolsAt = .now.advanced(by: .milliseconds(600))
	}
}

/// Watches the pointer over an item and, while it's there or the item's preview is open, mounts
/// the preview's session behind it. An item nobody points at carries only this: the session's
/// state, panel anchor and observers were built with every row, which made each row scrolled
/// into view dearer to build (DEV-1235).
private struct SidebarHoverPreviewModifier: ViewModifier {
	private let item: SidebarItem
	private let selected: Bool
	private let isSuspended: Bool
	private let onAction: (SidebarAction) -> Void

	@Environment(\.sidebarHoverPreviews)
	private var previews

	@SwiftUI.State
	private var itemHovered: Bool

	/// The preview is open, which keeps its session after the pointer leaves the item for it.
	@SwiftUI.State
	private var isOpen: Bool

	fileprivate init(
		item: SidebarItem,
		selected: Bool,
		isSuspended: Bool,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.item = item
		self.selected = selected
		self.isSuspended = isSuspended
		self.onAction = onAction
		self._itemHovered = .init(initialValue: false)
		self._isOpen = .init(initialValue: false)
	}

	@ViewBuilder
	fileprivate func body(content: Content) -> some View {
		if let previews, previews.covers(item) {
			content
				.onHover { itemHovered = $0 }
				.background {
					if itemHovered || isOpen {
						SidebarHoverPreviewSession(
							item: item,
							selected: selected,
							isSuspended: isSuspended,
							isItemHovered: itemHovered,
							previews: previews,
							isOpen: $isOpen,
							onAction: onAction
						)
					}
				}
		} else {
			content
		}
	}
}

/// One item's hover preview, from the pointer arriving on the item until it has left and the
/// preview has closed. It fills the item's frame, which its panel opens beside.
private struct SidebarHoverPreviewSession: View {
	private let item: SidebarItem
	private let selected: Bool
	private let isSuspended: Bool
	private let isItemHovered: Bool
	private let previews: SidebarHoverPreviews
	private let isOpen: Binding<Bool>
	private let onAction: (SidebarAction) -> Void

	@Environment(\.sidebarInteraction)
	private var interaction

	@SwiftUI.State
	private var isPresented: Bool

	/// `isItemHovered` as the session last heard it, for what runs after a delay.
	@SwiftUI.State
	private var itemHovered: Bool

	@SwiftUI.State
	private var previewHovered: Bool

	@SwiftUI.State
	private var pending: Task<Void, Never>?

	@SwiftUI.State
	private var search: SidebarFolderSearch

	/// Shift opened the preview or was pressed while it showed (DEV-1029): a tab's card loads its
	/// page now when the setting allows.
	@SwiftUI.State
	private var isShiftOpened: Bool

	@SwiftUI.State
	private var shiftMonitor: SidebarShiftKeyMonitor?

	/// The preview opens after the pointer rested on the item for the whole hover delay, or with
	/// Shift, rather than at once after another preview closed (DEV-1288).
	@SwiftUI.State
	private var isSettled: Bool

	/// The window's preview owner turned this preview away, or another replaced it: closing it
	/// isn't a close the next preview opens at once after (DEV-1288).
	@SwiftUI.State
	private var isTurnedAway: Bool

	fileprivate init(
		item: SidebarItem,
		selected: Bool,
		isSuspended: Bool,
		isItemHovered: Bool,
		previews: SidebarHoverPreviews,
		isOpen: Binding<Bool>,
		onAction: @escaping (SidebarAction) -> Void
	) {
		self.item = item
		self.selected = selected
		self.isSuspended = isSuspended
		self.isItemHovered = isItemHovered
		self.previews = previews
		self.isOpen = isOpen
		self.onAction = onAction
		self._isPresented = .init(initialValue: false)
		self._itemHovered = .init(initialValue: false)
		self._previewHovered = .init(initialValue: false)
		self._pending = .init(initialValue: nil)
		self._search = .init(initialValue: .init())
		self._isShiftOpened = .init(initialValue: false)
		self._shiftMonitor = .init(initialValue: nil)
		self._isSettled = .init(initialValue: true)
		self._isTurnedAway = .init(initialValue: false)
	}

	fileprivate var body: some View {
		Color.clear
			.allowsHitTesting(false)
			.accessibilityHidden(true)

			// A panel beside the row rather than a popover, which always draws an arrow.
			.sidebarHoverPanel(
				isPresented: $isPresented,
				acceptsKeyboard: holdsPointer,
				keyboard: isInteractive ? keyboard(previews) : (holdsPointer ? calendarKeyboard : nil),
				// A Live Calendar keeps its card; other previews float as raised glass (DEV-1275).
				drawsCard: isCalendar,
				margin: isCalendar ? 0 : SidebarPreviewGlassMetrics.shadowMargin,
				exclusivity: .init(
					isSettled: isSettled,
					isHeld: search.isEngaged || previewHovered,
					refused: turnedAway
				)
			) {
				preview(previews)
					.onHover(perform: previewHoverChanged)
			}
			.onChange(of: isItemHovered, initial: true) { _, hovering in itemHoverChanged(hovering) }
			.onChange(of: isPresented) { _, presented in

				// Last, since closing lets go of the session once the pointer has left the item.
				defer { isOpen.wrappedValue = presented }
				guard !presented else { return }
				if isTurnedAway {
					isTurnedAway = false
				} else {
					SidebarHoverPreviewWarmth.warm()
				}
				search = .init()
			}
			.onChange(of: isSuspended) { _, suspended in

				// Shift is watched only while the item isn't suspended, such as while it's
				// being renamed and Shift types a capital letter.
				if suspended {
					dismiss()
					stopWatchingShift()
				} else if itemHovered {
					startWatchingShift()
				}
			}
			.onChange(of: selected) { dismiss() }
			.onChange(of: item.isExpanded) { dismiss() }
			.onDisappear {
				pending?.cancel()
				stopWatchingShift()
			}
			.preference(key: SidebarHoverPreviewOpen.self, value: isPresented)
	}

	@ViewBuilder
	private func preview(_ previews: SidebarHoverPreviews) -> some View {
		switch item.id {
		case let .tab(id):
			if let calendar = previews.calendar(id) {
				SidebarCalendarCard(calendar: calendar)
			} else {
				SidebarTabPreviewCard(
					id: id,
					fallbackTitle: item.title,
					siteIcon: item.siteIcon,
					symbol: item.symbol,
					tint: item.tint,
					previews: previews,
					loadsLivePage: isShiftOpened
				)
			}

		case .folder:
			SidebarFolderPreviewList(
				folder: item,
				previews: previews,
				search: search,
				send: send,
				close: dismiss
			)
		}
	}

	/// Tab takes the keyboard into a folder's search; ↑, ↓, Return and Escape then drive it (DEV-836).
	private func keyboard(_ previews: SidebarHoverPreviews) -> SidebarHoverPanelKeyboard {
		.init(
			key: { key in
				let results = SidebarFolderPreview(
					folder: item,
					tabs: previews.tabs(SidebarFolderPreview.tabIDs(in: item))
				).resultIDs(matching: search.query)
				switch key {
				case .tab:
					return true
				case .up:
					send(.moved(.up, results: results))
				case .down:
					send(.moved(.down, results: results))
				case .return:
					send(.submitted(results: results))
				case .escape:
					send(.escape)
				}
				return true
			},
			keyStatusChanged: { isKey in
				send(isKey ? .focused : .clickedElsewhere)
			}
		)
	}

	private func send(_ action: SidebarFolderSearch.Action) {
		switch search.reduce(action) {
		case .none:
			break

		case let .open(id):
			dismiss()
			onAction(.select(.tab(id)))

		case .dismiss:
			dismiss()
		}
	}

	private var isInteractive: Bool { item.isFolder }

	private var isCalendar: Bool {
		guard case let .tab(id) = item.id else { return false }
		return previews.calendar(id) != nil
	}

	/// A Live Calendar card (DEV-804) takes the keyboard on Tab or a click, so its buttons can be
	/// reached; Escape closes it, and so does a click elsewhere unless the pointer is on it.
	private var calendarKeyboard: SidebarHoverPanelKeyboard {
		.init(
			key: { key in
				switch key {
				case .tab:
					return true
				case .escape:
					dismiss()
					return true
				case .up, .down, .return:
					return false
				}
			},
			keyStatusChanged: { isKey in
				if !isKey, !itemHovered, !previewHovered { dismiss() }
			}
		)
	}

	/// Folders and Live Calendar cards (DEV-804) have controls, so they wait briefly for the
	/// pointer to cross into them and take the keyboard when clicked; other tabs' cards close at once.
	private var holdsPointer: Bool {
		if item.isFolder { return true }
		guard case let .tab(id) = item.id else { return false }
		return previews.calendar(id) != nil
	}

	private func itemHoverChanged(_ hovering: Bool) {
		itemHovered = hovering
		pending?.cancel()
		if hovering {
			startWatchingShift()
			guard !isPresented, !isSuspended else { return }
			let isShiftDown: Bool = SidebarShiftKeyMonitor.isShiftDown
			let isWarm: Bool = SidebarHoverPreviewWarmth.isWarm
			let delay: Duration = SidebarHoverPreviewDelay.delay(
				isShiftDown: isShiftDown,
				isWarm: isWarm,
				interaction: interaction
			)
			pending = Task { @MainActor in
				try? await Task.sleep(for: delay)
				guard !Task.isCancelled, itemHovered, !isSuspended else { return }
				isShiftOpened = interaction.shiftOpensPreviews
					&& (isShiftDown || SidebarShiftKeyMonitor.isShiftDown)
				isSettled = SidebarHoverPreviewDelay.isSettled(
					isShiftDown: isShiftOpened,
					isWarm: isWarm,
					interaction: interaction
				)
				isPresented = true
			}
		} else {
			stopWatchingShift()
			scheduleDismissal()
		}
	}

	/// Shift pressed while the pointer rests on the item opens its preview at once, or has an open
	/// card load its page now (DEV-1029).
	private func shiftChanged(_ isDown: Bool) {
		guard isDown, itemHovered, !isSuspended else { return }
		isShiftOpened = true
		guard !isPresented else { return }
		pending?.cancel()
		pending = nil
		isSettled = true
		isPresented = true
	}

	/// The window's owner left the preview closed, because the one it shows is held, or another
	/// preview replaced it. A preview a passing pointer opened at once tries again once the
	/// pointer has rested on the item for the whole hover delay, when it replaces even a held one.
	private func turnedAway() {
		isTurnedAway = true
		pending?.cancel()
		pending = nil
		guard itemHovered, !isSettled, !isSuspended else { return }

		pending = Task { @MainActor in
			try? await Task.sleep(for: interaction.hoverPreviewDelay)
			guard !Task.isCancelled, itemHovered, !isSuspended else { return }
			isSettled = true
			isPresented = true
		}
	}

	private func startWatchingShift() {
		guard interaction.shiftOpensPreviews, shiftMonitor == nil, !isSuspended else { return }
		shiftMonitor = .init { isDown in shiftChanged(isDown) }
	}

	private func stopWatchingShift() {
		shiftMonitor?.stop()
		shiftMonitor = nil
	}

	private func previewHoverChanged(_ hovering: Bool) {
		previewHovered = hovering
		if hovering {
			pending?.cancel()
		} else {
			scheduleDismissal()
		}
	}

	/// A folder's list and a Live Calendar card wait briefly, so the pointer can cross the gap into
	/// them; any other tab's card closes at once. A folder whose search the user has engaged stays
	/// until they open a tab, click elsewhere or press Escape.
	private func scheduleDismissal() {
		guard isPresented else { return }
		guard holdsPointer else { return dismiss() }
		guard !search.isEngaged else { return }
		pending?.cancel()
		pending = Task { @MainActor in
			try? await Task.sleep(for: interaction.hoverPreviewDismissDelay)
			guard !Task.isCancelled, !itemHovered, !previewHovered else { return }
			send(.pointerLeft)
		}
	}

	private func dismiss() {
		pending?.cancel()
		pending = nil
		if isPresented { isPresented = false }
		isShiftOpened = false
		search = .init()
	}
}

// MARK: - Tab card

internal struct SidebarTabPreviewCard: View {
	private let id: UUID
	private let fallbackTitle: String
	private let siteIcon: SidebarItem.SiteIcon?
	private let symbol: String
	private let tint: SidebarTint
	private let previews: SidebarHoverPreviews

	/// Shift opened the card (DEV-1029): a page that isn't loaded loads now, when the setting
	/// gives `livePage`.
	private let loadsLivePage: Bool

	@SwiftUI.State
	private var thumbnail: CGImage?

	@SwiftUI.State
	private var isCapturing: Bool

	@SwiftUI.State
	private var site: SidebarSitePreview?

	@SwiftUI.State
	private var summary: String?

	internal init(
		id: UUID,
		fallbackTitle: String,
		siteIcon: SidebarItem.SiteIcon?,
		symbol: String,
		tint: SidebarTint,
		previews: SidebarHoverPreviews,
		loadsLivePage: Bool = false
	) {
		self.id = id
		self.fallbackTitle = fallbackTitle
		self.siteIcon = siteIcon
		self.symbol = symbol
		self.tint = tint
		self.previews = previews
		self.loadsLivePage = loadsLivePage
		self._thumbnail = .init(initialValue: nil)
		self._isCapturing = .init(initialValue: false)
		self._site = .init(initialValue: nil)
		self._summary = .init(initialValue: nil)
	}

	internal var body: some View {
		let preview = previews.tabs([id])[id]
		VStack(alignment: .leading, spacing: SidebarPreviewGlassMetrics.spacing) {
			if thumbnail != nil || isCapturing {
				picture
					.frame(width: Self.imageWidth, height: Self.imageHeight, alignment: .top)
					.clipShape(.rect(cornerRadius: Self.imageRadius, style: .continuous))
					.padding(SidebarPreviewGlassMetrics.tileInset)
					.sidebarPreviewGlass()
					.accessibilityHidden(true)
			}
			HStack(alignment: .top, spacing: 10) {
				FavoriteSiteIcon(
					key: siteIcon,
					fallback: symbol,
					tint: tint,
					size: 16,
					fallbackSize: 13,
					fallbackWeight: .medium
				)
				.frame(width: 16, height: 16)
				.padding(.top, 1)
				VStack(alignment: .leading, spacing: 2) {
					Text(preview?.title ?? fallbackTitle)
						.font(.system(size: 13, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(0.85))
						.lineLimit(2)
						.fixedSize(horizontal: false, vertical: true)
					if let detail = sidebarPreviewDetail(preview.map { Text(verbatim: $0.site) }, lastUsed: preview?.lastUsed) {
						detail
							.font(.system(size: 11))
							.foregroundStyle(BrowserTheme.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
					if let summary {
						Text(summary)
							.font(.system(size: 11))
							.foregroundStyle(BrowserTheme.secondary)
							.lineLimit(3)
							.fixedSize(horizontal: false, vertical: true)
							.padding(.top, 2)
					}
				}
				Spacer(minLength: 0)
			}
			.padding(.vertical, 10)
			.padding(.horizontal, 12)
			.sidebarPreviewGlass()
			if showsLoadHint(preview) {
				HStack(spacing: 5) {
					ChromeKeyHint("⇧")
					Text(localized: .appUI.sidebar.previewLoadPage)
						.font(.system(size: 11))
						.foregroundStyle(BrowserTheme.secondary)
				}
				.padding(.leading, 6)
			}
			if let site {
				SidebarSitePreviewSection(preview: site)
			}
		}
		.frame(width: SidebarPreviewGlassMetrics.tabWidth, alignment: .leading)
		.accessibilityElement(children: .combine)
		.task(id: PictureRequest(id: id, loadsLivePage: loadsLivePage)) {
			// A loaded page, or one Shift is loading, reserves the picture's space while it's
			// taken; any other card grows when a saved or published picture arrives. A picture
			// already shown stays until the new one replaces it.
			let livePage = loadsLivePage && preview?.isLoaded != true ? previews.livePage : nil
			isCapturing = preview?.isLoaded == true || livePage != nil

			// A request Shift replaced may still finish: what it brings is dropped.
			if let livePage {
				let image: CGImage? = await livePage(id)
				guard !Task.isCancelled else { return }
				if let image {
					thumbnail = image
					isCapturing = false
					return
				}
			}
			let image: CGImage? = await previews.thumbnail(id)
			guard !Task.isCancelled else { return }
			thumbnail = image ?? thumbnail
			isCapturing = false
		}
		.task(id: id) {
			guard preview?.isLoaded != true else { return }
			summary = await previews.summary(id)
		}
		.task(id: id) {
			site = await previews.site(id)
		}
	}

	/// The picture inside its glass tile, the tile's inset narrower than the card.
	private static let imageWidth: CGFloat = SidebarPreviewGlassMetrics.tabWidth - SidebarPreviewGlassMetrics.tileInset * 2
	private static let imageHeight: CGFloat = 160
	private static let imageRadius: CGFloat = ArxRaisedPalette.insetRadius(tileRadius: SidebarPreviewGlassMetrics.tileRadius)

	/// The page's picture, or the space a loaded page, or one Shift is loading, keeps while it's taken.
	@ViewBuilder
	private var picture: some View {
		if let thumbnail {
			Image(decorative: thumbnail, scale: 1)
				.resizable()
				.aspectRatio(contentMode: .fill)
		} else {
			BrowserTheme.hover
		}
	}

	/// A page that isn't loaded says Shift loads it, while Shift + hover loads the page is on
	/// (DEV-1029) and Shift hasn't already.
	private func showsLoadHint(_ preview: SidebarTabPreview?) -> Bool {
		previews.livePage != nil && preview?.isLoaded != true && !loadsLivePage
	}

	private struct PictureRequest: Equatable {
		internal var id: UUID
		internal var loadsLivePage: Bool
	}
}

// MARK: - Folder list

/// A folder's card (DEV-1275): a glass search field with Close beside it, and a glass tile of the
/// folder's tabs at any depth, its own first, then each subfolder's under its path.
internal struct SidebarFolderPreviewList: View {
	private let folder: SidebarItem
	private let previews: SidebarHoverPreviews
	private let search: SidebarFolderSearch
	private let send: (SidebarFolderSearch.Action) -> Void
	private let close: () -> Void

	internal init(
		folder: SidebarItem,
		previews: SidebarHoverPreviews,
		search: SidebarFolderSearch,
		send: @escaping (SidebarFolderSearch.Action) -> Void,
		close: @escaping () -> Void = {}
	) {
		self.folder = folder
		self.previews = previews
		self.search = search
		self.send = send
		self.close = close
	}

	internal var body: some View {
		let contents = SidebarFolderPreview(
			folder: folder,
			tabs: previews.tabs(SidebarFolderPreview.tabIDs(in: folder))
		)
		let groups = contents.groups(matching: search.query)
		let selection = search.selection(in: groups.flatMap { $0.entries.map(\.id) })

		VStack(alignment: .leading, spacing: SidebarPreviewGlassMetrics.spacing) {
			HStack(spacing: ArxFloatingGlass.controlSpacing) {
				// Every folder has its search, an empty one too, so the card keeps one shape.
				SidebarPreviewSearchField(
					placeholder: String.localized(.appUI.sidebar.previewSearchFolder(folder.title)),
					query: .init(
						get: { search.query },
						set: { send(.queryChanged($0)) }
					),
					// Closes the card, as Escape in its panel does (DEV-1297).
					onEscape: { send(.escape) }
				)
				ArxGlassCloseButton(action: close)
			}
			Group {
				if contents.entries.isEmpty {
					SidebarPreviewGlassMessage(String.localized(.appUI.sidebar.previewEmptyFolder))
						.padding(SidebarPreviewGlassMetrics.tileInset)
				} else if groups.isEmpty {
					SidebarPreviewGlassMessage(String.localized(.appUI.sidebar.previewNoMatches))
						.padding(SidebarPreviewGlassMetrics.tileInset)
				} else {
					// DESIGN.md › Lists (DEV-1289): rows touch, each holding half the gap around its
					// squircle, and the tile's inset is padding on the scrolled content, which
					// scrolling to a row brings in with it. Not lazy, so every row has the identity
					// the arrows scroll to.
					let gap = SidebarPreviewGlassMetrics.rowSpacing
					let padding = ArxListLayout.contentPadding(inset: SidebarPreviewGlassMetrics.tileInset, gap: gap)
					ScrollViewReader { proxy in
						ScrollView {
							VStack(alignment: .leading, spacing: 0) {
								ForEach(groups) { group in
									if !group.folderIDs.isEmpty {
										// As far from the rows around it as before rows touched.
										Text(group.path.joined(separator: " / "))
											.font(.system(size: 11, weight: .semibold))
											.foregroundStyle(BrowserTheme.secondary)
											.lineLimit(1)
											.padding(.horizontal, 10)
											.padding(.top, 8 + gap / 2)
											.padding(.bottom, 2 + gap / 2)
									}
									ForEach(group.entries) { entry in
										SidebarFolderPreviewRow(
											entry: entry,
											isSelected: entry.id == selection,
											hovered: { send(.rowHovered(entry.id)) },
											open: { send(.rowClicked(entry.id)) }
										)
										.arxListRow(gap: gap)
										.arxListRowAnchor(entry.id, top: padding, bottom: padding)
									}
								}
							}
							.padding(.horizontal, SidebarPreviewGlassMetrics.tileInset)
							.padding(.vertical, padding)
						}
						.scrollBounceBehavior(.basedOnSize)

						// The tile's inset is inside the scroll view now, so the cap includes it.
						.frame(maxHeight: SidebarPreviewGlassMetrics.listMaxHeight + 2 * SidebarPreviewGlassMetrics.tileInset)
						.fixedSize(horizontal: false, vertical: true)

						// The rows scroll to the tile's edge now, so its corners cut them.
						.clipShape(.rect(cornerRadius: SidebarPreviewGlassMetrics.tileRadius, style: .continuous))

						// The selection stays in view as the arrows move it and the list filters.
						.onChange(of: selection) { _, id in
							guard let id else { return }
							proxy.scrollToListRow(id)
						}
					}
				}
			}
			.sidebarPreviewGlass()
		}
		.frame(width: SidebarPreviewGlassMetrics.folderWidth, alignment: .leading)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(folder.title)
	}
}

/// A folder card's search, on glass like the card's tile: "Search <folder>", since the card has
/// no title of its own. Tab moves the keyboard into it (DEV-836).
private struct SidebarPreviewSearchField: View {
	private let placeholder: String
	private let query: Binding<String>
	private let onEscape: () -> Void

	internal init(
		placeholder: String,
		query: Binding<String>,
		onEscape: @escaping () -> Void
	) {
		self.placeholder = placeholder
		self.query = query
		self.onEscape = onEscape
	}

	internal var body: some View {
		ArxGlassSearchField(placeholder: placeholder, isEmpty: query.wrappedValue.isEmpty, onEscape: onEscape) {
			TextField(placeholder, text: query, prompt: Text(verbatim: ""))
				.accessibilityLabel(Text(verbatim: placeholder))
		}
	}
}

/// A tab in a folder's card: its site icon, its title, and its site and last use under it; a Split
/// View names its panes. The pointer and the arrows share one selection, as in the command bar.
private struct SidebarFolderPreviewRow: View {
	private let entry: SidebarFolderPreview.Entry
	private let isSelected: Bool
	private let hovered: () -> Void
	private let open: () -> Void

	internal init(
		entry: SidebarFolderPreview.Entry,
		isSelected: Bool,
		hovered: @escaping () -> Void,
		open: @escaping () -> Void
	) {
		self.entry = entry
		self.isSelected = isSelected
		self.hovered = hovered
		self.open = open
	}

	internal var body: some View {
		Button(action: open) {
			SidebarPreviewRaisedRow(title: entry.title, detail: detail, isSelected: isSelected) {
				FavoriteSiteIcon(
					key: entry.siteIcon,
					fallback: entry.symbol,
					tint: entry.tint,
					size: 16,
					fallbackSize: 14,
					fallbackWeight: .medium
				)
				.frame(width: 16, height: 16)
			}
		}
		.buttonStyle(.plain)
		.onHover { if $0 { hovered() } }
		.accessibilityAddTraits(isSelected ? .isSelected : [])
		.help(entry.preview?.url.absoluteString ?? entry.title)
	}

	private var detail: Text? {
		let lead: Text? = if let panes = entry.splitPanes {
			Text(localized: .appUI.sidebar.previewSplitView(panes))
		} else {
			entry.preview.map { Text(verbatim: $0.site) }
		}
		return sidebarPreviewDetail(lead, lastUsed: entry.preview?.lastUsed)
	}
}
