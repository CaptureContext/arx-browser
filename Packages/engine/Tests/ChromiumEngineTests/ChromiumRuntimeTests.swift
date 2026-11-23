import AppKit
import ChromiumBridge
import CustomDump
import Testing

@testable import ChromiumEngine

@Suite(.serialized)
@MainActor
internal struct ChromiumRuntimeTests {
	/// A page from the fixture runtime. `onReady` can't throw, so a failure is recorded rather
	/// than letting the test pass without its page.
	private static func makePage(in runtime: ChromiumRuntime) -> ChromiumPage? {
		do {
			return try runtime.makePage()
		} catch {
			Issue.record(error)
			return nil
		}
	}

	@Test(arguments: 0..<3)
	internal func disposableFixtureCannotAdoptRetirementIdentity(_ mode: Int) {
		var api = Fixture.api
		api.run_with_profile_retirement = { _, _, _, _, _, _ in
			Issue.record("A disposable fixture reached retirement startup")
			return 1
		}
		let runtime = ChromiumRuntime(api: api)
		let identity = ChromiumProfileRetirementConfiguration(
			installationID: UUID(),
			legacyProfileID: UUID()
		)

		#expect(throws: ChromiumProfileRetirementFailure.invalid) {
			try runtime.run(
				executable: Fixture.executable,
				profileDirectory: Fixture.profile,
				mockKeychainForTesting: true,
				extensionFixtureForTesting: mode == 0,
				profileRetirement: identity,
				documentCaptureFixtureForTesting: mode == 1,
				gestureFixtureForTesting: mode == 2
			) { _ in
				Issue.record("A refused fixture became ready")
			}
		}
	}

	@Test(arguments: 0..<3)
	internal func disposableFixturesCannotBeCombined(_ omittedMode: Int) {
		var api = Fixture.api
		api.run_with_options = { _, _, _, _ in
			Issue.record("Mixed fixture modes reached native startup")
			return 1
		}
		let runtime = ChromiumRuntime(api: api)

		#expect(throws: ChromiumError.invalidFixture) {
			try runtime.run(
				executable: Fixture.executable,
				profileDirectory: Fixture.profile,
				mockKeychainForTesting: true,
				extensionFixtureForTesting: omittedMode != 0,
				documentCaptureFixtureForTesting: omittedMode != 1,
				gestureFixtureForTesting: omittedMode != 2
			) { _ in
				Issue.record("Mixed fixture modes became ready")
			}
		}
	}

	@Test(arguments: 0..<5)
	internal func inspectionRequiresEveryFunctionTableEntry(_ missing: Int) {
		var api = Fixture.api
		switch missing {
		case 0: api.inspect_page = nil
		case 1: api.validate_inspection_reference = nil
		case 2: api.cancel_inspection = nil
		case 3: api.revoke_inspection_scope = nil
		default: api.inspection_document_is_current = nil
		}

		#expect(throws: ChromiumError.incompatibleBridge) {
			try ChromiumFramework.validated(api)
		}
		#expect(!ChromiumRuntime(api: api).supportsInspection)
	}

	@Test(arguments: [true, false])
	internal func referenceClickRequiresBothFunctionTableEntries(_ removeClick: Bool) {
		var api = Fixture.api
		if removeClick {
			api.click_inspection_reference = nil
		} else {
			api.cancel_reference_click = nil
		}
		#expect(throws: ChromiumError.incompatibleBridge) {
			try ChromiumFramework.validated(api)
		}
		#expect(!ChromiumRuntime(api: api).supportsReferenceClick)
	}

	@Test(arguments: [true, false])
	internal func referenceFormsRequireBothFunctionTableEntries(_ removePerform: Bool) async throws {
		var api = Fixture.api
		if removePerform {
			api.perform_inspection_form_action = nil
		} else {
			api.cancel_reference_form_action = nil
		}
		#expect(throws: ChromiumError.incompatibleBridge) {
			try ChromiumFramework.validated(api)
		}
		#expect(!ChromiumRuntime(api: api).supportsReferenceFormActions)
	}

	@Test(arguments: [true, false])
	internal func referenceScrollRequiresBothFunctionTableEntries(_ removePerform: Bool) async throws {
		var api = Fixture.api
		if removePerform {
			api.scroll_inspection_reference = nil
		} else {
			api.cancel_reference_click = nil
		}
		#expect(throws: ChromiumError.incompatibleBridge) {
			try ChromiumFramework.validated(api)
		}
		#expect(!ChromiumRuntime(api: api).supportsReferenceScroll)
	}

	@Test
	internal func referenceFormCapabilityIsIndependentOfReadiness() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		#expect(runtime.supportsReferenceFormActions)
		runtime.didBecomeReady()
		#expect(runtime.supportsReferenceFormActions)
		runtime.finish()
		#expect(runtime.supportsReferenceFormActions)
	}

	@Test
	internal func referenceClickCapabilityIsIndependentOfReadiness() {
		let runtime = ChromiumRuntime(api: Fixture.api)
		#expect(runtime.supportsReferenceClick)
		runtime.didBecomeReady()
		#expect(runtime.supportsReferenceClick)
		runtime.finish()
		#expect(runtime.supportsReferenceClick)
	}

	@Test
	internal func inspectionCapabilityIsStableAcrossRuntimeReadiness() {
		let runtime = ChromiumRuntime(api: Fixture.api)
		#expect(runtime.supportsInspection)
		runtime.didBecomeReady()
		#expect(runtime.supportsInspection)
		runtime.finish()
		#expect(runtime.supportsInspection)
	}

	@Test
	internal func mockKeychainRequiresExplicitRunOption() throws {
		var api = Fixture.api
		api.run_with_options = { _, _, callbacks, options in
			#expect(options?.pointee.use_mock_keychain_for_testing == true)
			return 17
		}
		let normal = ChromiumRuntime(api: api)
		#expect(try normal.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { _ in } == 0)
		let mock = ChromiumRuntime(api: api)
		let mockStatus = try mock.run(
			executable: Fixture.executable,
			profileDirectory: Fixture.profile,
			mockKeychainForTesting: true
		) { _ in }
		#expect(mockStatus == 17)
		api.run_with_options = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		let missing = ChromiumRuntime(api: api)
		#expect(throws: ChromiumError.incompatibleBridge) {
			try missing.run(
				executable: Fixture.executable,
				profileDirectory: Fixture.profile,
				mockKeychainForTesting: true
			) { _ in }
		}
	}

	@Test
	internal func gestureFixtureRequiresExplicitOwnedMockMode() throws {
		var api = Fixture.api
		api.run_with_options = { _, _, _, options in
			#expect(options?.pointee.use_mock_keychain_for_testing == true)
			#expect(options?.pointee.gesture_fixture_for_testing == true)
			return 29
		}
		let refused = ChromiumRuntime(api: api)
		#expect(throws: ChromiumError.invalidFixture) {
			try refused.run(
				executable: Fixture.executable,
				profileDirectory: Fixture.profile,
				gestureFixtureForTesting: true
			) { _ in }
		}

		let fixture = ChromiumRuntime(api: api)
		let status = try fixture.run(
			executable: Fixture.executable,
			profileDirectory: Fixture.profile,
			mockKeychainForTesting: true,
			gestureFixtureForTesting: true
		) { _ in }
		#expect(status == 29)

		let mixed = ChromiumRuntime(api: api)
		#expect(throws: ChromiumError.invalidFixture) {
			try mixed.run(
				executable: Fixture.executable,
				profileDirectory: Fixture.profile,
				mockKeychainForTesting: true,
				extensionFixtureForTesting: true,
				gestureFixtureForTesting: true
			) { _ in }
		}
	}

	@Test
	internal func ordinaryRuntimeCannotInjectGestureFixtureInput() async throws {
		Fixture.gestureCalls = 0
		var api = Fixture.api
		api.run_gesture_fixture = { _, _, _ in
			MainActor.assumeIsolated { Fixture.gestureCalls += 1 }
		}
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		let page = try runtime.makePage()
		let accepted = await runtime.runGestureFixture(
			on: page,
			loopbackOrigin: URL(string: "http://127.0.0.1:1234/")!
		)
		#expect(!accepted)
		#expect(Fixture.gestureCalls == 0)
		runtime.finish()
	}

	@Test
	internal func extensionStartupIsExplicitAndFixtureRequiresMockKeychain() throws {
		var api = Fixture.api
		api.run_with_options = { _, _, _, options in
			#expect(options?.pointee.use_mock_keychain_for_testing == true)
			#expect(options?.pointee.enable_extensions == false)
			#expect(options?.pointee.extension_fixture_for_testing == true)
			return 23
		}
		let ordinary = ChromiumRuntime(api: api)
		let ordinaryStatus = try ordinary.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
			#expect(!runtime.supportsExtensions)
		}
		#expect(ordinaryStatus == 0)
		let refused = ChromiumRuntime(api: api)
		#expect(throws: ChromiumExtensionFailure.invalidRequest) {
			try refused.run(
				executable: Fixture.executable,
				profileDirectory: Fixture.profile,
				extensionFixtureForTesting: true
			) { _ in }
		}
		let fixture = ChromiumRuntime(api: api)
		let fixtureStatus = try fixture.run(
			executable: Fixture.executable,
			profileDirectory: Fixture.profile,
			mockKeychainForTesting: true,
			extensionFixtureForTesting: true
		) { _ in }
		#expect(fixtureStatus == 23)
		#expect(!fixture.supportsExtensions)
	}

	@Test
	internal func rejectsIncompleteExtensionFunctionTable() throws {
		var api = Fixture.api
		api.inspect_extensions = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		api = Fixture.api
		api.manage_extension = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		api = Fixture.api
		api.cancel_extension_request = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		api = Fixture.api
		api.load_extension_fixture = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
	}

	@Test
	internal func rejectsIncompleteAuthorizedCloseTable() {
		var api = Fixture.api
		api.page_close_generation = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		api = Fixture.api
		api.request_authorized_close = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		api = Fixture.api
		api.consume_authorized_close = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
		api = Fixture.api
		api.cancel_authorized_close = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
	}

	@Test
	internal func rejectsMissingSynchronousMediaValidation() async throws {
		var api = Fixture.api
		api.media_source_is_current = nil
		#expect(throws: ChromiumError.incompatibleBridge) { try ChromiumFramework.validated(api) }
	}

	@Test
	internal func mediaValidationReadsNativeGenerationBeforeQueuedChanges() async throws {
		var api = Fixture.api
		api.media_source_is_current = { page, generation in
			MainActor.assumeIsolated {
				Fixture.mediaQueries += 1
				return page == 1 && generation == Fixture.mediaGeneration && Fixture.mediaPresent
			}
		}
		let runtime = ChromiumRuntime(api: api)
		var page: ChromiumPage?
		var failure: (any Error)?
		_ = try runtime.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
			do {
				let current = try runtime.makePage()
				page = current
				try runtime.observeMedia(current)
				Fixture.mediaQueries = 0
				Fixture.mediaGeneration = 4
				Fixture.mediaPresent = true
				var snapshot = ArxMediaSnapshot(
					generation: 4,
					revision: 1,
					present: true,
					video: true,
					picture: false,
					playback: 1,
					actions: UInt32(ARX_MEDIA_CAN_PAUSE),
					title: nil,
					origin: nil,
					artist: nil,
					artwork: nil,
					artwork_size: 0,
					call: false,
					microphone: ARX_MEDIA_DEVICE_UNKNOWN,
					camera: ARX_MEDIA_DEVICE_UNKNOWN
				)
				Fixture.callbacks?.media_changed(Fixture.callbacks?.context, 1, &snapshot)
				#expect(runtime.isMediaSourceCurrent(current, generation: 4))
				// Native invalidation happens first. No updated Swift callback is delivered.
				Fixture.mediaGeneration = 5
				#expect(!runtime.isMediaSourceCurrent(current, generation: 4))
				// Even a delayed callback from the old generation cannot restore authority.
				Fixture.callbacks?.media_changed(Fixture.callbacks?.context, 1, &snapshot)
				#expect(!runtime.isMediaSourceCurrent(current, generation: 4))
				Fixture.mediaPresent = false
				#expect(!runtime.isMediaSourceCurrent(current, generation: 5))
				let queries = Fixture.mediaQueries
				let foreign = ChromiumPage(id: 1, view: Fixture.view, runtime: runtime, isPrivate: false)
				#expect(!runtime.isMediaSourceCurrent(foreign, generation: 5))
				#expect(!runtime.isMediaSourceCurrent(current, generation: 0))
				current.close()
				#expect(!runtime.isMediaSourceCurrent(current, generation: 5))
				expectNoDifference(Fixture.mediaQueries, queries)
			} catch { failure = error }
		}
		#expect(failure == nil)
		#expect(!runtime.isMediaSourceCurrent(try #require(page), generation: 5))
	}

	@Test
	internal func privateMediaValidationNeverCallsNative() async throws {
		var api = Fixture.api
		api.media_source_is_current = { _, _ in
			Issue.record("Private media query must not reach native code")
			return true
		}
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }
		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		let page = try await runtime.makePage(profile: profile)
		#expect(page.isPrivate)
		#expect(!runtime.isMediaSourceCurrent(page, generation: 1))
	}

	@Test
	internal func rejectsMissingFramework() async throws {
		#expect(throws: ChromiumError.frameworkMissing("/does-not-exist/Arx Framework")) {
			try ChromiumRuntime(frameworkExecutable: URL(filePath: "/does-not-exist/Arx Framework"))
		}
	}

	@Test
	internal func refusesLoadingBeforeHostAllocatorPreparation() throws {
		let file = URL.temporaryDirectory.appending(path: "arx-loader-test-" + UUID().uuidString)
		try Data().write(to: file)

		// Best-effort cleanup of a temporary file.
		defer { try? FileManager.default.removeItem(at: file) }
		#expect(throws: ChromiumError.allocatorBootstrapFailed("The host must prepare the allocator at first entry before loading Chromium.")) {
			try ChromiumRuntime(frameworkExecutable: file)
		}
	}

	@Test
	internal func rejectsIncompleteFunctionTable() async throws {
		#expect(throws: ChromiumError.incompatibleBridge) {
			try ChromiumFramework.validated(ArxEngineAPI())
		}
	}

	@Test
	internal func adoptsExistingNativeChildWithoutNavigationAndRejectsForgedOrReplayedOffers() throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		var accepted: ChromiumPage?
		var offers = 0
		var failure: (any Error)?
		_ = try runtime.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
			do {
				let source = try runtime.makePage()
				runtime.onNewContents = { original, generation, child, url, intent in
					#expect(original === source)
					#expect(generation == 1)
					#expect(url.absoluteString == "https://child.example/")
					#expect(intent == .popup)
					#expect(!child.isPrivate)
					accepted = child
					offers += 1
					return true
				}

				for target in ["javascript:alert(1)", "file:///tmp/child", "relative", "about:settings"] {
					let result = runtime.receiveNewContents(source: 1, generation: 1, child: 2, target: target, disposition: 4)
					#expect(!result)
				}

				let stale = runtime.receiveNewContents(source: 1, generation: 2, child: 2, target: "https://child.example/", disposition: 4)
				#expect(!stale)
				let oversized = "x".withCString { pointer in
					Fixture.callbacks?.new_contents_requested?(
						Fixture.callbacks?.context, 1, 1, 2, pointer, 32_769, ARX_CONTENTS_POPUP
					) ?? false
				}
				#expect(!oversized)
				let invalidUTF8: [CChar] = [-1, 0]
				let malformed = invalidUTF8.withUnsafeBufferPointer { bytes in
					Fixture.callbacks?.new_contents_requested?(
						Fixture.callbacks?.context, 1, 1, 2, bytes.baseAddress, 1, ARX_CONTENTS_POPUP
					) ?? false
				}
				#expect(!malformed)
				let target = "https://child.example/"
				let approved = target.withCString { pointer in
					Fixture.callbacks?.new_contents_requested?(
						Fixture.callbacks?.context, 1, 1, 2, pointer, target.utf8.count, ARX_CONTENTS_POPUP
					) ?? false
				}
				#expect(approved)
				#expect(accepted?.identifier == 2)
				#expect(!Fixture.didNavigate)
				let replay = runtime.receiveNewContents(source: 1, generation: 1, child: 2, target: "https://child.example/", disposition: 4)
				#expect(!replay)
				#expect(offers == 1)

				var refused: ChromiumPage?
				runtime.onNewContents = { _, _, child, _, _ in
					refused = child
					return false
				}

				let rejection = runtime.receiveNewContents(source: 1, generation: 1, child: 3, target: "about:blank", disposition: 1)
				#expect(!rejection)
				#expect(refused?.isClosed == true)
				#expect(!source.isClosed)
				#expect(Fixture.destroyCount == 0) // rejected native child remains the native caller's responsibility
			} catch { failure = error }
		}

		#expect(failure == nil)
		#expect(accepted?.isClosed == true)
	}

	@Test
	internal func successfulOptionsPublicationDropsRollbackAuthorityOnTheNextActorTurn() async throws {
		var api = Fixture.api
		api.extension_views_available = { true }
		let runtime = ChromiumRuntime(api: api)
		runtime.extensionBridge.configure(enabled: true, fixture: false)
		runtime.didBecomeReady()
		defer { runtime.finish() }

		let extensionID = String(repeating: "a", count: 32)
		var child: ChromiumPage?
		var revoked = 0
		var settled = 0
		runtime.onExtensionView = { page, _, _ in
			child = page
			return true
		}
		runtime.onExtensionOptionsRevoked = { _, _, _ in revoked += 1 }
		await withCheckedContinuation { continuation in
			runtime.onExtensionOptionsSettled = { _ in
				settled += 1
				continuation.resume()
			}
			#expect(runtime.receiveRuntimeExtensionOptions(
				profileKey: "",
				extensionID: extensionID,
				child: 2,
				target: "chrome-extension://\(extensionID)/options.html"
			))
		}

		runtime.receiveRuntimeExtensionOptionsRevoked(
			profileKey: "",
			extensionID: extensionID,
			child: 2,
			generation: 1
		)
		#expect(settled == 1)
		#expect(revoked == 0)
		#expect(child?.isClosed == false)
	}

	@Test(arguments: ["revoke", "close", "navigation", "settled", "refused", "reentrant"])
	internal func runtimeOptionsRollbackOwnsOnlyTheExactInitialPublication(caseName: String) throws {
		var api = Fixture.api
		api.extension_views_available = { true }
		api.page_close_generation = { _ in MainActor.assumeIsolated { Fixture.optionsGeneration } }
		Fixture.optionsGeneration = 1
		let runtime = ChromiumRuntime(api: api)
		let extensionID = String(repeating: "a", count: 32)
		let target = "chrome-extension://\(extensionID)/options.html"
		var child: ChromiumPage?
		var revoked = 0
		var settled = 0

		_ = try runtime.run(
			executable: Fixture.executable,
			profileDirectory: Fixture.profile,
			enableExtensions: true
		) { runtime in
			@MainActor
			func revoke(
				profile: String = "",
				id: String = extensionID,
				generation: UInt64 = 1
			) {
				profile.withCString { key in
					id.withCString { extensionID in
						Fixture.callbacks?.extension_options_revoked?(
							Fixture.callbacks?.context, key, extensionID, 2, generation
						)
					}
				}
			}

			runtime.onExtensionOptionsRevoked = { page, profile, id in
				#expect(page === child)
				#expect(profile == nil)
				#expect(id == extensionID)
				revoked += 1
			}
			runtime.onExtensionOptionsSettled = { page in
				#expect(page === child)
				settled += 1
			}
			runtime.onExtensionView = { page, _, _ in
				child = page
				if caseName == "reentrant" { revoke() }
				return caseName != "refused"
			}

			let accepted = runtime.receiveRuntimeExtensionOptions(
				profileKey: "",
				extensionID: extensionID,
				child: 2,
				target: target
			)
			#expect(accepted == (caseName != "refused" && caseName != "reentrant"))

			switch caseName {
			case "close":
				child?.close()

			case "navigation":
				Fixture.optionsGeneration = 2

			case "settled":
				target.withCString { url in
					Fixture.callbacks?.page_changed(
						Fixture.callbacks?.context, 2, url, nil, false, false, false, 0
					)
				}

			default:
				break
			}

			// A foreign profile, extension, or generation cannot consume the offer.
			revoke(profile: UUID().uuidString.lowercased())
			revoke(id: String(repeating: "b", count: 32))
			revoke(generation: 2)
			revoke()
			revoke()

			let shouldRevoke = caseName == "revoke" || caseName == "reentrant"
			#expect(revoked == (shouldRevoke ? 1 : 0))
			#expect(settled == (shouldRevoke ? 0 : 1))
			#expect(child?.isClosed == (shouldRevoke || caseName == "close" || caseName == "refused"))
			#expect(Fixture.destroyCount == (caseName == "close" ? 1 : 0))
		}
	}

	@Test
	internal func nativeRuntimeOptionsUseSeparateOrdinaryProfileAuthorityAndNeverReplay() throws {
		var api = Fixture.api
		api.extension_views_available = { true }
		api.prepare_private_profile = { _ in true }
		let runtime = ChromiumRuntime(api: api)
		let extensionID = String(repeating: "a", count: 32)
		let target = "chrome-extension://\(extensionID)/options.html"
		var offers = 0
		var adopted: ChromiumPage?
		_ = try runtime.run(
			executable: Fixture.executable,
			profileDirectory: Fixture.profile,
			enableExtensions: true
		) { runtime in
			runtime.onExtensionView = { child, profile, id in
				#expect(profile == nil)
				#expect(id == extensionID)
				#expect(!child.isPrivate)
				offers += 1
				adopted = child
				return true
			}

			#expect(!runtime.receiveExtensionOptions(
				request: 0,
				profileKey: "",
				extensionID: extensionID,
				child: 2,
				target: target,
				kind: ARX_EXTENSION_VIEW_OPTIONS
			))
			#expect(!runtime.receiveRuntimeExtensionOptions(
				profileKey: UUID().uuidString.lowercased(),
				extensionID: extensionID,
				child: 2,
				target: target
			))
			let privateID = UUID()
			do {
				try runtime.preparePrivateProfile(privateID)
			} catch {
				Issue.record(error)
				return
			}
			#expect(!runtime.receiveRuntimeExtensionOptions(
				profileKey: privateID.uuidString.lowercased(),
				extensionID: extensionID,
				child: 2,
				target: target
			))
			#expect(!runtime.receiveRuntimeExtensionOptions(
				profileKey: "",
				extensionID: extensionID,
				child: 2,
				target: "chrome-extension://\(String(repeating: "b", count: 32))/options.html"
			))
			let accepted = "".withCString { key in
				extensionID.withCString { id in
					target.withCString { url in
						Fixture.callbacks?.extension_options_requested?(
							Fixture.callbacks?.context, key, id, 3, url, target.utf8.count
						) ?? false
					}
				}
			}
			#expect(accepted)
			#expect(adopted?.identifier == 3)
			#expect(!Fixture.didNavigate)
			adopted?.close()
			#expect(!runtime.receiveRuntimeExtensionOptions(
				profileKey: "",
				extensionID: extensionID,
				child: 3,
				target: target
			))
			#expect(!runtime.receiveRuntimeExtensionOptions(
				profileKey: "",
				extensionID: extensionID,
				child: 2,
				target: target
			))
			#expect(offers == 1)

			runtime.onExtensionView = { _, _, _ in false }
			#expect(!runtime.receiveRuntimeExtensionOptions(
				profileKey: "",
				extensionID: extensionID,
				child: 4,
				target: target
			))
			#expect(Fixture.destroyCount == 1) // Native owns the refused child cleanup.
		}
		#expect(!runtime.receiveRuntimeExtensionOptions(
			profileKey: "",
			extensionID: extensionID,
			child: 5,
			target: target
		))
	}

	@Test
	internal func enforcesRuntimeAndPageLifetime() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		#expect(throws: ChromiumError.notRunning) { try runtime.makePage() }
		var page: ChromiumPage?
		var failure: (any Error)?
		_ = try runtime
			.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
				do {
					let created = try runtime.makePage()
					page = created
					try created.navigate(to: URL(string: "https://capturecontext.dev")!)
					#expect(Fixture.didNavigate)
					runtime.requestQuit()
					#expect(Fixture.didQuit)
				} catch { failure = error }
			}
		#expect(failure == nil)
		let created = try #require(page)
		#expect(created.isClosed)
		#expect(throws: ChromiumError.pageClosed) { try created.reload() }
		#expect(throws: ChromiumError.alreadyStarted) {
			try runtime.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { _ in }
		}
	}

	@Test
	internal func closesPageOnceAndPreventsNativeCallsAfterClose() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		var failure: (any Error)?
		_ = try runtime
			.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
				do {
					let page = try runtime.makePage()
					page.close()
					page.close()
					expectNoDifference(Fixture.destroyCount, 1)
					#expect(throws: ChromiumError.pageClosed) { try page.goBack() }
				} catch { failure = error }
			}
		#expect(failure == nil)
	}

	@Test
	internal func copiesCallbackStringsBeforeNativeMemoryExpires() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		var page: ChromiumPage?
		_ = try runtime
			.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
				page = Self.makePage(in: runtime)
				"https://capturecontext.dev".withCString { url in
					"Example".withCString { title in
						Fixture.callbacks?.page_changed(
							Fixture.callbacks?.context,
							1,
							url,
							title,
							false,
							true,
							false,
							-105
						)
					}
				}
			}
		let navigation = try #require(page).navigation
		expectNoDifference(navigation, .init(
			url: URL(string: "https://capturecontext.dev"),
			title: "Example",
			isLoading: false,
			canGoBack: true,
			canGoForward: false,
			errorCode: -105
		))
	}

	@Test
	internal func navigationCarriesUnattendedAuthenticationCancellations() async throws {
		var api = Fixture.api
		api.page_authentication_cancellations = { page in page == 1 ? 2 : 0 }
		let runtime = ChromiumRuntime(api: api)
		var page: ChromiumPage?
		_ = try runtime
			.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
				page = Self.makePage(in: runtime)
				"https://capturecontext.dev".withCString { url in
					Fixture.callbacks?.page_changed(Fixture.callbacks?.context, 1, url, nil, false, false, false, 0)
				}
			}
		expectNoDifference(try #require(page).navigation.authenticationCancellations, 2)
	}

	@Test
	internal func navigationCarriesUnattendedUserActionRequests() async throws {
		var api = Fixture.api
		api.page_user_action_requests = { page in
			page == 1 ? ARX_USER_ACTION_WEB_AUTHENTICATION.rawValue | ARX_USER_ACTION_FEDERATED_SIGN_IN.rawValue : 0
		}
		let runtime = ChromiumRuntime(api: api)
		var page: ChromiumPage?
		_ = try runtime
			.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
				page = Self.makePage(in: runtime)
				"https://capturecontext.dev".withCString { url in
					Fixture.callbacks?.page_changed(Fixture.callbacks?.context, 1, url, nil, false, false, false, 0)
				}
			}
		expectNoDifference(
			try #require(page).navigation.userActionRequests,
			[.webAuthentication, .federatedSignIn]
		)
	}

	@Test
	internal func extensionTabPlacementsListOnlyOpenPagesInWindows() async throws {
		ExtensionPlacementCapture.placements = []
		ExtensionPlacementCapture.nextPage = 0
		var api = Fixture.api
		api.create_page = { _, _ in
			MainActor.assumeIsolated {
				ExtensionPlacementCapture.nextPage += 1
				return ExtensionPlacementCapture.nextPage
			}
		}
		api.set_extension_tab_placements = { placements, count in
			MainActor.assumeIsolated {
				ExtensionPlacementCapture.placements = Array(UnsafeBufferPointer(start: placements, count: count))
			}
		}
		let runtime = ChromiumRuntime(api: api)
		#expect(runtime.supportsExtensionWindows)
		_ = try runtime
			.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
				guard
					let shown = Self.makePage(in: runtime),
					let behind = Self.makePage(in: runtime),
					let closed = Self.makePage(in: runtime)
				else { return }

				closed.close()
				runtime.setExtensionTabPlacements([
					(shown, .init(windowNumber: 7, index: 0, isActive: true, isHighlighted: true)),
					(behind, .init(windowNumber: 7, index: 1, isActive: false, isHighlighted: false)),
					(behind, .init(windowNumber: 0, index: 0, isActive: true, isHighlighted: true)),
					(closed, .init(windowNumber: 7, index: 2, isActive: false, isHighlighted: false)),
				])
			}
		expectNoDifference(
			ExtensionPlacementCapture.placements.map { [Int($0.page), Int($0.window_number), Int($0.index)] },
			[[1, 7, 0], [2, 7, 1]]
		)
		expectNoDifference(ExtensionPlacementCapture.placements.map(\.active), [true, false])
		expectNoDifference(ExtensionPlacementCapture.placements.map(\.highlighted), [true, false])
	}

	@Test
	internal func downloadEventsSurvivePageClosureAndCopyNativeStrings() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		var events: AsyncStream<ChromiumDownloadEvent>?
		_ = try runtime.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
			let page = Self.makePage(in: runtime)
			page?.close()
			Fixture.emitDownload(state: 0, received: 12)
			events = runtime.downloadEvents()
			Fixture.emitDownload(state: 1, received: 24)
			"profile".withCString { profile in
				Fixture.callbacks?.downloads_initialized(Fixture.callbacks?.context, profile)
			}
		}
		var received: [ChromiumDownloadEvent] = []
		for await value in try #require(events) { received.append(value) }
		#expect(received.count == 3)
		guard case let .changed(first) = received[0], case let .changed(last) = received[1] else {
			Issue.record("Expected native download snapshots")
			return
		}
		#expect(first.guid == "download-guid")
		#expect(first.filename == "sample.txt")
		#expect(first.profileKey == "profile")
		#expect(first.url?.absoluteString == "https://capturecontext.dev/file")
		#expect(first.target?.path == "/tmp/sample.txt")
		#expect(first.state == .inProgress)
		#expect(first.receivedBytes == 12)
		#expect(last.state == .complete)
		#expect(last.receivedBytes == 24)
		#expect(received[2] == .initialized(profileKey: "profile"))
	}

	@Test
	internal func quitGuardReadsNativeWorkBeforeQueuedEventsArrive() throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		_ = try runtime.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
			Fixture.activeDownloads = 2
			#expect(runtime.activeDownloadCount() == 2)
			#expect(throws: Never.self) { try runtime.cancelAllDownloads() }
			#expect(Fixture.cancelledAll)
			#expect(runtime.activeDownloadCount() == 0)
		}
		#expect(runtime.activeDownloadCount() == 0)
		#expect(throws: ChromiumError.notRunning) { try runtime.cancelAllDownloads() }
	}

	@Test
	internal func cancellationRoutesToProfileAndRejectsAfterShutdown() throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		_ = try runtime.run(executable: Fixture.executable, profileDirectory: Fixture.profile) { runtime in
			#expect(throws: Never.self) { try runtime.cancelDownload(profileKey: "private-profile", guid: "transfer") }
			#expect(Fixture.cancelledProfile == "private-profile")
			#expect(Fixture.cancelledGUID == "transfer")
		}
		#expect(throws: ChromiumError.notRunning) {
			try runtime.cancelDownload(profileKey: "private-profile", guid: "transfer")
		}
	}


	// MARK: - ABI55 (DEV-885) web notifications

	@Test
	internal func aNotificationWindowBecomesAnAdoptedPageOnlyOnce() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		runtime.didBecomeReady()
		defer { runtime.finish() }

		var offers: [(ChromiumPage, UUID?)] = []
		runtime.onNotificationWindow = { page, profile in
			offers.append((page, profile))
			return true
		}
		#expect(runtime.receiveNotificationWindow(
			profileKey: "",
			child: 7,
			target: "https://mail.example/inbox"
		))
		#expect(offers.count == 1)
		#expect(offers.first?.1 == nil)
		#expect(offers.first?.0.navigation.url?.absoluteString == "https://mail.example/inbox")
		#expect(offers.first?.0.navigation.isLoading == true)

		// Native IDs are never recycled: the same or an older child is a replay.
		#expect(!runtime.receiveNotificationWindow(profileKey: "", child: 7, target: "https://mail.example"))
		#expect(!runtime.receiveNotificationWindow(profileKey: "", child: 6, target: "https://mail.example"))
		// Only web pages, and only prepared ordinary profiles.
		#expect(!runtime.receiveNotificationWindow(profileKey: "", child: 8, target: "file:///etc/hosts"))
		#expect(!runtime.receiveNotificationWindow(
			profileKey: UUID().uuidString.lowercased(),
			child: 9,
			target: "https://mail.example"
		))
		#expect(offers.count == 1)
	}

	@Test
	internal func aRefusedNotificationWindowLeavesNoPage() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		runtime.didBecomeReady()
		defer { runtime.finish() }

		var refused: ChromiumPage?
		runtime.onNotificationWindow = { page, _ in
			refused = page
			return false
		}
		#expect(!runtime.receiveNotificationWindow(profileKey: "", child: 3, target: "https://mail.example"))
		#expect(refused?.isClosed == true)
	}

	@Test
	internal func notificationClicksReadOnlyWebOrigins() async throws {
		let flags = ARX_NOTIFICATION_PERSISTENT.rawValue | ARX_NOTIFICATION_HANDLED.rawValue
		let click = try #require(ChromiumNotificationClick(
			profileKey: "",
			origin: "https://mail.example:8443",
			flags: flags
		))
		#expect(click.isPersistent)
		#expect(click.isHandled)
		#expect(!click.pageIsGone)
		#expect(click.origin.port == 8443)

		let gone = try #require(ChromiumNotificationClick(
			profileKey: "",
			origin: "http://localhost:3000",
			flags: ARX_NOTIFICATION_PAGE_GONE.rawValue
		))
		#expect(gone.pageIsGone)
		#expect(!gone.isPersistent)

		#expect(ChromiumNotificationClick(profileKey: "", origin: "https://mail.example/inbox", flags: 0) == nil)
		#expect(ChromiumNotificationClick(profileKey: "", origin: "chrome-extension://abc", flags: 0) == nil)
		#expect(ChromiumNotificationClick(profileKey: "", origin: "null", flags: 0) == nil)
		#expect(ChromiumNotificationClick(profileKey: "Not-A-Key", origin: "https://mail.example", flags: 0) == nil)
	}

	@Test
	internal func notificationClicksReachTheAppForProfilesNotPreparedYet() async throws {
		let runtime = ChromiumRuntime(api: Fixture.api)
		runtime.didBecomeReady()
		defer { runtime.finish() }

		var clicks: [ChromiumNotificationClick] = []
		runtime.onNotificationClick = { clicks.append($0) }
		let legacy = ChromiumNotificationClick(
			profileKey: "",
			origin: URL(string: "https://mail.example")!,
			isPersistent: true,
			isHandled: false,
			pageIsGone: false
		)
		let unprepared = ChromiumNotificationClick(
			profileKey: UUID().uuidString.lowercased(),
			origin: URL(string: "https://mail.example")!,
			isPersistent: true,
			isHandled: false,
			pageIsGone: false
		)
		runtime.receiveNotificationClick(legacy)

		// Chromium loads a profile Arx hasn't shown yet, or released, to dispatch its click.
		runtime.receiveNotificationClick(unprepared)
		expectNoDifference(clicks, [legacy, unprepared])
	}
}

