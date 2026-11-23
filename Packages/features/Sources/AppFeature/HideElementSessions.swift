import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
import SwiftUI
import _ComposableArchitecture

/// Hide Element's mode on one page (DEV-1298): the engine's picker stays open over the page,
/// outlined in red with the scope pointer, each click hiding an element and saving it to My
/// filters, while a toast at the page's bottom right offers Undo and Done and opens into the
/// list of the elements hidden on the site, the same entries as the site menu's Hidden Elements.
@Reducer
public struct HideElementFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		/// The page's tab: one mode per page.
		public var id: BrowserCore.Tab.ID

		/// The page's site as uBlock names it, whose lines the list shows.
		public var site: String

		/// The elements hidden on the site, in My filters' order, then this session's picks.
		public var entries: IdentifiedArrayOf<Entry>
		public var isExpanded: Bool

		/// The entry ↑ and ↓ chose in the open list, which Delete shows again.
		public var selection: Entry.ID?

		/// The lines this session hid, the last at the end, which Undo takes back in turn.
		public var undoable: [String]

		/// Lines shown again whose elements the page keeps hidden until it loads again.
		public var waitingForReload: [String]

		/// Lines on their way out of My filters, which a list read before uBlock drops them still
		/// has: they stay off the list until one read without them.
		public var removing: Set<String> = []
		public var note: HideElementToast.Note?

		/// The outline's box in the page's points, which the toast keeps clear of.
		public var target: CGRect?

		/// Done was asked for; the picker is closing.
		public var isFinishing: Bool

		/// The page's document when the mode opened: Done reloads only that one.
		public var documentRevision: UInt64?

		/// The engine can't run the mode on the page: once its stream ends, the host opens
		/// uBlock's picker instead.
		public var isUnavailable: Bool = false

		public init(
			id: BrowserCore.Tab.ID,
			site: String,
			entries: IdentifiedArrayOf<Entry> = [],
			isExpanded: Bool = false,
			selection: Entry.ID? = nil,
			undoable: [String] = [],
			waitingForReload: [String] = [],
			note: HideElementToast.Note? = nil,
			target: CGRect? = nil,
			isFinishing: Bool = false
		) {
			self.id = id
			self.site = site
			self.entries = entries
			self.isExpanded = isExpanded
			self.selection = selection
			self.undoable = undoable
			self.waitingForReload = waitingForReload
			self.note = note
			self.target = target
			self.isFinishing = isFinishing
		}

		public var canUndo: Bool { !undoable.isEmpty && !isFinishing }
	}

	/// A line of My filters hiding an element on the site, and what it hides when the page has it.
	public struct Entry: Equatable, Identifiable, Sendable {
		/// The line, `site##selector`.
		public var id: String
		public var element: BrowserHiddenElementDescription?

		public init(
			id: String,
			element: BrowserHiddenElementDescription? = nil
		) {
			self.id = id
			self.element = element
		}

		public var selector: String { BrowserHiddenElements.selector(of: id) }
	}

	@CasePathable
	public enum Action: Sendable {
		/// Opens the mode on the page, outlined in `accent`.
		case start(ChromePalette.RGB)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)

		@CasePathable
		public enum UI: Sendable {
			case undo
			case done
			case toggleList

			/// An entry's eye, or Delete on the chosen one: the element shows again.
			case show(String)
		}

		@CasePathable
		public enum Event: Sendable {
			case engine(BrowserElementHidingEvent)

			/// The site's lines, read from My filters.
			case entriesLoaded([String]?)

			/// The picker closed.
			case ended
		}

		@CasePathable
		public enum Delegate: Sendable {
			/// The engine can't run the mode on this page: the host opens uBlock's picker instead.
			case unavailable

			/// The mode is over: the host lets the session go.
			case ended
		}
	}

	/// How many times Done waits for uBlock to drop a line shown again before reloading.
	public static let reloadPolls: Int = 20
	public static let reloadPollInterval: Duration = .milliseconds(100)

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.continuousClock)
	private var clock

	public init() {}

	public var body: some ReducerOf<Self> {
		Reduce { state, action in
			switch action {
			case let .start(accent):
				let id = state.id
				return .run { [engine] send in
					let events = await engine.hideElements(id, accent) { NSCursor.hideElement }
					for await event in events {
						await send(.event(.engine(event)))
					}
					await send(.event(.ended))
				}

			case let .event(.engine(event)):
				return handle(event, state: &state)

			case let .event(.entriesLoaded(filters)):
				guard let filters else { return .none }

				// Lines shown again stay off the list until uBlock has dropped them.
				state.removing.formIntersection(filters)
				let listed = filters.filter { !state.removing.contains($0) }

				// The site's lines in My filters' order; this session's picks the engine hasn't
				// listed yet stay at the end.
				var entries: IdentifiedArrayOf<Entry> = .init(uniqueElements: listed.map { filter in
					state.entries[id: filter] ?? .init(id: filter)
				})
				for entry in state.entries where entries[id: entry.id] == nil && state.undoable.contains(entry.id) {
					entries.append(entry)
				}
				state.entries = entries
				state.fixSelection()
				let unnamed = entries.filter { $0.element == nil }.map(\.id)
				guard !unnamed.isEmpty else { return .none }

				let id = state.id
				_ = MainActor.assumeIsolated { [engine] in engine.elementHidingCommand(id, .describe(unnamed)) }
				return .none

			case .event(.ended):
				// Told once the stream is over, so the host lets the session go with nothing left
				// to send it.
				if state.isUnavailable { return .send(.delegate(.unavailable)) }

				let id = state.id
				let waiting = state.waitingForReload
				let document = state.documentRevision
				guard !waiting.isEmpty, document != nil else { return .send(.delegate(.ended)) }

				// An element hidden before this time comes back only once the page loads again
				// without its line, which uBlock says by listing the site without it.
				return .run { [engine, clock] send in
					for _ in 0..<Self.reloadPolls {
						let hidden = await engine.hiddenElements(id)
						let lines = Set(hidden?.sites.values.flatMap(\.self) ?? [])
						guard waiting.contains(where: lines.contains) else { break }
						try? await clock.sleep(for: Self.reloadPollInterval)
					}

					// Only the page the mode was on: the person may have browsed on, which ended it.
					if await engine.snapshot(id)?.documentRevision == document {
						try? await engine.command(id, .reload)
					}
					await send(.delegate(.ended))
				}

			case .ui(.undo):
				guard !state.isFinishing, let filter = state.undoable.popLast() else { return .none }

				return show(filter, state: &state)

			case let .ui(.show(filter)):
				guard !state.isFinishing, state.entries[id: filter] != nil else { return .none }

				state.undoable.removeAll { $0 == filter }
				return show(filter, state: &state)

			case .ui(.toggleList):
				guard !state.isFinishing else { return .none }

				state.isExpanded.toggle()
				let id = state.id
				let isOpen = state.isExpanded
				if isOpen {
					state.selection = state.selection ?? state.entries.last?.id
				}
				_ = MainActor.assumeIsolated { [engine] in engine.elementHidingCommand(id, .listOpen(isOpen)) }
				return isOpen ? loadEntries(state) : .none

			case .ui(.done):
				guard !state.isFinishing else { return .none }

				state.isFinishing = true
				let id = state.id
				let closing = MainActor.assumeIsolated { [engine] in engine.elementHidingCommand(id, .close) }

				// No picker to close: the mode is over already.
				return closing ? .none : .send(.event(.ended))

			case .delegate:
				return .none
			}
		}
	}

	private func handle(
		_ event: BrowserElementHidingEvent,
		state: inout State
	) -> Effect<Action> {
		switch event {
		case .unavailable:
			state.isFinishing = true
			state.isUnavailable = true
			return .none

		case .opened:
			let id = state.id
			state.documentRevision = MainActor.assumeIsolated { [engine] in engine.snapshot(id)?.documentRevision }
			return loadEntries(state)

		case let .hidden(filter, element):
			state.note = nil
			state.undoable.removeAll { $0 == filter }
			state.undoable.append(filter)
			state.waitingForReload.removeAll { $0 == filter }
			if state.entries[id: filter] == nil {
				state.entries.append(.init(id: filter, element: element))
			} else {
				state.entries[id: filter]?.element = element
			}
			return .none

		case let .refused(filter):
			// It went from the page, but nothing keeps it hidden; Undo still shows it again.
			state.note = .refused
			state.undoable.removeAll { $0 == filter }
			state.undoable.append(filter)
			return .none

		case let .target(box):
			state.target = box
			return .none

		case let .described(found):
			for (filter, element) in found {
				guard let element else { continue }
				state.entries[id: filter]?.element = element
			}
			return .none

		case let .shown(filter, isVisible):
			if !isVisible, !state.waitingForReload.contains(filter) {
				state.waitingForReload.append(filter)
			}
			return .none

		case let .key(key):
			switch key {
			case .escape:
				guard state.isExpanded else { return .send(.ui(.done)) }
				return .send(.ui(.toggleList))

			case .return:
				return .send(.ui(.toggleList))

			case .undo:
				return .send(.ui(.undo))

			case .up, .down:
				state.moveSelection(by: key == .up ? -1 : 1)
				return .none

			case .delete:
				guard let selection = state.selection else { return .none }
				return .send(.ui(.show(selection)))
			}
		}
	}

	/// Takes `filter` out of My filters and shows its element on the page again.
	private func show(
		_ filter: String,
		state: inout State
	) -> Effect<Action> {
		let id = state.id
		let wasListed = state.entries[id: filter] != nil
		let index = state.entries.index(id: filter)
		state.entries.remove(id: filter)
		state.note = nil
		if let index, state.selection == filter {
			state.selection = state.entries.isEmpty ? nil : state.entries[min(index, state.entries.count - 1)].id
		}
		let (shown, unhidden) = MainActor.assumeIsolated { [engine] in

			// A pick the engine refused has no line to take out, only its element to show.
			let removed = wasListed ? engine.showHiddenElement(id, filter) : true
			return (removed, engine.elementHidingCommand(id, .unhide(filter)))
		}

		// A line the page can't show at once, such as one of uBlock's `:remove()` lines, comes
		// back when Done reloads the page.
		if shown, wasListed, !unhidden, !state.waitingForReload.contains(filter) {
			state.waitingForReload.append(filter)
		}
		if !shown {
			// It's still in My filters: list it again on the next look.
			return loadEntries(state)
		}
		if wasListed { state.removing.insert(filter) }
		return .none
	}

	private func loadEntries(_ state: State) -> Effect<Action> {
		let id = state.id
		let site = state.site
		return .run { [engine] send in
			let hidden = await engine.hiddenElements(id)
			await send(.event(.entriesLoaded(hidden?.filters(for: site))))
		}
	}
}

