import AppKit
import ChromiumEngine

@main
private enum ChromiumHost {
	@MainActor
	internal static func main() {
		#if DEBUG
		ChromiumRuntime.reportBootstrapEntryForSmoke()
		#endif
		guard ChromiumRuntime.prepareHostAllocator() else { exit(1) }
		do {
			let bundle = Bundle.main
			guard
				let executable = bundle.executableURL,
				let frameworks = bundle.privateFrameworksURL,
				let profilePath = ProcessInfo.processInfo.environment["ARX_ENGINE_PROFILE"]
			else { throw HostError.missingConfiguration }
			let extensionFixture = CommandLine.arguments.last == ExtensionSmoke.argument
			let extensionInstallFixture = CommandLine.arguments.last == ExtensionInstallSmoke.argument
			let webstoreInstallFixture = CommandLine.arguments.last == WebstoreInstallSmoke.argument
			let closeFixture = CommandLine.arguments.last == CloseSmoke.argument
			let hangFixture = CommandLine.arguments.last == HangSmoke.argument
			let inspectionFixture = CommandLine.arguments.last == InspectionSmoke.argument
			let referenceClickFixture = CommandLine.arguments.last == ReferenceClickSmoke.argument
			let documentCaptureFixture = CommandLine.arguments.last == DocumentCaptureSmoke.argument
			let linkContextFixture = CommandLine.arguments.last == LinkContextSmoke.argument
			let focusedLinkFixture = CommandLine.arguments.last == FocusedLinkSmoke.argument
			let backForwardCacheFixture = CommandLine.arguments.last == BackForwardCacheSmoke.argument
			let crossSiteLinkFixture = CommandLine.arguments.last == CrossSiteLinkSmoke.argument
			let siteSettingsFixture = CommandLine.arguments.last == SiteSettingsSmoke.argument
			let browsingDataFixture = CommandLine.arguments.last == BrowsingDataSmoke.argument
			let gestureFixture = CommandLine.arguments.last == GestureSmoke.argument
			let referenceScrollFixture = CommandLine.arguments.last == ReferenceScrollSmoke.argument
			let referenceFormFixture = CommandLine.arguments.last == ReferenceFormSmoke.argument
			let referenceKeypressFixture = CommandLine.arguments.last == ReferenceKeypressSmoke.argument
			let passwordFixture = CommandLine.arguments.last == PasswordSmoke.argument
			let backgroundVisibilityFixture = CommandLine.arguments.last == BackgroundVisibilitySmoke.argument
			let isSpecializedFixture = extensionFixture
			|| closeFixture
			|| hangFixture
			|| inspectionFixture
			|| referenceClickFixture
			|| referenceFormFixture
			|| referenceScrollFixture
			|| linkContextFixture
			|| focusedLinkFixture
			|| backForwardCacheFixture
			|| crossSiteLinkFixture
			|| siteSettingsFixture
			|| browsingDataFixture
			|| documentCaptureFixture
			|| gestureFixture
			|| referenceKeypressFixture
			|| extensionInstallFixture
			|| webstoreInstallFixture
			|| passwordFixture
			|| backgroundVisibilityFixture
			let fixtureArguments = isSpecializedFixture
			? Array(CommandLine.arguments.dropLast())
			: CommandLine.arguments
			let smoke = try HostSmokeConfiguration.resolve(
				arguments: fixtureArguments,
				environment: ProcessInfo.processInfo.environment,
				workDirectory: bundle.bundleURL.deletingLastPathComponent()
			)

			let runtime = try ChromiumRuntime(
				frameworkExecutable: frameworks.appending(path: "Arx Framework.framework/Arx Framework")
			)

			// Scripts/engine/smoke.py turns content blocking (Helium's uBlock Origin, DEV-884)
			// off for smokes that don't test it, before any profile shows a page: on a fresh
			// profile uBlock reloads itself once and fetches lists, which those smokes would race.
			if ProcessInfo.processInfo.environment["ARX_ENGINE_CONTENT_BLOCKING"] == "0" {
				runtime.setContentBlocking(enabled: false, blockCookieBanners: false)
			}

			if documentCaptureFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = DocumentCaptureSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true,
					documentCaptureFixtureForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_DOCUMENT_CAPTURE_SMOKE_SUCCESS")
				exit(result)
			}

			if gestureFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = GestureSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true,
					gestureFixtureForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }

