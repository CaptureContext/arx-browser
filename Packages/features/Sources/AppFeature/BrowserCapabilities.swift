import BrowserCaptureClient
import BrowserCore
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import Foundation
import PageCaptureFeature
import _ComposableArchitecture
import _IssueReporting

/// Stable dependencies installed before the runtime starts; native media is created only when ready.
@MainActor
internal final class BrowserCapabilities {
	private let isRunning: @MainActor @Sendable () -> Bool
	private let nativeCapture: BrowserCaptureClient
	private let nativeInspection: BrowserPageInspectionClient
	private let nativeInteraction: BrowserPageInteractionClient
	private let nativeWait: BrowserPageWaitClient
	private let makeMedia: @MainActor @Sendable () throws -> BrowserMediaClient
	private let makeExtensions: @MainActor @Sendable (@escaping @MainActor @Sendable (Profile.ID) -> Bool) -> BrowserExtensionsClient
	private var nativeMedia: BrowserMediaClient = .init()
	private var nativeExtensions: BrowserExtensionsClient = .init()
	private var activated: Bool = false
	private var stopped: Bool = false
	private var observationTasks: [UUID: Task<Void, Never>] = [:]
	private var finishObservations: [UUID: @Sendable () -> Void] = [:]
	internal weak var store: StoreOf<AppFeature>?

