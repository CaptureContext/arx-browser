import AppUI
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

public struct LinkActionFeedback: Equatable, Sendable {
	public var windowID: UUID?

	/// The split view pane the links came from, so the toast shows in that pane.
	/// `nil` outside split view, where the toast stays at the window's corner.
	public var paneID: UUID?
	public var result: LinkCopyResult
	public var status: Status

	public init(
		windowID: UUID?,
		paneID: UUID? = nil,
		result: LinkCopyResult,
		status: Status
	) {
		self.windowID = windowID
		self.paneID = paneID
		self.result = result
		self.status = status
	}

	public enum Status: Equatable, Sendable {
		case copied
		case copyFailed
		case share(LinkShareOutcome)
	}
}

@Reducer
internal struct LinkActions {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.linkSharing)
	private var sharing

	private enum Cancellation: Hashable {
		case feedbackTimer
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.copyLinks) { state, value in
			let (mode, suppliedItems, preferredRuleID, sourceWindowID, sourcePaneID) = value
			let items = suppliedItems ?? state.linkItems(in: sourceWindowID ?? state.focusedWindowID, paneID: sourcePaneID)
			guard !items.isEmpty else { return .none }
			let result = LinkTransformer.copy(
				items, mode: mode, rules: state.settings.proxyLinkRules, preferredRuleID: preferredRuleID
			)
			state.linkActionGeneration += 1
			let generation = state.linkActionGeneration
			let windowID = sourceWindowID ?? state.focusedWindowID
			let paneID = state.linkFeedbackPaneID(in: windowID, preferring: sourcePaneID)
			return .run { [sharing] send in
				let copied = await sharing.copy(result.text)
				await send(.event(.linkActionFinished(generation, .init(
					windowID: windowID, paneID: paneID, result: result, status: copied ? .copied : .copyFailed
				))))
			}
		}

		Pullback(\.ui.shareProxyLinks) { state, value in
			let (suppliedItems, preferredRuleID, sourceWindowID, sourcePaneID) = value
			let items = suppliedItems ?? state.linkItems(in: sourceWindowID ?? state.focusedWindowID, paneID: sourcePaneID)
			guard !items.isEmpty else { return .none }
			let result = LinkTransformer.copy(
				items, mode: .proxy, rules: state.settings.proxyLinkRules, preferredRuleID: preferredRuleID
			)
			state.linkActionGeneration += 1
			let generation = state.linkActionGeneration
			let windowID = sourceWindowID ?? state.focusedWindowID
			let paneID = state.linkFeedbackPaneID(in: windowID, preferring: sourcePaneID)
			return .run { [sharing] send in
				let outcome: LinkShareOutcome
				do {
					try result.transformations.forEach { try LinkTransformer.validate($0.output) }
					outcome = await sharing.share(result.transformations.map(\.output), windowID)
				} catch {
					outcome = .failed(linkErrorMessage(error as? LinkTransformationError ?? .invalidURL))
				}
				await send(.event(.linkActionFinished(generation, .init(
					windowID: windowID, paneID: paneID, result: result, status: .share(outcome)
				))))
			}
		}

		Pullback(\.ui.shareLinks) { state, value in
			let (items, windowID) = value
			guard !items.isEmpty else { return .none }

			let result = LinkTransformer.copy(items, mode: .original, rules: state.settings.proxyLinkRules)
			state.linkActionGeneration += 1
			let generation = state.linkActionGeneration
			let paneID = state.linkFeedbackPaneID(in: windowID)
			return .run { [sharing] send in
				let outcome = await sharing.share(result.transformations.map(\.output), windowID)
				await send(.event(.linkActionFinished(generation, .init(
					windowID: windowID, paneID: paneID, result: result, status: .share(outcome)
				))))
			}
		}

		Pullback(\.delegate.copyURL) { _, url in
			.send(.ui(.copyLinks(.original, items: [.init(title: "", url: url)])))
		}

		Pullback(\.event.linkActionFinished) { state, value in
			let (generation, feedback) = value
			guard generation == state.linkActionGeneration else { return .none }
			if let id = feedback.windowID {
				guard state.hasLinkActionHost(id) else { return .none }
			}
			state.linkActionFeedback = feedback
			return .none
		}

		Pullback(\.ui.linkFeedbackShown) { state in
			guard state.linkActionFeedback != nil, !state.linkFeedbackIsHovered else { return .none }
			return expireFeedback(state.linkActionGeneration, after: ArxToastMetrics.duration)
		}

		Pullback(\.ui.dismissLinkFeedback) { state in
			state.linkActionFeedback = nil
			state.linkFeedbackIsHovered = false
			return .cancel(id: Cancellation.feedbackTimer)
		}

		Pullback(\.ui.linkFeedbackHovered) { state, isHovered in
			guard
				state.linkActionFeedback != nil,
				state.linkFeedbackIsHovered != isHovered
			else { return .none }

			state.linkFeedbackIsHovered = isHovered

			// The toast waits while the pointer is over it, then gives the reader a moment more.
			return isHovered
			? .cancel(id: Cancellation.feedbackTimer)
			: expireFeedback(state.linkActionGeneration, after: ArxToastMetrics.resumeDuration)
		}

		Pullback(\.event.linkFeedbackExpired) { state, generation in
			guard generation == state.linkActionGeneration, !state.linkFeedbackIsHovered
			else { return .none }

			state.linkActionFeedback = nil
			return .none
		}
	}
}