extension HideElementFeature.State {
	/// Keeps the chosen entry one that's listed.
	fileprivate mutating func fixSelection() {
		guard let selection, entries[id: selection] == nil else { return }
		self.selection = isExpanded ? entries.last?.id : nil
	}

	/// ↑ and ↓ in the open list, stopping at its ends.
	fileprivate mutating func moveSelection(by offset: Int) {
		guard isExpanded, !entries.isEmpty else { return }

		let current = selection.flatMap { entries.index(id: $0) } ?? (offset > 0 ? -1 : entries.count)
		let next = min(max(current + offset, 0), entries.count - 1)
		selection = entries[next].id
	}
}

/// Runs each page's Hide Element mode (DEV-1298); `CommandRouting` starts and ends them.
@Reducer
internal struct HideElementSessions {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	internal init() {}

	internal var body: some ReducerOf<Self> {
		EmptyReducer()
			.forEach(\.hideElementSessions, action: \.hideElementSessions) { HideElementFeature() }

		// Little Arx's own command bar offers Hide Element as its menu does.
		Reduce { state, _ in
			let available = state.hideElementEnabled && state.settings.general.blocksContent
			for id in state.littleWindows.ids where state.littleWindows[id: id]?.canHideElements != available {
				state.littleWindows[id: id]?.canHideElements = available
			}
			return .none
		}
	}
}