@MainActor
private enum Fixture {
	internal static var gestureCalls: Int = 0
	internal static var mediaQueries: Int = 0
	internal static var optionsGeneration: UInt64 = 1
	internal static var mediaGeneration: UInt64 = 1
	internal static var mediaPresent: Bool = false
	internal static var activeDownloads: UInt64 = 0
	internal static var cancelledAll: Bool = false
	internal static var cancelledProfile: String?
	internal static var cancelledGUID: String?
	internal static var callbacks: ArxEngineCallbacks?
	internal static var view: NSView = .init()
	internal static var didNavigate: Bool = false
	internal static var didQuit: Bool = false
	internal static var destroyCount: Int = 0
	internal static var executable: URL { URL(filePath: "/tmp/Arx.app/Contents/MacOS/Arx") }
	internal static var profile: URL { URL(filePath: "/tmp/arx-engine-test-profile") }

	internal static func emitDownload(
		state: Int32,
		received: Int64
	) {
		"profile".withCString { profile in
			"download-guid".withCString { guid in
				"https://capturecontext.dev/file".withCString { url in
					"/tmp/sample.txt".withCString { path in
						"sample.txt".withCString { filename in
							var snapshot = ArxDownloadSnapshot(
								guid: guid,
								url: url,
								target_path: path,
								filename: filename,
								source_page: 1,
								state: state,
								interrupt_reason: 0,
								received_bytes: received,
								total_bytes: 24,
								started_at: 100,
								dangerous: false,
								missing: false,
								private_context: true
							)
							callbacks?.download_changed(callbacks?.context, profile, &snapshot)
						}
					}
				}
			}
		}
	}