				print("ARX_GESTURE_SMOKE_SUCCESS")
				exit(result)
			}

			if backgroundVisibilityFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = BackgroundVisibilitySmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }

				print("ARX_BACKGROUND_VISIBILITY_SMOKE_SUCCESS")
				exit(result)
			}

			if extensionInstallFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = ExtensionInstallSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true,
					extensionInstallFixtureForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_EXTENSION_INSTALL_SMOKE_SUCCESS")
				exit(result)
			}

			if webstoreInstallFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL),
					let port = url.port,
					let origin = URL(string: "http://127.0.0.1:\(port)")
				else { throw HostError.missingConfiguration }
				let fixture = WebstoreInstallSmoke(runtime: runtime, origin: origin)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true,
					extensionInstallFixtureForTesting: true,
					webstoreFixtureOriginForTesting: origin
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_WEBSTORE_INSTALL_SMOKE_SUCCESS")
				exit(result)
			}

			if passwordFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL),
					let probe = ProcessInfo.processInfo.environment["ARX_PASSWORD_PROBE"]
				else { throw HostError.missingConfiguration }
				let fixture = try PasswordSmoke(runtime: runtime, url: url, probe: probe)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_PASSWORD_SMOKE_SUCCESS")
				exit(result)
			}

			if linkContextFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = LinkContextSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_LINK_CONTEXT_SMOKE_SUCCESS")
				exit(result)
			}

			if browsingDataFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				// A folder of the smoke's own, beside its disposable profile.
				let folder = smoke.profileDirectory.deletingLastPathComponent().appending(path: "downloads-fixture")
				try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
				let fixture = BrowsingDataSmoke(runtime: runtime, url: url, folder: folder)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_BROWSING_DATA_SMOKE_SUCCESS")
				exit(result)
			}

			if siteSettingsFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = SiteSettingsSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_SITE_SETTINGS_SMOKE_SUCCESS")
				exit(result)
			}

			if crossSiteLinkFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = CrossSiteLinkSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_CROSS_SITE_LINK_SMOKE_SUCCESS")
				exit(result)
			}

			if focusedLinkFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = FocusedLinkSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_FOCUSED_LINK_SMOKE_SUCCESS")
				exit(result)
			}

			if backForwardCacheFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = BackForwardCacheSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_BACK_FORWARD_CACHE_SMOKE_SUCCESS")
				exit(result)
			}

			if referenceScrollFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = try ReferenceScrollSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }

				print("ARX_REFERENCE_SCROLL_SMOKE_SUCCESS")
				exit(result)
			}

			if referenceKeypressFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = try ReferenceKeypressSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_REFERENCE_KEYPRESS_SMOKE_SUCCESS")
				exit(result)
			}

			if referenceFormFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = try ReferenceFormSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }

				print("ARX_REFERENCE_FORM_SMOKE_SUCCESS")
				exit(result)
			}

			if referenceClickFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = try ReferenceClickSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }

				print("ARX_REFERENCE_CLICK_SMOKE_SUCCESS")
				exit(result)
			}

			if inspectionFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = try InspectionSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }

				print("ARX_INSPECTION_SMOKE_SUCCESS")
				exit(result)
			}

			if hangFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = HangSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_HANG_SMOKE_SUCCESS")
				exit(result)
			}

			if closeFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }

				let fixture = CloseSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_CLOSE_SMOKE_SUCCESS")
				exit(result)
			}

			if extensionFixture {
				guard
					let smoke,
					let rawURL = ProcessInfo.processInfo.environment["ARX_ENGINE_URL"],
					let url = URL(string: rawURL)
				else { throw HostError.missingConfiguration }
				let fixture = ExtensionSmoke(runtime: runtime, url: url)
				let result = try runtime.run(
					executable: executable,
					profileDirectory: smoke.profileDirectory,
					mockKeychainForTesting: true,
					extensionFixtureForTesting: true
				) { _ in fixture.open() }
				guard fixture.verified, result == 0 else { exit(1) }
				print("ARX_EXTENSION_SMOKE_SUCCESS")
				exit(result)
			}
			let host = WindowHost(runtime: runtime)
			let result = try runtime.run(
				executable: executable,
				profileDirectory: smoke?.profileDirectory ?? URL(filePath: profilePath),
				mockKeychainForTesting: smoke != nil
			) { _ in host.open() }
			if host.failed { exit(1) }
			if ProcessInfo.processInfo.environment["ARX_ENGINE_SMOKE_TITLE"] != nil {
				guard host.verified, result == 0 else {
					diagnostic("ARX_ENGINE_SMOKE_FAILED: runtime returned without a verified fixture")
					exit(1)
				}
				print("ARX_ENGINE_SMOKE_SUCCESS")
			}
			exit(result)
		} catch {
			FileHandle.standardError.write(Data("Engine host: \(error)\n".utf8))
			exit(1)
		}
	}

	private enum HostError: Error {
		case missingConfiguration
	}
}