// MARK: - Presentation

extension HideElementFeature.Entry {
	/// The entry as the toast's list shows it: what the outline's label called the element, else
	/// its selector; its kind and its selector; a symbol for its kind.
	internal var presentation: HideElementToast.Entry {
		let kind = element?.kind ?? .element
		return .init(
			id: id,
			title: element?.label.isEmpty == false ? element?.label ?? selector : selector,
			detail: String.localized(.appUI.hideElement.toast.entryDetail(kind.title, selector)),
			symbol: kind.symbol
		)
	}
}

extension BrowserHiddenElementDescription.Kind {
	internal var title: String {
		switch self {
		case .link: String.localized(.appUI.hideElement.kind.link)
		case .button: String.localized(.appUI.hideElement.kind.button)
		case .image: String.localized(.appUI.hideElement.kind.image)
		case .video: String.localized(.appUI.hideElement.kind.video)
		case .audio: String.localized(.appUI.hideElement.kind.audio)
		case .frame: String.localized(.appUI.hideElement.kind.frame)
		case .list: String.localized(.appUI.hideElement.kind.list)
		case .listItem: String.localized(.appUI.hideElement.kind.listItem)
		case .navigation: String.localized(.appUI.hideElement.kind.navigation)
		case .banner: String.localized(.appUI.hideElement.kind.banner)
		case .footer: String.localized(.appUI.hideElement.kind.footer)
		case .sidebar: String.localized(.appUI.hideElement.kind.sidebar)
		case .form: String.localized(.appUI.hideElement.kind.form)
		case .dialog: String.localized(.appUI.hideElement.kind.dialog)
		case .section: String.localized(.appUI.hideElement.kind.section)
		case .article: String.localized(.appUI.hideElement.kind.article)
		case .textField: String.localized(.appUI.hideElement.kind.textField)
		case .heading: String.localized(.appUI.hideElement.kind.heading)
		case .paragraph: String.localized(.appUI.hideElement.kind.paragraph)
		case .table: String.localized(.appUI.hideElement.kind.table)
		case .element: String.localized(.appUI.hideElement.kind.element)
		}
	}