	internal static var api: ArxEngineAPI {
		ArxEngineAPI(
			run: { _, _, callbacks in
				MainActor.assumeIsolated {
					Fixture.callbacks = callbacks?.pointee
					Fixture.didNavigate = false
					Fixture.didQuit = false
					Fixture.destroyCount = 0
					Fixture.activeDownloads = 0
					Fixture.cancelledAll = false
					callbacks?.pointee.ready(callbacks?.pointee.context)
					callbacks?.pointee.stopping(callbacks?.pointee.context)
					Fixture.callbacks = nil
					return 0
				}
			},
			request_quit: { MainActor.assumeIsolated { Fixture.didQuit = true } },
			create_page: { _, _ in 1 },
			destroy_page: { _ in
				MainActor.assumeIsolated { Fixture.destroyCount += 1 }
			},
			page_view: { _ in
				let view = MainActor.assumeIsolated { Fixture.view }
				return Unmanaged.passUnretained(view).toOpaque()
			},
			navigate: { _, _ in
				MainActor.assumeIsolated {
					Fixture.didNavigate = true
					return true
				}
			},
			go_back: { _ in },
			go_forward: { _ in },
			reload: { _ in },
			stop: { _ in },
			prepare_profile: { _, request in
				MainActor.assumeIsolated {
					Fixture.callbacks?.profile_ready(
						Fixture.callbacks?.context,
						request,
						true
					)
				}
			},
			request_close: { _, request in
				MainActor.assumeIsolated {
					Fixture.callbacks?.close_decided(
						Fixture.callbacks?.context,
						request,
						true
					)
				}
			},
			history_count: { _ in 0 },
			history_entry: { _, _, _, _, _ in -1 },
			go_to_entry: { _, _ in },
			prepare_private_profile: { _ in true },
			release_private_profile: { _ in },
			clear_cache_and_reload: { _ in },
			observe_downloads: { _ in true },
			cancel_download: { profile, guid in
				MainActor.assumeIsolated {
					Fixture.cancelledProfile = profile.map(String.init(cString:))
					Fixture.cancelledGUID = guid.map(String.init(cString:))
					return true
				}
			},
			active_download_count: { MainActor.assumeIsolated { Fixture.activeDownloads } },
			cancel_all_downloads: {
				MainActor.assumeIsolated {
					Fixture.activeDownloads = 0
					Fixture.cancelledAll = true
				}
			},
			capture_viewport: { _, _, _ in },
			cancel_capture: { _ in },
			run_with_options: { _, _, _, _ in 0 },
			observe_media: { _ in true },
			perform_media: { _, _, _, _, _ in },
			cancel_media: { _ in },
			private_media_metadata_status: { _ in -1 },
			inspect_extensions: { _, _ in },
			manage_extension: { _, _, _, _, _ in },
			cancel_extension_request: { _ in },
			load_extension_fixture: { _, _ in },
			media_source_is_current: { _, _ in false },
			page_close_generation: { _ in 1 },
			request_authorized_close: { _, _, _ in },
			consume_authorized_close: { _, _, _ in ARX_CLOSE_STALE },
			cancel_authorized_close: { _, _ in },
			lookup_site_icon: { _, _, _ in },
			cancel_site_icon: { _ in },
			inspect_page: { _, _, _, _ in },
			validate_inspection_reference: { _, _, _, _, _ in },
			cancel_inspection: { _ in },
			revoke_inspection_scope: { _ in },
			inspection_document_is_current: { _, _, _ in false },
			click_inspection_reference: { _, _, _, _, _, _, _ in },
			cancel_reference_click: { _ in },
			perform_inspection_form_action: { _, _, _, _, _, _, _, _, _, _ in },
			cancel_reference_form_action: { _ in },
			scroll_inspection_reference: { _, _, _, _, _, _, _, _, _ in },
			link_context_is_current: { _, _ in false },
			dismiss_link_context: { _, _ in },
			run_with_profile_retirement: nil,
			profile_retirement_available: nil,
			inspect_profile_retirement: nil,
			queue_profile_retirement: nil,
			document_capture_available: { false },
			capture_document: { _, _, _ in },
			cancel_document_capture: { _ in },
			run_document_capture_fixture: { _, _, _ in },
			run_gesture_fixture: nil,
			reference_keypress_available: { false },
			configure_content_hosting: { _, _ in true },
			extension_install_available: nil,
			install_extension_crx: nil,
			resolve_extension_install: nil,
			install_extension_fixture: nil,
			extension_views_available: { false },
			open_extension_view: { _, _, _, _, _, _, _ in },
			devtools_available: { false },
			configure_devtools: { _, _, _ in },
			open_devtools: { _ in ARX_DEVTOOLS_UNAVAILABLE },
			inspect_link_context: { _, _ in ARX_DEVTOOLS_UNAVAILABLE },
			close_devtools: { _ in false },
			devtools_is_open: { _ in false },
			reload_bypassing_cache: { _ in },
			devtools_frontend_loaded: { _ in false },
			set_unattended: { _ in },
			unattended_dialog_count: { 0 },
			unpacked_extensions_available: { false },
			load_unpacked_extension: { _, _, _, _ in },
			page_authentication_cancellations: { _ in 0 },
			set_extension_tab_placements: { _, _ in },
			page_user_action_requests: { _ in 0 },
			set_unattended_shutdown: { _, _, _ in },
			page_find: { _, _, _, _ in },
			page_stop_find: { _ in },
			page_find_status: { _, matches, active in
				matches?.pointee = -1
				active?.pointee = -1
			},
			// Plain main-frame reads use inspect_page; tests opt into frames and windows.
			inspect_frame: nil,
			capture_offscreen: nil,
			request_pdf: nil,
			cancel_pdf: nil,
			page_file_chooser: nil,
			answer_file_chooser: nil,
			page_dialog: nil,
			answer_page_dialog: nil,
			media_position: nil,
			seek_media: nil,
			set_page_audio_muted: nil,
			start_download: nil,
			evaluate_script: nil,
			set_developer_log: nil,
			read_developer_log: nil,
			cancel_developer: nil,
			answer_password_save: nil,
			sign_in_credentials: nil,
			sign_in_attempt: nil,
			cancel_sign_in: nil,
			list_saved_passwords: nil,
			save_saved_password: nil,
			remove_saved_password: nil,
			reveal_saved_password: nil,
			import_saved_passwords: nil,
			cancel_saved_passwords: nil,
			focused_link: nil,
			list_site_settings: nil,
			set_site_permission: nil,
			set_site_zoom: nil,
			count_browsing_data: nil,
			clear_browsing_data: nil,
			download_settings: nil,
			set_download_settings: nil,
			site_data_scope: nil,
			clear_site_data: nil,
			page_zoom: nil,
			set_page_zoom: nil,
			devtools_layout: nil,
			show_devtools_panel: nil,
			start_devtools_inspect: nil,
			install_webstore_extension: nil,
			decline_webstore_install: nil,
			prepare_private_profile_for: nil,
			update_webstore_extension: nil,
			configure_page_menu: nil,
			save_page: nil,
			import_password_records: nil,
			import_cookies: nil,
			check_cookies: nil,
			undo_credential_import: nil,
			install_webstore_extension_by_id: nil,
			configure_context_menus: nil,
			run_extension_action: nil,
			page_document_type: nil,
			external_link_is_current: nil,
			set_site_icon_fetch: nil,
			lookup_cached_site_icon: nil,
			accept_autofill_suggestion: nil,
			select_autofill_suggestion: nil,
			dismiss_autofill_suggestions: nil,
			set_autofill_authentication: nil,
			set_autofill_products: nil,
			list_autofill_data: nil,
			save_autofill_address: nil,
			save_autofill_card: nil,
			remove_autofill_data: nil,
			cancel_autofill_data: nil,
			exit_page_fullscreen: nil,
			download_link_context: nil,
			set_page_prompts_hosted: nil,
			copy_page_permission_prompt: nil,
			answer_page_permission_prompt: nil,
			evaluate_translation_script: nil,
			page_unresponsive: nil,
			wait_for_page: nil,
			end_page_renderer: nil,
			ping_page: nil,
			page_renderer_end: nil,
			page_main_document: nil,
			set_link_hover_reports: nil,
			page_colors: nil
		)
	}
}

