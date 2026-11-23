#if DEBUG
import AppKit
import Foundation

extension BrowserWindow {
	/// `make hand-check-smoke`: the phases `ARX_HAND_CHECK_SMOKE` names, on the launch page
	/// `ARX_ENGINE_URL`, then quits. See `HandCheckSmoke`.
	internal func startHandCheckSmoke() {
		guard
			headless == nil,
			environment["ARX_ENGINE_PROFILE"] != nil,
			let phases = HandCheckSmoke.phases(environment: environment)
		else {
			if environment[HandCheckSmoke.environmentKey] != nil {
				failed = true
				FileHandle.standardError.write(Data("ARX_HAND_CHECK_SMOKE_FAILED: setup: unknown phase or no disposable profile\n".utf8))
				store.send(.ui(.quit))
			}
			return
		}

		Task { @MainActor [self] in
			var current = "setup"
			do {
				guard let baseURL = environment["ARX_ENGINE_URL"].flatMap(URL.init(string:))
				else { throw HandCheckSmoke.Failure("ARX_ENGINE_URL is missing") }

				try await HandCheckSmoke.wait("main window and launch page", seconds: 60) {
					guard let window = self.window, window.isVisible else { return false }
					let navigation = store.main.viewer.item.navigation
					return navigation.url == baseURL && !navigation.isLoading
				}
				NSApp.activate()
				for phase in phases {
					current = phase.rawValue
					guard let window else { throw HandCheckSmoke.Failure("the main window closed") }
					try await HandCheckSmoke.wait("window key", context: { "active=\(NSApp.isActive)" }) {
						window.makeKeyAndOrderFront(nil)
						return window.isKeyWindow
					}
					switch phase {
					case .find:
						try await FindFocusSmoke.run(store: store, engine: engine, window: window, baseURL: baseURL)

					case .fullScreen:
						try await WindowFullScreenSmoke.run(store: store, engine: engine, window: window)

					case .address:
						try await AddressFieldSmoke.run(store: store, window: window, baseURL: baseURL)

					case .privateSave:
						try await PrivateSaveSmoke.run(store: store, engine: engine, baseURL: baseURL, environment: environment)

					case .hideElementToast:
						try await HideElementToastSmoke.run(store: store, engine: engine, window: window, baseURL: baseURL)
					}
				}
				print("ARX_HAND_CHECK_SMOKE_SUCCESS")
			} catch {
				failed = true
				FileHandle.standardError.write(Data("ARX_HAND_CHECK_SMOKE_FAILED: \(current): \(error)\n".utf8))
			}
			fflush(stdout)
			store.send(.ui(.quit))
		}
	}
}
#endif