extension LinkActions {
	private func expireFeedback(
		_ generation: Int,
		after duration: Duration
	) -> Effect<Action> {
		let timer: Effect<Action> = .run { [clock] send in
			try await clock.sleep(for: duration)
			await send(.event(.linkFeedbackExpired(generation)))
		}
		.cancellable(id: Cancellation.feedbackTimer)

		// `cancelInFlight` cancels when the timer's task registers, off the main actor, so an
		// older timer could cancel this one and leave the feedback up. Cancel in reducer order
		// instead; an older timer that registers late carries an older generation and is ignored.
		return .concatenate(.cancel(id: Cancellation.feedbackTimer), timer)
	}
}

extension AppFeature.State {
	internal func hasLinkActionHost(_ id: UUID) -> Bool {
		if id == main.id { return windowIsOpen && !main.isClosing }
		if let host = windows[id: id] { return !host.isClosing }
		if let little = littleWindows[id: id] { return !little.isClosing && !little.isPromoting }

		// Page PiP's site menu shares from its floating window (DEV-1257).
		if id == LinkSharingClient.pagePictureInPictureWindowID { return pagePictureInPicture?.isFloating == true }
		return false
	}

	/// The pane a link toast reports on: in split view, the pane the links came from, or the
	/// focused pane. Outside split view, and over Peek, the toast keeps to the window's corner.
	internal func linkFeedbackPaneID(
		in windowID: UUID?,
		preferring sourcePaneID: UUID? = nil
	) -> UUID? {
		let id = windowID ?? main.id
		guard
			!peeks.contains(where: { $0.source.windowID == id }),
			let host = id == main.id ? main : windows[id: id],
			host.viewer.isSplit
		else { return nil }

		if let sourcePaneID, host.viewer.panes[id: sourcePaneID] != nil { return sourcePaneID }
		return host.viewer.activePaneID
	}

	/// The tab whose page shows the link toast, or `nil` when it shows at the window's corner:
	/// outside split view, or once its pane closed or the split ended.
	internal func linkFeedbackTabID(_ feedback: LinkActionFeedback) -> BrowserCore.Tab.ID? {
		guard let paneID = feedback.paneID, let id = feedback.windowID else { return nil }
		guard let host = id == main.id ? main : windows[id: id], host.viewer.isSplit else { return nil }
		return host.viewer.panes[id: paneID]?.item.tab?.id
	}

	internal mutating func discardLinkFeedback(in windowID: UUID) {
		guard linkActionFeedback?.windowID == windowID else { return }
		linkActionFeedback = nil
		linkFeedbackIsHovered = false
	}

	/// The active renderer is authoritative even when a pin has left its saved URL.
	public var focusedLinkItems: [LinkCopyItem] { linkItems(in: focusedWindowID) }