	internal init(
		isRunning: @escaping @MainActor @Sendable () -> Bool,
		capture: BrowserCaptureClient,
		media: @escaping @MainActor @Sendable () throws -> BrowserMediaClient,
		extensions: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable (Profile.ID) -> Bool) -> BrowserExtensionsClient,
		inspection: BrowserPageInspectionClient = .init(),
		interaction: BrowserPageInteractionClient = .init(),
		pageWait: BrowserPageWaitClient = .init()
	) {
		self.isRunning = isRunning
		self.nativeCapture = capture
		self.nativeInspection = inspection
		self.nativeInteraction = interaction
		self.nativeWait = pageWait
		self.makeMedia = media
		self.makeExtensions = extensions
	}

	deinit {
		for task in observationTasks.values { task.cancel() }
		for finish in finishObservations.values { finish() }
	}

	private var isReady: Bool {
		activated
		&& !stopped
		&& isRunning()
		&& store != nil
		&& store?.shouldQuit == false
	}

	internal var capture: BrowserCaptureClient {
		.init(
			fullDocumentIsAvailable: { [weak self] in self?.fullDocumentCaptureAvailable == true },
			wholePageIsAvailable: { [weak self] in self?.wholePageCaptureAvailable == true },
			isAvailable: { [weak self] in self?.captureAvailable == true },
			offscreenIsAvailable: { [weak self] in self?.offscreenCaptureAvailable == true },
			pdfIsAvailable: { [weak self] in self?.pdfAvailable == true },
			pdfAuthorized: { [weak self] request, authorize in
				try Task.checkCancellation()

				guard let self, pdfAvailable else { throw PageCaptureFailure.unavailable }
				guard authorize() else { throw PageCaptureFailure.staleDocument }

				return try await nativeCapture.pdfAuthorized(request) { [weak self] in
					self?.pdfAvailable == true && authorize()
				}
			},
			captureAuthorized: { [weak self] request, authorize in
				try Task.checkCancellation()

				guard
					let self,
					captureAvailable,
					modeIsAvailable(request)
				else { throw PageCaptureFailure.unavailable }
				guard authorize() else { throw PageCaptureFailure.staleDocument }

				let frame = try await nativeCapture.captureAuthorized(request) { [weak self] in
					self?.captureAvailable == true
					&& self?.modeIsAvailable(request) == true
					&& authorize()
				}
				try Task.checkCancellation()

				guard captureAvailable, modeIsAvailable(request)
				else { throw PageCaptureFailure.unavailable }
				guard authorize() else { throw PageCaptureFailure.staleDocument }

				return frame
			},
			crop: nativeCapture.crop,
			scrollIsAvailable: { [weak self] in self?.captureScrollAvailable == true },
			scrollAuthorized: { [weak self] request, offset, authorize in
				try Task.checkCancellation()

				guard let self, captureScrollAvailable else { throw PageCaptureFailure.unavailable }
				guard authorize() else { throw PageCaptureFailure.staleDocument }

				let moved = try await nativeCapture.scrollAuthorized(request, offset) { [weak self] in
					self?.captureScrollAvailable == true && authorize()
				}
				try Task.checkCancellation()

				// The page may have moved by now: `.unavailable` would say it didn't.
				guard captureScrollAvailable, authorize() else { throw PageCaptureFailure.staleDocument }

				return moved
			}
		)
	}

	/// DEV-1208.
	private var captureScrollAvailable: Bool { captureAvailable && nativeCapture.scrollIsAvailable() }

	private var fullDocumentCaptureAvailable: Bool { isReady && nativeCapture.fullDocumentIsAvailable() }

	/// DEV-1172.
	private var wholePageCaptureAvailable: Bool { isReady && nativeCapture.wholePageIsAvailable() }

	/// A whole page needs the engine's beyond-viewport capture, a recorded document ABI16's.
	private func modeIsAvailable(_ request: PageCaptureRequest) -> Bool {
		switch request.mode {
		case .viewport: true
		case .fullDocument: request.beyondViewport ? wholePageCaptureAvailable : fullDocumentCaptureAvailable
		}
	}

	private var captureAvailable: Bool { isReady && nativeCapture.isAvailable() }

	private var offscreenCaptureAvailable: Bool { captureAvailable && nativeCapture.offscreenIsAvailable() }

	private var pdfAvailable: Bool { isReady && nativeCapture.pdfIsAvailable() }

	internal var inspection: BrowserPageInspectionClient {
		inspection(owns: { [weak self] in self?.ownsInspectionSource($0) == true })
	}

	/// Node bounds for an on-page capture. It reads only the exact source a live capture
	/// session prepared, which may be a Little Arx or temporary Peek page that automation
	/// can't read.
	internal var captureInspection: BrowserPageInspectionClient {
		inspection(owns: { [weak self] in self?.ownsCaptureInspectionSource($0) == true })
	}

	private func inspection(
		owns: @escaping @MainActor @Sendable (PageInspectionSource) -> Bool
	) -> BrowserPageInspectionClient {
		.init(
			isAvailable: { [weak self] in self?.inspectionAvailable == true },
			inspectAuthorized: { [weak self] request, source, authorize in
				try Task.checkCancellation()
				guard let self, inspectionAvailable
				else { throw AutomationFailure.notReady }
				guard owns(source), authorize()
				else { throw AutomationFailure.denied }

				let snapshot = try await nativeInspection.inspectAuthorized(request, source) { [weak self] in
					self?.inspectionAvailable == true
					&& owns(source)
					&& authorize()
				}
				try Task.checkCancellation()
				guard
					inspectionAvailable,
					owns(source),
					authorize()
				else { throw AutomationFailure.denied }

				return snapshot
			},
			documentIsCurrent: { [weak self] result in
				guard let self else { return false }
				return inspectionAvailable
				&& owns(result.source)
				&& nativeInspection.documentIsCurrent(result)
			},
			revokeScope: { [weak self] in self?.nativeInspection.revokeScope($0) }
		)
	}

	internal var pageWait: BrowserPageWaitClient {
		.init(
			isAvailable: { [weak self] in self?.waitAvailable == true },
			waitAuthorized: { [weak self] request, target, authorize in
				guard let self, waitAvailable else { throw AutomationFailure.notReady }
				guard ownsWaitTarget(target), authorize() else { throw AutomationFailure.denied }

				let observation = try await nativeWait.waitAuthorized(request, target) { [weak self] in
					self?.waitAvailable == true
					&& self?.ownsWaitTarget(target) == true
					&& authorize()
				}
				try Task.checkCancellation()
				guard waitAvailable, ownsWaitTarget(target), authorize()
				else { throw AutomationFailure.denied }

				return observation
			},
			sourceIsCurrent: { [weak self] source in
				guard let self else { return false }
				return waitAvailable
				&& ownsWaitTarget(source.target)
				&& nativeWait.sourceIsCurrent(source)
			}
		)
	}

	private var waitAvailable: Bool { isReady && nativeWait.isAvailable() }

	private func ownsWaitTarget(_ target: PageWaitTarget) -> Bool {
		guard let store, ownsProfile(target.profileID) else { return false }
		return store.workspace.tabs[id: target.tabID]?.profileID == target.profileID
	}

	internal var interaction: BrowserPageInteractionClient {
		.init(
			isAvailable: { [weak self] in self?.interactionAvailable == true },
			clickAuthorized: { [weak self] request, inspection, authorize in
				guard let self, interactionAvailable else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .notReady)
				}
				guard ownsInspectionSource(inspection.source) else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
				}

				return await nativeInteraction.clickAuthorized(request, inspection) { [weak self] in
					self?.interactionAvailable == true
					&& self?.ownsInspectionSource(inspection.source) == true
					&& authorize()
				}
			},
			keypressIsAvailable: { [weak self] in self?.keypressAvailable == true },
			formIsAvailable: { [weak self] in self?.formAvailable == true },
			formAuthorized: { [weak self] request, inspection, authorize in
				guard
					let self,
					formAvailable,
					request.kind != .keyPress || keypressAvailable
				else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .notReady)
				}
				guard ownsInspectionSource(inspection.source) else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
				}

				return await nativeInteraction.formAuthorized(request, inspection) { [weak self] in
					self?.formAvailable == true
					&& (request.kind != .keyPress || self?.keypressAvailable == true)
					&& self?.ownsInspectionSource(inspection.source) == true
					&& authorize()
				}
			},
			scrollIsAvailable: { [weak self] in self?.scrollAvailable == true },
			scrollAuthorized: { [weak self] request, inspection, authorize in
				guard let self, scrollAvailable else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .notReady)
				}
				guard ownsInspectionSource(inspection.source) else {
					return .init(operationID: request.operationID, disposition: .notDispatched, failure: .denied)
				}

				return await nativeInteraction.scrollAuthorized(request, inspection) { [weak self] in
					self?.scrollAvailable == true
					&& self?.ownsInspectionSource(inspection.source) == true
					&& authorize()
				}
			}
		)
	}

	private var scrollAvailable: Bool { isReady && nativeInteraction.scrollIsAvailable() }

	private var keypressAvailable: Bool { isReady && nativeInteraction.keypressIsAvailable() }

	private var formAvailable: Bool { isReady && nativeInteraction.formIsAvailable() }

	private var interactionAvailable: Bool { isReady && nativeInteraction.isAvailable() }

	private var inspectionAvailable: Bool { isReady && nativeInspection.isAvailable() }

	private func ownsCaptureInspectionSource(_ source: PageInspectionSource) -> Bool {
		guard let store, ownsProfile(source.profileID) else { return false }
		return store.captureSessions.contains { $0.inspection == source }
	}

	private func ownsInspectionSource(_ source: PageInspectionSource) -> Bool {
		guard let store, ownsProfile(source.profileID) else { return false }
		return store.workspace.tabs[id: source.tabID]?.profileID == source.profileID
	}

	internal var extensions: BrowserExtensionsClient {
		.init(
			optionsAvailability: { [weak self] in self?.extensionOptionsAvailable == true },
			openOptions: { [weak self] request in
				try Task.checkCancellation()

				guard let self, extensionOptionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let inventory = try await nativeExtensions.openOptions(request)
				try Task.checkCancellation()

				guard extensionOptionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				return inventory
			},
			availability: { [weak self] in self?.extensionsAvailable == true },
			installationAvailability: { [weak self] in
				self?.extensionInstallationAvailable == true
			},
			inspect: { [weak self] profileID in
				try Task.checkCancellation()

				guard let self, extensionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let inventory = try await nativeExtensions.inspect(profileID)
				try Task.checkCancellation()

				guard extensionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				return inventory
			},
			manage: { [weak self] request in
				try Task.checkCancellation()

				guard let self, extensionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let inventory = try await nativeExtensions.manage(request)
				try Task.checkCancellation()

				guard extensionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				return inventory
			},
			prepareInstallation: { [weak self] request in
				try Task.checkCancellation()
				guard let self, extensionInstallationAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let prompt = try await nativeExtensions.prepareInstallation(request)
				do {
					try Task.checkCancellation()
					guard extensionInstallationAvailable
					else { throw BrowserExtensionsClient.Failure.unavailable }
					guard ownsProfile(request.profileID), prompt.profileID == request.profileID
					else { throw BrowserExtensionsClient.Failure.missingProfile }
				} catch {
					nativeExtensions.cancelInstallation(prompt)
					throw error
				}
				return prompt
			},
			resolveInstallation: { [weak self] prompt, accept in
				guard let self else { throw BrowserExtensionsClient.Failure.unavailable }
				do {
					try Task.checkCancellation()
					guard extensionInstallationAvailable
					else { throw BrowserExtensionsClient.Failure.unavailable }
					guard ownsProfile(prompt.profileID)
					else { throw BrowserExtensionsClient.Failure.missingProfile }
				} catch {
					nativeExtensions.cancelInstallation(prompt)
					throw error
				}
				let inventory = try await nativeExtensions.resolveInstallation(prompt, accept)
				try Task.checkCancellation()
				guard extensionInstallationAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(prompt.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				return inventory
			},
			cancelInstallation: { [weak self] in self?.nativeExtensions.cancelInstallation($0) },
			unpackedAvailability: { [weak self] in self?.extensionUnpackedAvailable == true },
			loadUnpacked: { [weak self] request in
				try Task.checkCancellation()

				guard let self, extensionUnpackedAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let inventory = try await nativeExtensions.loadUnpacked(request)
				try Task.checkCancellation()

				guard extensionsAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				return inventory
			},
			// DEV-801: without these the app's client fell back to its defaults, so the
			// Chrome Web Store button stayed hidden and Add to Chrome never reached the sheet.
			webstoreAvailability: { [weak self] in self?.extensionWebstoreAvailable == true },
			webstoreInstallRequests: { [weak self] in
				guard let self, extensionWebstoreAvailable
				else { return AsyncStream { $0.finish() } }

				let native = nativeExtensions
				return observe(native.webstoreInstallRequests(), limit: 4) { [weak self] request in
					guard self?.ownsProfile(request.profileID) == true else {
						native.declineWebstoreInstallation(request)
						return nil
					}
					return request
				}
			},
			prepareWebstoreInstallation: { [weak self] request, inventory in
				guard let self else { throw BrowserExtensionsClient.Failure.unavailable }
				do {
					try Task.checkCancellation()
					guard extensionWebstoreAvailable
					else { throw BrowserExtensionsClient.Failure.unavailable }
					guard ownsProfile(request.profileID)
					else { throw BrowserExtensionsClient.Failure.missingProfile }
				} catch {
					nativeExtensions.declineWebstoreInstallation(request)
					throw error
				}

				let prompt = try await nativeExtensions.prepareWebstoreInstallation(request, inventory)
				do {
					try Task.checkCancellation()
					guard extensionWebstoreAvailable
					else { throw BrowserExtensionsClient.Failure.unavailable }
					guard ownsProfile(request.profileID), prompt.profileID == request.profileID
					else { throw BrowserExtensionsClient.Failure.missingProfile }
				} catch {
					nativeExtensions.cancelInstallation(prompt)
					throw error
				}
				return prompt
			},
			declineWebstoreInstallation: { [weak self] in
				self?.nativeExtensions.declineWebstoreInstallation($0)
			},
			// DEV-776: forwarded like installs, or Check for Updates and the periodic
			// check never see the capability.
			webstoreUpdateAvailability: { [weak self] in self?.extensionWebstoreUpdateAvailable == true },
			prepareWebstoreUpdate: { [weak self] request in
				try Task.checkCancellation()
				guard let self, extensionWebstoreUpdateAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let prompt = try await nativeExtensions.prepareWebstoreUpdate(request)
				do {
					try Task.checkCancellation()
					guard extensionWebstoreUpdateAvailable
					else { throw BrowserExtensionsClient.Failure.unavailable }
					guard ownsProfile(request.profileID), prompt.profileID == request.profileID
					else { throw BrowserExtensionsClient.Failure.missingProfile }
				} catch {
					nativeExtensions.cancelInstallation(prompt)
					throw error
				}
				return prompt
			},
			// DEV-845: extensions brought over from another browser, checked like updates.
			webstoreImportAvailability: { [weak self] in self?.extensionWebstoreImportAvailable == true },
			prepareWebstoreImport: { [weak self] request in
				try Task.checkCancellation()
				guard let self, extensionWebstoreImportAvailable
				else { throw BrowserExtensionsClient.Failure.unavailable }
				guard ownsProfile(request.profileID)
				else { throw BrowserExtensionsClient.Failure.missingProfile }

				let prompt = try await nativeExtensions.prepareWebstoreImport(request)
				do {
					try Task.checkCancellation()
					guard extensionWebstoreImportAvailable
					else { throw BrowserExtensionsClient.Failure.unavailable }
					guard ownsProfile(request.profileID), prompt.profileID == request.profileID
					else { throw BrowserExtensionsClient.Failure.missingProfile }
				} catch {
					nativeExtensions.cancelInstallation(prompt)
					throw error
				}
				return prompt
			},
			// Without it the app's client fell back to its default, which reads nothing, so every
			// extension tile showed its letter in place of the icon the engine reported (DEV-824).
			icon: { [weak self] path in
				guard let icon = await self?.extensionIcon else { return nil }

				return await icon(path)
			},
			// DEV-884. BrowserWindow also sets it on the runtime before the engine starts.
			setContentBlocking: { [weak self] isOn, cookieBanners in
				self?.nativeExtensions.setContentBlocking(isOn, cookieBanners)
			}
		)
	}

	private var extensionsAvailable: Bool { isReady && nativeExtensions.isAvailable }

	/// The engine's icon reader while extensions are available.
	private var extensionIcon: (@Sendable (String) async -> Data?)? {
		extensionsAvailable ? nativeExtensions.icon : nil
	}

	private var extensionUnpackedAvailable: Bool {
		extensionsAvailable && nativeExtensions.unpackedAvailability()
	}

	private var extensionOptionsAvailable: Bool {
		extensionsAvailable && nativeExtensions.optionsAvailability()
	}

	private var extensionInstallationAvailable: Bool {
		extensionsAvailable && nativeExtensions.isInstallationAvailable
	}

	private var extensionWebstoreAvailable: Bool {
		extensionsAvailable && nativeExtensions.isWebstoreAvailable
	}

	private var extensionWebstoreUpdateAvailable: Bool {
		extensionsAvailable && nativeExtensions.isWebstoreUpdateAvailable
	}

	private var extensionWebstoreImportAvailable: Bool {
		extensionsAvailable && nativeExtensions.isWebstoreImportAvailable
	}

	internal var media: BrowserMediaClient {
		.init(
			availability: { [weak self] in self?.mediaAvailable == true },
			events: { [weak self] in
				guard let self, mediaAvailable
				else { return .finished }

				return observe(nativeMedia.events(), limit: 1) { [weak self] snapshot in
					.init(
						revision: snapshot.revision,
						sources: snapshot.sources.filter {
							!$0.isPrivate && self?.ownsSource($0.id) == true
						}
					)
				}
			},
			activations: { [weak self] in
				guard let self, mediaAvailable
				else { return .finished }

				return observe(nativeMedia.activations(), limit: 16) { [weak self] id in
					self?.canControlSource(id) == true ? id : nil
				}
			},
			isSourceCurrent: { [weak self] id in
				guard
					let self,
					mediaAvailable,
					canControlSource(id)
				else { return false }

				return nativeMedia.isSourceCurrent(id)
			},
			perform: { [weak self] request in
				try Task.checkCancellation()

				guard let self, mediaAvailable
				else { throw BrowserMediaClient.Failure.unavailable }
				guard canControlSource(request.sourceID)
				else { throw BrowserMediaClient.Failure.staleSource }

				try await nativeMedia.perform(request)
				try Task.checkCancellation()

				guard mediaAvailable
				else { throw BrowserMediaClient.Failure.unavailable }
				guard canControlSource(request.sourceID)
				else { throw BrowserMediaClient.Failure.staleSource }
			},
			position: { [weak self] tabID in
				guard
					let self,
					mediaAvailable,
					ownsTab(tabID)
				else { return nil }

				return nativeMedia.position(tabID)
			},
			// Tab-level audio (DEV-690, DEV-800) isn't tied to a media source, so it's authorized by the tab.
			setMuted: { [weak self] tabID, isMuted in
				guard let self, mediaAvailable
				else { throw BrowserMediaClient.Failure.unavailable }
				guard canControlTab(tabID)
				else { throw BrowserMediaClient.Failure.staleSource }

				try nativeMedia.setMuted(tabID, isMuted)
			},
			supportsVolume: { [weak self] in
				guard let self, mediaAvailable
				else { return false }

				return nativeMedia.supportsVolume()
			},
			setVolume: { [weak self] tabID, volume in
				guard let self, mediaAvailable
				else { throw BrowserMediaClient.Failure.unavailable }
				guard canControlTab(tabID)
				else { throw BrowserMediaClient.Failure.staleSource }

				try nativeMedia.setVolume(tabID, volume)
			}
		)
	}

	private var mediaAvailable: Bool { isReady && nativeMedia.isAvailable }

	internal func activate() {
		guard
			!activated,
			!stopped,
			isRunning(),
			store != nil
		else { return }

		activated = true
		nativeExtensions = makeExtensions { [weak self] in self?.ownsProfile($0) == true }

		// Unavailable media does not disable capture or extension management.
		nativeMedia = withErrorReporting("Native media initialization failed.") {
			try makeMedia()
		} ?? .init()
	}

	internal func stop() {
		stopped = true
		for scope in store?.automation.inspectionScopes.values.map(\.id) ?? [] {
			nativeInspection.revokeScope(scope)
		}

		for task in observationTasks.values { task.cancel() }
		for finish in finishObservations.values { finish() }
		observationTasks.removeAll()
		finishObservations.removeAll()

		nativeMedia = .init()
		nativeExtensions = .init()
	}

	private func ownsProfile(_ id: Profile.ID) -> Bool {
		isReady && store?.workspace.profiles.ids.contains(id) == true
	}

	private func ownsSource(_ id: BrowserMediaSource.ID) -> Bool {
		guard let tab = ownedTab(id.tabID)
		else { return false }

		return tab.profileID == id.profileID
	}

	private func ownsTab(_ id: BrowserCore.Tab.ID) -> Bool {
		ownedTab(id) != nil
	}

	private func ownedTab(_ id: BrowserCore.Tab.ID) -> BrowserCore.Tab? {
		guard isReady, let store
		else { return nil }

		let tabs = store.workspace.tabs + store.littleWindows.map(\.tab) + store.peeks.map(\.tab)
		guard
			let tab = tabs.first(where: { $0.id == id }),
			ownsProfile(tab.profileID)
		else { return nil }

		return tab
	}

	private func canControlSource(_ id: BrowserMediaSource.ID) -> Bool {
		// Canceling quit may produce no new native snapshot, so observations retain ownership.
		ownsSource(id) && store?.checkingQuit == false
	}

	private func canControlTab(_ id: BrowserCore.Tab.ID) -> Bool {
		ownsTab(id) && store?.checkingQuit == false
	}

	private func observe<Value: Sendable>(
		_ source: AsyncStream<Value>,
		limit: Int,
		transform: @escaping @MainActor @Sendable (Value) -> Value?
	) -> AsyncStream<Value> {
		let id = UUID()
		let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(limit))

		let task = Task { [weak self] in
			for await value in source {
				guard !Task.isCancelled, self?.isReady == true
				else { break }

				if let value = transform(value) { continuation.yield(value) }
			}

			continuation.finish()
			self?.observationTasks[id] = nil
			self?.finishObservations[id] = nil
		}

		observationTasks[id] = task
		finishObservations[id] = { continuation.finish() }
		continuation.onTermination = { [weak self] _ in
			Task { @MainActor [weak self] in
				self?.observationTasks.removeValue(forKey: id)?.cancel()
				self?.finishObservations[id] = nil
			}
		}

		return stream
	}
}