@MainActor
internal struct ChromiumUnattendedTests {
	fileprivate static var configured: [Bool] = []

	@Test
	internal func unattendedModeIsFixedBeforeStartup() throws {
		Self.configured = []
		var api = ArxEngineAPI()
		api.set_unattended = { value in MainActor.assumeIsolated { ChromiumUnattendedTests.configured.append(value) } }
		api.unattended_dialog_count = { 3 }
		let runtime = ChromiumRuntime(api: api)

		#expect(runtime.supportsUnattendedRuns)
		try runtime.configureUnattended()
		#expect(Self.configured == [true])
		#expect(runtime.unattendedDialogCount == 0)
		runtime.didBecomeReady()
		#expect(runtime.unattendedDialogCount == 3)
		#expect(throws: ChromiumError.alreadyStarted) { try runtime.configureUnattended() }
		#expect(Self.configured == [true])
	}

	@Test
	internal func olderBridgeCannotRunUnattended() {
		let runtime = ChromiumRuntime(api: ArxEngineAPI())
		#expect(!runtime.supportsUnattendedRuns)
		#expect(throws: ChromiumError.incompatibleBridge) { try runtime.configureUnattended() }
		#expect(!runtime.supportsUnattendedShutdown)
		#expect(throws: ChromiumError.incompatibleBridge) {
			try runtime.configureUnattendedShutdown(deadline: .seconds(60)) { _ in }
		}
	}

	/// DEV-800: per-tab volume is an export outside the ABI table, so an engine built before it
	/// still loads and only lacks volume.
	@Test
	internal func audioVolumeIsOptionalAndNeedsARunningEngine() {
		let older = ChromiumRuntime(api: ArxEngineAPI())
		#expect(!older.supportsAudioVolume)

		let runtime = ChromiumRuntime(api: ArxEngineAPI(), audioVolume: { _, _ in true })
		#expect(runtime.supportsAudioVolume)
		let page = ChromiumPage(id: 7, view: NSView(), runtime: runtime, isPrivate: false)
		#expect(throws: ChromiumMediaFailure.unavailable) { try runtime.setAudioVolume(page, 0.5) }
		#expect(throws: ChromiumMediaFailure.unavailable) { try older.setAudioVolume(page, 0.5) }
	}

	/// DEV-878: back/forward history is an export outside the ABI table too, read only from the
	/// runtime's own running pages.
	@Test
	internal func navigationStateIsOptionalAndReadsOnlyOwnPages() async throws {
		let older = ChromiumRuntime(api: ArxEngineAPI())
		#expect(!older.supportsNavigationState)

		let runtime = ChromiumRuntime(
			api: ArxEngineAPI(),
			navigationState: .init(
				copy: { _, _ in 0 },
				createRestoredPage: { _, _, _, _ in 0 },
				loadRestoredPage: { _ in false }
			)
		)
		#expect(runtime.supportsNavigationState)
		let page = ChromiumPage(id: 7, view: NSView(), runtime: runtime, isPrivate: false)
		let privatePage = ChromiumPage(id: 8, view: NSView(), runtime: runtime, isPrivate: true)
		#expect(runtime.navigationState(page) == nil)

		// A page the runtime didn't make is never read, private or not.
		runtime.didBecomeReady()
		#expect(runtime.navigationState(page) == nil)
		#expect(runtime.navigationState(privatePage) == nil)
		#expect(older.navigationState(page) == nil)
		#expect(throws: ChromiumError.notRunning) { try older.loadRestoredPage(page) }
	}

	@Test
	internal func unattendedShutdownReportsExpiryBeforeStartupOnly() throws {
		ShutdownCapture.deadline = 0
		ShutdownCapture.expired = nil
		ShutdownCapture.context = nil
		var api = ArxEngineAPI()
		api.set_unattended_shutdown = { deadline, expired, context in
			MainActor.assumeIsolated {
				ShutdownCapture.deadline = deadline
				ShutdownCapture.expired = expired
				ShutdownCapture.context = context
			}
		}
		let runtime = ChromiumRuntime(api: api)
		let reported = Reported()

		#expect(runtime.supportsUnattendedShutdown)
		try runtime.configureUnattendedShutdown(deadline: .seconds(45)) { code in reported.append(code) }
		#expect(ShutdownCapture.deadline == 45)
		ShutdownCapture.expired?(ShutdownCapture.context, 2)
		#expect(reported.values == [2])

		runtime.didBecomeReady()
		#expect(throws: ChromiumError.alreadyStarted) {
			try runtime.configureUnattendedShutdown(deadline: .seconds(10)) { _ in }
		}
		#expect(ShutdownCapture.deadline == 45)
	}
}

@MainActor
private enum ExtensionPlacementCapture {
	internal static var placements: [ArxExtensionTabPlacement] = []
	internal static var nextPage: UInt64 = 0
}

@MainActor
private enum ShutdownCapture {
	internal static var deadline: UInt32 = 0
	internal static var expired: (@convention(c) (UnsafeMutableRawPointer?, Int32) -> Void)?
	internal static var context: UnsafeMutableRawPointer?
}

private final class Reported: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var codes: [Int32] = []

	internal var values: [Int32] { lock.withLock { codes } }

	internal func append(_ code: Int32) {
		lock.withLock { codes.append(code) }
	}
}
