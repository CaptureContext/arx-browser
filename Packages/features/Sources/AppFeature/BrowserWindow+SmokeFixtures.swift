import AppKit
import AppUI
import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPagePreviewClient
import BrowserPageWaitClient
import BrowserDownloadsClient
import BrowserSiteIconClient
import BrowserSurfaceClient
import BrowserHistoryClient
import HistoryDatabase
import PageTextIndexClient
import BrowserWorkspaceClient
import CoreServices.AE
import ChromiumBrowserEngine
import ChromiumEngine
import DownloadsFeature
import FairPlayBridge
import MainFeature
import MigrationAssistant
import MigrationAssistantFeature
import OnboardingFeature
import OSLog
import SettingsFeature
import SwiftUI
import TaskManagerFeature
import WebKitBrowserEngine
import WorkspaceSync
import _ComposableArchitecture

extension BrowserWindow {
	// MARK: - Smoke fixtures

	#if DEBUG
	internal func configureRoutingSmoke(_ fixture: RoutingSmokeFixture?) {
		routingSmoke = fixture.map(RoutingSmoke.init)
	}

	internal func configureRetirementSmoke(_ fixture: ProfileRetirementSmoke?) {
		retirementSmoke = fixture
	}

	internal func startRetirementSmoke() {
		guard let retirementSmoke else { return }
		Task { @MainActor [self] in
			do {
				try await retirementSmoke.run(store: store, engine: engine.client)
			} catch {
				failed = true
				FileHandle.standardError.write(Data("Arx retirement fixture failed: \(error)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}

	internal func configureExtensionSettingsSmoke(_ fixture: ExtensionSettingsSmokeFixture?) {
		extensionSettingsSmokeFixture = fixture
	}

	internal func startExtensionSettingsSmoke() {
		guard let fixture = extensionSettingsSmokeFixture else { return }
		extensionSettingsSmokeFixture = nil
		Task { @MainActor [self] in
			do {
				try await ExtensionSettingsSmoke.run(
					fixture: fixture,
					store: store,
					engine: engine
				) { [weak self] in
					self?.settingsWindow?.attachedSheet?.attachedSheet?.isVisible == true
				}
				store.send(.ui(.quit))
			} catch {
				failed = true
				let failure = error as? ExtensionSettingsSmokeFixture.Failure ?? .invalidFixture
				let message = "ARX_EXTENSION_SETTINGS_APP_FAILED: \(failure.rawValue)\n"
				FileHandle.standardError.write(Data(message.utf8))
				runtime.requestQuit()
			}
		}
	}

	internal func startDeveloperToolsSmoke() {
		guard
			environment["ARX_DEVTOOLS_SMOKE"] == "1",
			environment["ARX_ENGINE_PROFILE"] != nil
		else { return }

		Task { @MainActor [self] in
			do {
				try await DeveloperToolsSmoke.run(store: store, engine: engine, environment: environment)
			} catch {
				failed = true
				let failure = (error as? DeveloperToolsSmoke.Failure)?.rawValue ?? "\(error)"
				FileHandle.standardError.write(Data("ARX_DEVTOOLS_SMOKE_FAILED: \(failure)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}

	internal func startProfileReleaseSmoke() {
		guard
			ProfileReleaseSmoke.isRequested(environment: environment),
			environment["ARX_ENGINE_PROFILE"] != nil
		else { return }

		Task { @MainActor [self] in
			do {
				try await ProfileReleaseSmoke.run(store: store, engine: engine, environment: environment)
			} catch {
				failed = true
				let failure = (error as? ProfileReleaseSmoke.Failure)?.rawValue ?? "\(error)"
				FileHandle.standardError.write(Data("ARX_PROFILE_RELEASE_SMOKE_FAILED: \(failure)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}

	internal func startLocalFailureSmoke() {
		guard
			environment["ARX_LOCAL_FAILURE_SMOKE"] == "1",
			environment["ARX_ENGINE_PROFILE"] != nil
		else { return }

		Task { @MainActor [self] in
			do {
				try await LocalFailureSmoke.run(store: store, engine: engine, environment: environment)
			} catch {
				failed = true
				let failure = (error as? LocalFailureSmoke.Failure)?.rawValue ?? "\(error)"
				FileHandle.standardError.write(Data("ARX_LOCAL_FAILURE_SMOKE_FAILED: \(failure)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}

	internal func startTabUnloadSmoke() {
		guard
			environment["ARX_TAB_UNLOAD_SMOKE"] == "1",
			environment["ARX_ENGINE_PROFILE"] != nil
		else { return }

		Task { @MainActor [self] in
			do {
				try await TabUnloadSmoke.run(
					store: store,
					engine: engine,
					window: { [weak self] in self?.window },
					environment: environment
				)
			} catch {
				failed = true
				let failure = (error as? TabUnloadSmoke.Failure)?.rawValue ?? "\(error)"
				FileHandle.standardError.write(Data("ARX_TAB_UNLOAD_SMOKE_FAILED: \(failure)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}

	internal func startSignInSmoke() {
		let smoke: SignInSmoke?
		do {
			smoke = try SignInSmoke.start(
				store: store,
				engine: engine,
				window: { [weak self] in self?.window },
				environment: environment
			)
		} catch {
			failed = true
			FileHandle.standardError.write(Data("ARX_SIGN_IN_SMOKE_FAILED: invalidFixture\n".utf8))
			store.send(.ui(.quit))
			return
		}
		guard let smoke else { return }

		Task { @MainActor [self] in
			do {
				try await smoke.run()
			} catch {
				failed = true
			}
			store.send(.ui(.quit))
		}
	}

	internal func startLittleArxSpaceSmoke() {
		guard headless == nil, LittleArxSpaceSmoke.isRequested(environment: environment) else { return }

		let smoke = LittleArxSpaceSmoke(environment: environment)
		littleArxSpaceSmoke = smoke
		Task { @MainActor [self] in
			do {
				try await smoke.run(
					store: store,
					mainWindow: { [weak self] in self?.window },
					panel: { [weak self] id in self?.littleWindows[id] },
					render: { [weak self] in self?.render() }
				)
			} catch {
				failed = true
				let failure = (error as? LittleArxSpaceSmoke.Failure)?.rawValue ?? "\(error)"
				FileHandle.standardError.write(Data("ARX_LITTLE_ARX_SPACE_SMOKE_FAILED: \(failure)\n".utf8))
			}
			store.send(.ui(.quit))
		}
	}

	internal func startRoutingSmoke() {
		guard let routingSmoke else { return }
		Task { [self] in
			do {
				try await routingSmoke.run(store: store, engine: engine.client)
			} catch {
				failed = true
				let reason = (error as? RoutingSmokeFixture.Failure)?.rawValue ?? "fixtureError"
				do {
					try routingSmoke.writeResult(status: reason)
				} catch {
					FileHandle.standardError.write(Data("Routing smoke result failed\n".utf8))
				}
			}
			store.send(.ui(.quit))
		}
	}
	#endif
}