@MainActor
private final class WindowHost: NSObject, NSWindowDelegate {
	private let runtime: ChromiumRuntime
	private var window: NSWindow?
	private var page: ChromiumPage?
	internal private(set) var verified: Bool = false
	internal private(set) var failed: Bool = false

	internal init(runtime: ChromiumRuntime) {
		self.runtime = runtime
		super.init()
	}

	internal func open() {
		diagnostic("ARX_ENGINE_HOST_READY")
		do {
			let page = try runtime.makePage()
			self.page = page
			diagnostic("ARX_ENGINE_HOST_PAGE_CREATED")
			let window = NSWindow(
				contentRect: .init(
					x: 0,
					y: 0,
					width: 1000,
					height: 700
				),
				styleMask: [.titled, .closable, .resizable, .miniaturizable],
				backing: .buffered,
				defer: false
			)
			self.window = window
			window.isReleasedWhenClosed = false
			window.delegate = self
			window.contentView = page.view
			window.title = "Arx engine host"
			window.center()
			window.makeKeyAndOrderFront(nil)
			NSApplication.shared.setActivationPolicy(.regular)
			NSApplication.shared.activate(ignoringOtherApps: true)

			let environment = ProcessInfo.processInfo.environment
			if let expectedTitle = environment["ARX_ENGINE_SMOKE_TITLE"] {
				var isFinding = false
				page.onNavigation = { [weak self, weak page] navigation in
					guard let self, let page, !self.verified else { return }
					if isFinding {
						guard
							let result = navigation.findResult,
							result.matches == 1,
							result.active == 1
						else { return }
						do {
							try page.stopFind()
						} catch {
							self.fail("stopping find: \(error)")
							return
						}
						self.verified = true
						diagnostic("ARX_ENGINE_SMOKE_FIND_VERIFIED")
						self.finish()
						return
					}
					let titleMatches = navigation.title == expectedTitle
					let error = navigation.errorCode.map(String.init) ?? "none"
					diagnostic(
						"ARX_ENGINE_SMOKE_NAVIGATION loading=\(navigation.isLoading) titleMatches=\(titleMatches) error=\(error)"
					)
					guard navigation.title == expectedTitle, !navigation.isLoading else { return }
					guard
						page.view.window != nil,
						page.view.bounds.width > 0,
						page.view.bounds.height > 0
					else { return }
					diagnostic("ARX_ENGINE_SMOKE_LOAD_VERIFIED")
					isFinding = true
					do {
						try page.find("Chromium", forward: true, newSession: true)
					} catch {
						self.fail("starting find: \(error)")
					}
				}
				DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
					guard let self, !self.verified else { return }
					self.failed = true
					diagnostic("ARX_ENGINE_SMOKE_FAILED: fixture did not load within 30 seconds")
					self.finish()
				}
			}
			if let rawURL = environment["ARX_ENGINE_URL"], let url = URL(string: rawURL) {
				diagnostic("ARX_ENGINE_HOST_NAVIGATE")
				try page.navigate(to: url)
			}
		} catch {
			failed = true
			FileHandle.standardError.write(Data("Engine window: \(error)\n".utf8))
			finish()
		}
	}

	internal func windowWillClose(_ notification: Notification) {
		finish()
	}

	/// Fails the engine smoke now, rather than at its timeout.
	private func fail(_ reason: String) {
		failed = true
		diagnostic("ARX_ENGINE_SMOKE_FAILED: \(reason)")
		finish()
	}

	private func finish() {
		page?.close()
		page = nil
		window?.orderOut(nil)
		diagnostic("ARX_ENGINE_HOST_QUIT_REQUESTED")
		runtime.requestQuit()
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