	internal var symbol: String {
		switch self {
		case .link: "link"
		case .button: "button.horizontal"
		case .image: "photo"
		case .video: "play.rectangle"
		case .audio: "waveform"
		case .frame: "rectangle.on.rectangle"
		case .list, .listItem: "list.bullet"
		case .navigation: "menubar.rectangle"
		case .banner: "rectangle.topthird.inset.filled"
		case .footer: "rectangle.bottomthird.inset.filled"
		case .sidebar: "sidebar.right"
		case .form, .textField: "character.cursor.ibeam"
		case .dialog: "macwindow"
		case .section, .article: "doc.text"
		case .heading, .paragraph: "text.alignleft"
		case .table: "tablecells"
		case .element: "square.dashed"
		}
	}
}

// MARK: - Overlay

/// Hide Element's toast over its page (DEV-1298), at the bottom right, moving to the bottom left
/// or fading when the outline comes near, so it never covers what's being chosen.
internal struct HideElementOverlay: View {
	internal let store: StoreOf<HideElementFeature>

	@State
	private var placement: HideElementToastPlacement = .trailing

	@State
	private var toastSize: CGSize = .zero

	/// Whether the pointer is over the toast, which then holds still and solid (DEV-1315).
	@State
	private var isPointerOver: Bool = false

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion: Bool

	private func place(page: CGSize) {
		placement = HideElementToastPlacement.resolve(
			target: store.target,
			toast: toastSize,
			page: page,
			current: placement,
			isPointerOver: isPointerOver
		)
	}

	internal var body: some View {
		GeometryReader { geometry in
			let page = geometry.size
			HideElementToast(
				site: store.site,
				entries: store.entries.map(\.presentation),
				isExpanded: store.isExpanded,
				selection: store.selection,
				canUndo: store.canUndo,
				note: store.note,
				reloadsWhenDone: !store.waitingForReload.isEmpty,
				undo: { store.send(.ui(.undo)) },
				done: { store.send(.ui(.done)) },
				toggle: { store.send(.ui(.toggleList)) },
				show: { store.send(.ui(.show($0))) }
			)
			.onGeometryChange(for: CGSize.self, of: \.size) { toastSize = $0 }
			.onHover { isPointerOver = $0 }
			.opacity(placement == .faded ? HideElementToast.Metrics.fadedOpacity : 1)
			.padding(HideElementToast.Metrics.edgeInset)
			.frame(
				maxWidth: .infinity,
				maxHeight: .infinity,
				alignment: placement == .leading ? .bottomLeading : .bottomTrailing
			)

			// Again whenever the outline, the toast (its list opening) or the page changes size.
			.onChange(of: store.target, initial: true) { place(page: page) }
			.onChange(of: toastSize) { place(page: page) }
			.onChange(of: page) { place(page: page) }
			.onChange(of: isPointerOver) { place(page: page) }
			.animation(reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28), value: placement)
			.animation(reduceMotion ? nil : .snappy(duration: 0.24), value: store.isExpanded)
		}
		.transition(.opacity.combined(with: .move(edge: .bottom)))
	}
}

/// Draws a page's Hide Element toast, and its capture session, above its surface, wherever the
/// page is shown: the main window, a Split View pane, Peek or Little Arx.
@MainActor
internal func pageOverlay(store: StoreOf<AppFeature>) -> BrowserPageOverlay {
	let capture = pageCaptureOverlay(store: store)
	return .init { tabID in
		if let view = capture.content(tabID) { return view }
		guard
			store.hideElementSessions[id: tabID] != nil,
			let child = store.scope(state: \.hideElementSessions[id: tabID], action: \.hideElementSessions[id: tabID])
		else { return nil }

		return AnyView(
			HideElementOverlay(store: child)
				.id(tabID)

				// Switching tabs or closing the window ends the mode, as it ends a capture.
				.onDisappear {
					guard store.hideElementSessions[id: tabID]?.isFinishing == false else { return }
					store.send(.hideElementSessions(.element(id: tabID, action: .ui(.done))))
				}
		)
	}
}
