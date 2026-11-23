import AppUpdaterClient
import _ComposableArchitecture

/// The Updates section and Check for Updates…: follows Sparkle's state, checks when asked,
/// turns the automatic check and download switches into Sparkle settings, switches between the
/// Stable and Beta channels, and holds What's New after an update (DEV-888).
///
/// The updater only runs in a configured, signed release build. Everywhere else the first
/// status is unavailable, the section says why, and nothing here reaches Sparkle again.
@Reducer
internal struct SettingsUpdates {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.appUpdater)
	private var updater

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.startUpdates) { _ in
			.run { [updater] send in
				for await event in await updater.start() {
					switch event {
					case let .status(status):
						await send(.event(.updatesChanged(status)))

					case .quitRequested:
						await send(.delegate(.quitToInstallUpdate))

					case let .whatsNew(whatsNew):
						await send(.event(.whatsNewReady(whatsNew)))
					}
				}
			}
			.cancellable(id: Cancellation.updates, cancelInFlight: true)
		}

		Pullback(\.event.updatesChanged) { state, status in
			state.updates = status
			return .none
		}

		Pullback(\.event.whatsNewReady) { state, whatsNew in
			state.whatsNew = whatsNew
			return .none
		}

		Pullback(\.ui.dismissWhatsNew) { state in
			state.whatsNew = nil
			return .none
		}

		Pullback(\.ui.openReleaseNotes) { state in
			guard let whatsNew = state.whatsNew
			else { return .none }

			state.whatsNew = nil
			return .send(.delegate(.openReleaseNotes(whatsNew.fullNotesURL)))
		}

		Pullback(\.ui.updateChannel) { state, channel in

			// Never downgrades: the installed build stays until the channel has a newer one.
			guard
				state.updates?.isAvailable == true,
				state.updates?.offersBeta == true || channel == .stable,
				state.updates?.channel != channel
			else { return .none }

			state.updates?.channel = channel
			return .run { [updater] _ in
				await updater.setChannel(channel)
			}
		}

		Pullback(\.event.updateQuitCancelled) { _ in
			.run { [updater] _ in
				await updater.quitCancelled()
			}
		}

		Pullback(\.ui.installUpdate) { state in
			guard state.updates?.isReadyToInstall == true
			else { return .none }

			return .send(.delegate(.quitToInstallUpdate))
		}

		Pullback(\.ui.checkForUpdates) { state in
			guard state.updates?.canCheck == true
			else { return .none }

			return .run { [updater] _ in
				await updater.checkForUpdates()
			}
		}

		Pullback(\.ui.automaticallyChecksForUpdates) { state, isEnabled in
			guard
				state.updates?.isAvailable == true,
				state.updates?.automaticallyChecks != isEnabled
			else { return .none }

			state.updates?.automaticallyChecks = isEnabled
			return .run { [updater] _ in
				await updater.setAutomaticallyChecks(isEnabled)
			}
		}

		Pullback(\.ui.automaticallyDownloadsUpdates) { state, isEnabled in

			// Downloads only happen as part of automatic checks.
			guard
				state.updates?.isAvailable == true,
				state.updates?.automaticallyChecks == true,
				state.updates?.automaticallyDownloads != isEnabled
			else { return .none }

			state.updates?.automaticallyDownloads = isEnabled
			return .run { [updater] _ in
				await updater.setAutomaticallyDownloads(isEnabled)
			}
		}
	}

	private enum Cancellation: Hashable {
		case updates
	}
}