	public func linkItems(
		in windowID: UUID?,
		tabIDs: [UUID]? = nil,
		saved: Bool = false,
		paneID: UUID? = nil
	) -> [LinkCopyItem] {
		let peek = peeks.first(where: { $0.source.windowID == (windowID ?? main.id) })
		if tabIDs == nil, paneID == nil, !saved, let peek {
			guard peek.phase == .idle else { return [] }

			let navigation = peek.viewer.navigation
			return [.init(
				title: navigation.title.isEmpty ? peek.tab.displayTitle : navigation.title,
				url: navigation.url ?? peek.tab.restoration.url
			)]
		}
		if let id = windowID, let little = littleWindows[id: id] {
			guard !little.isCommandOnly, !little.isClosing, !little.isPromoting else { return [] }
			guard tabIDs == nil || tabIDs == [little.tab.id.rawValue] else { return [] }
			return [.init(
				title: little.viewer.navigation.title.isEmpty ? little.tab.displayTitle : little.viewer.navigation.title,
				url: little.viewer.navigation.url ?? little.tab.restoration.url
			)]
		}
		let focused: MainFeature.State?
		if let id = windowID, id != main.id { focused = windows[id: id] }
		else { focused = windowIsOpen ? main : nil }
		guard let focused, !focused.isClosing else { return [] }
		let pane = focused.viewer.panes[id: paneID ?? focused.viewer.activePaneID]
		guard pane != nil else { return [] }
		let selected = paneID != nil || focused.viewer.isSplit ? pane?.item.tab : focused.sidebar.selectedTab
		let ids = tabIDs ?? selected.map { [$0.id.rawValue] } ?? []
		return ids.compactMap { id in
			guard let tab = focused.sidebar.organization.tabs.first(where: { $0.id.rawValue == id })
			else { return nil }
			if saved, let destination = tab.savedDestination {
				return .init(title: destination.title, url: destination.url)
			}
			let navigation = focused.viewer.panes.first(where: { $0.item.tab?.id == tab.id })?.item.navigation
			let title = navigation.flatMap { $0.title.isEmpty ? nil : $0.title } ?? tab.displayTitle
			return .init(title: title, url: navigation?.url ?? tab.restoration.url)
		}
	}
}

@MainActor
internal func browserLinkActions(
	store: StoreOf<AppFeature>,
	windowID: UUID
) -> BrowserLinkActions {
	.init(
		copy: { mode, ids, saved in
			let items = ids.map { store.state.sidebarLinkItems(in: windowID, tabIDs: $0, saved: saved) }
			?? store.state.linkItems(in: windowID, saved: saved)
			let paneID = ids.flatMap { store.state.linkSourcePaneID(in: windowID, tabIDs: $0) }
			store.send(.ui(.copyLinks(mode, items: items, sourceWindowID: windowID, sourcePaneID: paneID)))
		},
		share: { ids in
			let items = ids.map { store.state.sidebarLinkItems(in: windowID, tabIDs: $0) }
			?? store.state.linkItems(in: windowID)
			let paneID = ids.flatMap { store.state.linkSourcePaneID(in: windowID, tabIDs: $0) }
			store.send(.ui(.shareProxyLinks(items: items, sourceWindowID: windowID, sourcePaneID: paneID)))
		},
		// Asked as the menu is built (DEV-1262).
		proxies: { ids in
			let items = ids.map { store.state.sidebarLinkItems(in: windowID, tabIDs: $0) }
			?? store.state.linkItems(in: windowID)
			let rules = store.state.settings.proxyLinkRules
			return items.contains { LinkTransformer.proxies($0.url, rules: rules) }
		}
	)
}

extension AppFeature.State {
	/// The pane showing the one tab a sidebar menu copies, so its toast shows there in split view.
	internal func linkSourcePaneID(
		in windowID: UUID,
		tabIDs: [UUID]
	) -> UUID? {
		guard tabIDs.count == 1, let host = windowID == main.id ? main : windows[id: windowID]
		else { return nil }
		return host.viewer.panes.first(where: { $0.item.tab?.id.rawValue == tabIDs[0] })?.id
	}
}
