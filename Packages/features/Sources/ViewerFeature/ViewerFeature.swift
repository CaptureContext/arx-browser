import BrowserCore
import BrowserEngineClient
import Foundation
import ViewerItemFeature
import _ComposableArchitecture

@Reducer
public struct ViewerFeature {
	@ObservableState
	public struct State: Equatable {
		public var panes: IdentifiedArrayOf<ViewerPaneFeature.State>
		public var activePaneID: UUID
		public var orientation: Orientation

		/// Each pane's share of the split's length, in `panes` order.
		public var fractions: [Double]

		/// How many panes fit side by side and stacked, at the minimum pane length.
		public var capacity: Capacity

		/// Tabs other windows or Peek show. A layout leaves them out, since a tab has one host.
		public var tabsShownElsewhere: Set<BrowserCore.Tab.ID>
		public var spaceID: Space.ID?
		public var requestedSpaceID: Space.ID?
		public var presentations: [BrowserSpacePresentation]
		public var preservesPresentation: Bool

		/// Panes a space switch kept because they already showed the restored page. The next
		/// `resume` leaves them observing as they are instead of showing their page again.
		public var continuingPaneIDs: Set<UUID>

		/// Retained across removed panes so a restored placement never reuses an observation epoch.
		public var observationGeneration: Int

		public init(item: ViewerItemFeature.State = .init()) {
			let id = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
			self.panes = [.init(id: id, item: item)]
			self.activePaneID = id
			self.orientation = .horizontal
			self.fractions = [1]
			self.capacity = .init()
			self.tabsShownElsewhere = []
			self.spaceID = nil
			self.requestedSpaceID = nil
			self.presentations = []
			self.preservesPresentation = false
			self.continuingPaneIDs = []
			self.observationGeneration = item.generation
		}

		/// Compatibility projection. Asynchronous actions always use `panes` and their original ID.
		public var item: ViewerItemFeature.State {
			get { panes[id: activePaneID]?.item ?? .init() }
			set { panes[id: activePaneID]?.item = newValue }
		}

		public var isSplit: Bool { panes.count > 1 }

		/// How many panes the current orientation has room for.
		public var paneLimit: Int { capacity.panes(orientation) }

		/// Whether one more pane fits, given the limit of four and the window's size.
		public var canAddPane: Bool { panes.count < paneLimit }

		/// The first pane's share, as the two-pane divider showed it.
		public var proportion: Double { fractions.first ?? 1 }
	}

	public struct Capacity: Equatable, Sendable {
		public var horizontal: Int
		public var vertical: Int

		/// Until the view measures the window, nothing is refused for size.
		public init(
			horizontal: Int = SplitLayout.maximumPanes,
			vertical: Int = SplitLayout.maximumPanes
		) {
			self.horizontal = horizontal
			self.vertical = vertical
		}

		public init(size: CGSize) {
			self.init(
				horizontal: SplitLayout.capacity(length: size.width),
				vertical: SplitLayout.capacity(length: size.height)
			)
		}

		public func panes(_ orientation: Orientation) -> Int {
			orientation == .horizontal ? horizontal : vertical
		}
	}

	public typealias Orientation = BrowserSpacePresentation.Orientation

	@CasePathable
	public enum Action: Sendable {
		case item(ViewerItemFeature.Action)
		case panes(IdentifiedActionOf<ViewerPaneFeature>)
		case show(BrowserCore.Tab?, in: UUID)
		case unload(BrowserCore.Tab.ID, in: UUID, generation: Int)
		case unloadIfUnchanged(BrowserCore.Tab.ID, in: UUID, generation: Int)

		/// Shows `tab` again in the pane that shows it, opening its page anew: its page closed, as when
		/// another Mac moved it to another profile, and the pane would stay blank otherwise. A suspended
		/// pane stays suspended.
		case reopen(BrowserCore.Tab, in: UUID)
		case split(BrowserCore.Tab?)

		/// Adds a pane for `tab` at `index`, turning the split to `orientation`.
		case insert(BrowserCore.Tab, at: Int, orientation: Orientation)

		/// Adds an empty pane at `index`, turning the split to `orientation` (DEV-733).
		case splitEmpty(at: Int, orientation: Orientation)

