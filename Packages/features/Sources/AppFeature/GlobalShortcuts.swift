import AppUI
import BrowserCore
import _ComposableArchitecture

@Reducer
internal struct GlobalShortcuts {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.globalShortcut)
	private var client

	private enum Cancellation: Hashable {
		/// Every registration, cancelled before a newer one starts.
		case registration

		/// One registration generation, so a stale one can be stopped without touching a newer one.
		case generation(Int)
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.event.routingReady) { state in
			state.settings.linkClicks.globalLittleArxEnabled ? .send(.configureGlobalShortcut) : .none
		}

		Pullback(\.settings.ui.recordKeyboardShortcut) { state, _ in
			state.settings.linkClicks.globalLittleArxEnabled ? .send(.configureGlobalShortcut) : .none
		}

		// Add Shortcut records too, so the global hotkey steps aside for it (DEV-920).
		Pullback(\.settings.ui.addKeyboardShortcut) { state, _ in
			state.settings.linkClicks.globalLittleArxEnabled ? .send(.configureGlobalShortcut) : .none
		}

		Pullback(\.settings.ui.categorySelected) { state, _ in
			state.settings.linkClicks.globalLittleArxEnabled ? .send(.configureGlobalShortcut) : .none
		}

		Pullback(\.ui.closeSettings) { state in
			state.settings.linkClicks.globalLittleArxEnabled ? .send(.configureGlobalShortcut) : .none
		}

		Pullback(\.configureGlobalShortcut) { state in
			let isActive = state.settings.linkClicks.globalLittleArxEnabled && state.settings.recordingCommand == nil
			let binding = isActive ? state.settings.keyboardShortcuts.shortcut(for: .littleArx) : nil
			if isActive, binding == nil {
				state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutNeedsBinding)
			} else if binding == nil {
				state.settings.globalShortcutMessage = nil
			}
			guard binding != state.globalShortcutBinding else { return .none }
			state.globalShortcutBinding = binding
			state.globalShortcutGeneration += 1
			guard let binding else { return .cancel(id: Cancellation.registration) }
			state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutRegistering)
			let generation = state.globalShortcutGeneration
			let registration: Effect<Action> = .run { @MainActor [client] send in

				// Both cancellation IDs are registered by now. Report in and start in one main-actor
				// turn: the native registration is a single slot, so a stale start would replace it.
				send(.event(.globalShortcutStarted(generation)))
				guard !Task.isCancelled else { return }

				for await event in client.events(binding) {
					try Task.checkCancellation()
					send(.event(.globalShortcut(generation, event)))
				}
			}
			.cancellable(id: Cancellation.generation(generation))
			.cancellable(id: Cancellation.registration)

			// `cancelInFlight` cancels when the effect's task registers, which happens off the
			// main actor, so an older registration could cancel this one and keep the old binding.
			// Cancel synchronously in reducer order; one that registers later is stopped when it
			// reports in, before it reaches the native client.
			return .concatenate(.cancel(id: Cancellation.registration), registration)
		}

		Pullback(\.event.globalShortcutStarted) { state, generation in
			guard generation == state.globalShortcutGeneration
			else { return .cancel(id: Cancellation.generation(generation)) }

			return .none
		}

		Pullback(\.event.globalShortcut) { state, value in
			let (generation, event) = value
			guard
				generation == state.globalShortcutGeneration,
				state.globalShortcutBinding != nil,
				state.settings.linkClicks.globalLittleArxEnabled,
				!state.shouldQuit
			else { return .none }

			switch event {
			case .registered:
				state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutRegistered)
				return .none

			case .unavailableLayout:
				state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutLayout)
				return .none

			case .taken:
				state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutTaken)
				return .none

			case let .failed(code):
				state.settings.globalShortcutMessage = String.localized(.appUI.settings.globalShortcutFailed(Int(code)))
				return .none

			case .pressed:
				guard state.settings.recordingCommand == nil else { return .none }

				var target: AppFeature.CommandTarget = .application
				if let id = state.focusedWindowID {
					let focusedTarget = state.commandTarget(in: id)
					if state.commandContext(for: focusedTarget) != nil { target = focusedTarget }
				}
				return .send(.ui(.command(.littleArx, target)))
			}
		}
	}
}

extension Reducer where State == AppFeature.State, Action == AppFeature.Action {
	/// Registers the global Little Arx shortcut again when it's switched on or off or its binding
	/// changes, whichever reducer changed it.
	internal func reconfiguringGlobalShortcut() -> some Reducer<State, Action> {
		onChange(of: \.globalShortcutPreference) { _, state in
			let needsConfiguration = state.settings.linkClicks.globalLittleArxEnabled
			|| state.globalShortcutBinding != nil
			|| state.settings.globalShortcutMessage != nil

			return needsConfiguration ? .send(.configureGlobalShortcut) : .none
		}
	}
}

extension AppFeature.State {
	fileprivate struct GlobalShortcutPreference: Equatable {
		internal let isEnabled: Bool
		internal let binding: BrowserCore.KeyboardShortcut?
	}

	fileprivate var globalShortcutPreference: GlobalShortcutPreference {
		.init(
			isEnabled: settings.linkClicks.globalLittleArxEnabled,
			binding: settings.keyboardShortcuts.shortcut(for: .littleArx)
		)
	}
}
