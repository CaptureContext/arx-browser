import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// One close attempt of an ordinary window: the tabs it would release, in the order they're asked
/// (DEV-1107).
public struct WindowCloseRequest: Equatable, Sendable {
	public let token: Int
	public let tabIDs: [BrowserCore.Tab.ID]
}

/// Closing the main or an additional ordinary window asks the pages it would release that hold
/// unsaved input, while the window is still open to show their before-unload question, as closing
/// a private window asks its pages (DEV-1107).
///
/// Closing a window releases the tabs no other window holds (DEV-1104), and the engine keeps a
/// page with unsaved input loaded. Here those pages are asked first: Leave closes the window and
/// they unload with the others (`TabUnloadReason.windowClosedAnswered`); Stay keeps it open. A page
/// with unsaved input and nothing to ask agrees at once, as when closing its tab. With an engine
/// that can't tell, nothing is asked and the window closes as before.
@Reducer
internal struct WindowCloseQuestions {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.requestCloseWindow) { state, id in
			guard let window = state.openOrdinaryWindow(id) else {
				// Not an open ordinary window by the store's account: close as before.
				return Self.close(id, state: state)
			}

			// One question at a time; a window already closing is past asking.
			guard !window.isClosing, state.windowCloseRequests[id] == nil else { return .none }

			let tabs = state.tabsReleasedByClosing(id)

			// A quit asks every page itself.
			guard !tabs.isEmpty, !state.shouldQuit, !state.checkingQuit else {
				return Self.close(id, state: state)
			}

			state.windowCloseRequestCount &+= 1
			let request = WindowCloseRequest(token: state.windowCloseRequestCount, tabIDs: tabs)

			// Not `isClosing`: the window stays whole while it asks, its Peek and agents included, so
			// Stay finds it as it was.
			state.windowCloseRequests[id] = request

			return .run { @MainActor [engine] send in
				var answered: [BrowserCore.Tab.ID: UInt64] = [:]
				for tab in request.tabIDs where engine.tabHoldsUnsavedInput(tab) {
					guard !Task.isCancelled else { return }

					// The answer holds for the document that gave it, and only while it's current.
					let document = engine.snapshot(tab)?.documentRevision
					let approved = await engine.permitsClosing(tab)
					guard !Task.isCancelled else { return }
					guard approved else {
						send(.event(.windowCloseDecision(id, request, answered: nil)))
						return
					}
					if let document, engine.snapshot(tab)?.documentRevision == document {
						answered[tab] = document
					}
				}
				guard !Task.isCancelled else { return }
				send(.event(.windowCloseDecision(id, request, answered: answered)))
			}
			.cancellable(id: CloseEffectID(windowID: id), cancelInFlight: true)
		}

		Pullback(\.event.windowCloseDecision) { state, value in
			let (id, request, answered) = value
			guard state.windowCloseRequests[id] == request else { return .none }
			state.windowCloseRequests[id] = nil

			// Closed meanwhile another way.
			guard state.openOrdinaryWindow(id) != nil else { return .none }

			// Stay, or a quit that took over.
			guard let answered, !state.shouldQuit, !state.checkingQuit else { return .none }

			// The window now releases tabs it didn't ask, as after moving to another space: ask
			// again. Fewer, as when a sweep unloaded one meanwhile, needs no new question.
			guard Set(state.tabsReleasedByClosing(id)).isSubset(of: request.tabIDs) else {
				return .send(.ui(.requestCloseWindow(id)))
			}

			state.tabUnloading.answered.merge(answered) { _, new in new }
			return Self.close(id, state: state)
		}

		// A window closing another way, as an agent or a quit closes it, stops asking.
		Pullback(\.ui.closeWindow) { state in
			Self.stopAsking(state.main.id, state: &state)
		}

		Pullback(\.ui.closeAdditionalWindow) { state, id in
			Self.stopAsking(id, state: &state)
		}
	}

	private struct CloseEffectID: Hashable { let windowID: UUID }

	private static func stopAsking(_ id: UUID, state: inout State) -> Effect<Action> {
		guard state.windowCloseRequests.removeValue(forKey: id) != nil else { return .none }

		return .cancel(id: CloseEffectID(windowID: id))
	}

	/// Closes the window as AppKit's close did before DEV-1107; the store's change closes the
	/// native window.
	private static func close(_ id: UUID, state: State) -> Effect<Action> {
		id == state.main.id ? .send(.ui(.closeWindow)) : .send(.ui(.closeAdditionalWindow(id)))
	}
}

extension AppFeature.State {
	/// The main window while it's open, or an additional window, when ordinary.
	fileprivate func openOrdinaryWindow(_ id: UUID) -> MainFeature.State? {
		let window = id == main.id ? (windowIsOpen ? main : nil) : windows[id: id]
		guard let window, !window.isPrivate else { return nil }

		return window
	}

	/// The loaded tabs closing this window would release (DEV-1104): those it holds that no other
	/// open window does, or every workspace tab when it's the last one, other than chats and tabs
	/// shown elsewhere, in Little Arx, another window's Peek or Page PiP; the Page PiP it owns
	/// counts as its own. What its panes show
	/// comes first, then the workspace's order.
	internal func tabsReleasedByClosing(_ id: UUID) -> [BrowserCore.Tab.ID] {
		let holds = windowHolds
		guard let closing = holds[id] else { return [] }

		let others = holds.filter { $0.key != id }.values
		var held = tabsHeld(by: [closing])

		// The Page PiP it owns, though it moved to another space since, as `noteWindowHolds` has.
		if let floating = pagePictureInPicture, floating.windowID == id { held.insert(floating.tabID) }
		var released = others.isEmpty ? Set(workspace.tabs.ids) : held.subtracting(tabsHeld(by: others))
		released.subtract(tabUnloading.unloaded)
		released.subtract(littleWindows.map(\.tab.id))
		released.subtract(peeks.filter { $0.source.windowID != id }.map(\.tab.id))
		if let floating = pagePictureInPicture, floating.windowID != id { released.remove(floating.tabID) }
		guard !released.isEmpty else { return [] }

		let ordered = workspace.tabs.filter { released.contains($0.id) && !$0.isChat }.map(\.id)
		let panes = ordered.filter { closing.panes.contains($0) }
		return panes + ordered.filter { !closing.panes.contains($0) }
	}
}