		/// Shows exactly these tabs, in order, keeping the panes that already show one of them.
		case layout(Layout)

		/// A layout's own `show`, kept apart so nothing mistakes it for the user changing a pane.
		case showInLayout(BrowserCore.Tab?, in: UUID)
		case command(BrowserEngineClient.Command, in: UUID, tabID: BrowserCore.Tab.ID)
		case suspend
		case resume
		case selectSpace(
			Space.ID,
			BrowserOrganization,
			selected: BrowserCore.Tab?,
			selectRequested: Bool = false,
			excluding: Set<BrowserCore.Tab.ID> = []
		)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case focus(UUID)
			case focusOtherPane
			case closePane(UUID)
			case swapPanes
			case toggleOrientation

			/// Each pane's share at the end of a divider drag.
			case resize([Double])

			/// A divider's double-click: every pane gets an equal share.
			case equalize
			case resizeEnded

			/// The viewer's size changed enough to fit a different number of panes.
			case capacityChanged(Capacity)
		}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public struct Layout: Equatable, Sendable {
		public var tabs: [BrowserCore.Tab]
		public var activeTabID: BrowserCore.Tab.ID?
		public var orientation: Orientation
		public var fractions: [Double]

		/// Ends with an empty, focused pane waiting for a tab, as Add Tab… opens.
		public var addsEmptyPane: Bool

		public init(
			tabs: [BrowserCore.Tab],
			activeTabID: BrowserCore.Tab.ID?,
			orientation: Orientation = .horizontal,
			fractions: [Double]? = nil,
			addsEmptyPane: Bool = false
		) {
			self.tabs = tabs
			self.activeTabID = activeTabID
			self.orientation = orientation
			self.addsEmptyPane = addsEmptyPane
			self.fractions = SplitLayout.sanitized(fractions, count: tabs.count + (addsEmptyPane ? 1 : 0))
		}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		// Normalize compatibility actions before entering forEach, so child cancellation IDs
		// and every emitted action are scoped to the pane that received the original action.
		Reduce { state, action in
			state.preserveObservationGeneration()
			defer { state.preserveObservationGeneration() }
			let routed: Action
			switch action {
			case let .unload(tabID, id, generation):
				@Dependency(\.browserEngine)
				var engine

				guard
					state.panes[id: id]?.item.tab?.id == tabID,
					state.panes[id: id]?.item.generation == generation
				else { return .none }
				return .run { @MainActor [engine] send in
					guard engine.snapshot(tabID) == nil else { return }
					send(.unloadIfUnchanged(tabID, in: id, generation: generation))
				}

			case let .unloadIfUnchanged(tabID, id, generation):
				guard
					state.panes[id: id]?.item.tab?.id == tabID,
					state.panes[id: id]?.item.generation == generation
				else { return .none }
				routed = .panes(.element(id: id, action: .item(.show(nil))))

			case let .reopen(tab, id):
				guard
					let item = state.panes[id: id]?.item,
					item.tab?.id == tab.id,
					item.isObserving
				else { return .none }
				routed = .panes(.element(id: id, action: .item(.show(tab))))

			case let .command(command, id, tabID):
				guard state.panes[id: id]?.item.tab?.id == tabID else { return .none }
				routed = .panes(.element(id: id, action: .item(.ui(.command(command)))))

			case let .item(item):
				routed = .panes(.element(id: state.activePaneID, action: .item(item)))

			case let .show(tab, id), let .showInLayout(tab, id):
				guard state.panes[id: id] != nil else { return .none }
				if let tab, let existing = state.panes.first(where: { $0.item.tab?.id == tab.id }) {
					state.activePaneID = existing.id
					return .none
				}
				routed = .panes(.element(id: id, action: .item(.show(tab))))

			case let .panes(.element(id, _)):
				guard state.panes[id: id] != nil else { return .none }
				routed = action

			default:
				routed = action
			}
			if case let .panes(.element(id, .item(.show(tab)))) = routed, tab != nil {
				// Exhaustion cannot wrap into authority held by an earlier observation.
				guard state.observationGeneration < Int.max else { return .none }
				let generation = state.observationGeneration
				state.panes[id: id]?.item.generation = generation
			}
			return ViewerPanes()._reduce(into: &state, action: routed)
		}
	}
}
