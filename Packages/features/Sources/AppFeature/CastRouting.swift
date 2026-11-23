import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

extension AppFeature.State {
	/// The window a tab's picker goes on: the one that asked for it, else the window or Little
	/// Arx showing the tab. Nil when none does, or another tab's picker is up.
	internal func castPickerWindow(for tabID: BrowserCore.Tab.ID) -> UUID? {
		guard
			!shouldQuit,
			castPicker == nil || castPicker?.tabID == tabID || castPicker.map({ !castPickerWindowIsOpen($0.windowID) }) == true
		else { return nil }

		if let request = castPickerRequest, request.tabID == tabID, castPickerWindowIsOpen(request.windowID) {
			return request.windowID
		}
		for host in (windowIsOpen ? [main] : []) + Array(windows) where !host.isClosing {
			if host.viewer.panes.contains(where: { $0.item.tab?.id == tabID }) || host.viewer.item.tab?.id == tabID {
				return host.id
			}
		}
		return littleWindows.first { !$0.isClosing && $0.viewer.tab?.id == tabID }?.id
	}

	/// The window is open and not closing: the main window, another browser window or a Little Arx.
	internal func castPickerWindowIsOpen(_ id: UUID) -> Bool {
		if id == main.id { return windowIsOpen && !main.isClosing }
		if let window = windows[id: id] { return !window.isClosing }
		return littleWindows[id: id].map { !$0.isClosing } ?? false
	}

	/// The tab Cast… acts on in a window: its focused pane's, or Little Arx's. Never a chat.
	internal func castTab(for target: AppFeature.CommandTarget) -> (tabID: BrowserCore.Tab.ID, windowID: UUID)? {
		guard case let .window(id, paneID) = target else { return nil }

		if let little = littleWindows[id: id] {
			guard !little.isCommandOnly, let tab = little.viewer.tab, !tab.isChat else { return nil }
			return (tab.id, id)
		}
		guard let window = window(id) else { return nil }
		let pane = paneID ?? window.viewer.activePaneID
		guard let tab = window.viewer.panes[id: pane]?.item.tab ?? window.viewer.item.tab, !tab.isChat
		else { return nil }

		return (tab.id, id)
	}
}

/// Pages' Cast pickers reach their tab's window as a sheet (DEV-927).
@Reducer
internal struct CastRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.cast)
	private var cast

	internal var body: some ReducerOf<Self> {
		CombineReducers {
			Pullback(\.cast.observe) { state, menuTitle in
				state.castIsAvailable = MainActor.assumeIsolated { [cast] in cast.isAvailable() }
				guard state.castIsAvailable else { return .none }

				return .run { [cast] send in
					for await event in await cast.events(menuTitle) {
						await send(.cast(.changed(event)))
					}
				}
				.cancellable(id: Cancellation.observe, cancelInFlight: true)
			}

			Pullback(\.cast.open) { state, request in
				let (tabID, windowID) = request
				state.castPickerRequest = .init(tabID: tabID, windowID: windowID)
				let shown = MainActor.assumeIsolated { [cast] in cast.show(tabID) }
				if !shown { state.castPickerRequest = nil }
				return .none
			}

			Pullback(\.cast.changed) { state, event in
				guard let picker = event.picker else {
					// Casting started, the page navigated, or the picker was closed.
					if state.castPicker?.tabID == event.tabID { state.castPicker = nil }
					if state.castPickerRequest?.tabID == event.tabID { state.castPickerRequest = nil }
					return .none
				}
				if state.castPicker?.tabID == event.tabID {
					state.castPicker?.picker = picker
					return .none
				}
				guard let windowID = state.castPickerWindow(for: event.tabID) else {
					let tabID = event.tabID
					MainActor.assumeIsolated { [cast] in cast.close(tabID) }
					return .none
				}
				state.castPickerRequest = nil
				state.castPicker = .init(windowID: windowID, tabID: event.tabID, picker: picker)
				return .none
			}

			Pullback(\.castPicker.delegate.closed) { state in
				state.castPicker = nil
				return .none
			}

			// A window that closes takes its sheet without a Done: close the engine's picker too,
			// or a site's request would wait and other tabs' pickers be refused.
			Reduce { state, _ in
				guard let picker = state.castPicker, !state.castPickerWindowIsOpen(picker.windowID)
				else { return .none }

				state.castPicker = nil
				let tabID = picker.tabID
				return .run { [cast] _ in await cast.close(tabID) }
			}
		}
		.ifLet(\.castPicker, action: \.castPicker) { CastPicker() }
	}

	private enum Cancellation: Hashable {
		case observe
	}
}
