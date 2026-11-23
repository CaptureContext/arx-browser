import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import Foundation
import MainFeature
import _ComposableArchitecture

extension BrowserAutomation {
	internal func capture(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .capture(request) = pending.request.operation,
			let tab = state.workspace.tabs.first(where: { $0.id.rawValue == request.targetID }),
			let snapshot = pending.snapshots[tab.id],
			let documentRevision = snapshot.documentRevision
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		@Dependency(\.browserCapture)
		var capture

		@Dependency(\.pageCaptureExport)
		var export

		// An element capture crops to the bounds the connection's latest snapshot
		// reported for that reference, in that same document.
		var elementSource: (inspection: AutomationInspectionResult, bounds: PageCaptureRegion)?
		if let element = request.element {
			let released = state.automation.releasedInspections.first {
				$0.request.sessionID == pending.request.sessionID
				&& $0.result.source.tabID == tab.id
				&& $0.result.snapshot.snapshotID == element.snapshotID
				&& $0.expiresAt > now
			}
			guard
				let released,
				released.result.source.documentRevision == documentRevision,
				let node = released.result.snapshot.nodes.first(where: { $0.reference == element.reference }),
				let bounds = node.bounds
			else { return finish(requestID, result: .failure(.staleReference), state: &state) }

			elementSource = (released.result, bounds)
		}

		state.automation.pending[requestID]?.executing = true
		let snapshotID = uuid()
		let title = tab.customTitle ?? (snapshot.navigation.title.isEmpty ? tab.displayTitle : snapshot.navigation.title)
		let nativeRequest = PageCaptureRequest(
			tabID: tab.id,
			revision: snapshot.revision,
			// The native frame may exceed the delivered cap; scale and JPEG shrink it below.
			limits: .init(maximumEncodedBytes: 16 * 1024 * 1024),
			mode: request.mode == .fullDocument ? .fullDocument : .viewport,
			documentRevision: documentRevision,
			ordinaryProfileID: tab.profileID,
			offscreen: request.offscreen
		)

		return .run { [control, pageInspection, elementSource] send in
			do {
				try Task.checkCancellation()
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				guard await capture.isAvailable()
				else { throw AutomationFailure.unsupported }
				if request.offscreen {
					guard await capture.offscreenIsAvailable()
					else { throw AutomationFailure.unsupported }
				}
				if request.mode == .fullDocument {
					guard await capture.fullDocumentIsAvailable()
					else { throw AutomationFailure.unsupported }
				}

				let frame = try await capture.captureAuthorized(nativeRequest) {
					control.authorize(requestID)
				}
				guard frame.request == nativeRequest
				else { throw AutomationFailure.staleTarget }
				try frame.validate()
				_ = try PageCaptureCodec.decode(frame.image, limits: nativeRequest.limits)
				var region = request.region
				if let elementSource {
					guard await pageInspection.documentIsCurrent(elementSource.inspection)
					else { throw AutomationFailure.staleReference }

					region = try Self.visibleRegion(elementSource.bounds, frame: frame)
				}
				let cropped = try region.map { try capture.crop(frame, $0) } ?? frame.image
				let image = try Self.deliveredImage(cropped, for: request)
				let save: AutomationCaptureResult.SaveOutcome? = if request.save {
					try await Self.save(image, title: title, export: export) {
						await control.authorize(requestID)
					}
				} else {
					nil
				}
				let result = AutomationCaptureResult(
					request: request,
					profileID: tab.profileID,
					sessionRevision: snapshot.revision,
					documentRevision: documentRevision,
					documentID: frame.documentID,
					snapshotID: snapshotID,
					image: image,
					viewportWidth: frame.viewportWidth,
					viewportHeight: frame.viewportHeight,
					deviceScale: frame.deviceScale,
					wasLoading: frame.wasLoading,
					documentGeometry: frame.documentGeometry,
					elementRegion: elementSource == nil ? nil : region,
					save: save
				)
				try result.validate()
				let encoded = try JSONEncoder().encode(AutomationIPC.Reply.result(.capture(result)))
				guard encoded.count <= AutomationIPC.maximumImageResponseBytes
				else { throw AutomationFailure.limitExceeded }

				try Task.checkCancellation()
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				await send(.automation(.event(.finished(requestID, .capture(result)))))

			} catch is CancellationError {
				// Cancellation removes only the request; no image is published or retained.
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))

			} catch {
				let failure = Self.captureFailure(error)
				await send(.automation(.event(.finished(requestID, .failure(failure)))))
			}
		}
		.cancellable(id: requestID)
	}

	/// Asks the person where to save the delivered image and writes it there.
	/// Authority is checked again after the panel, which may stay open for a while.
	private static func save(
		_ image: AutomationCaptureImage,
		title: String,
		export: PageCaptureExportClient,
		authorize: @Sendable () async -> Bool
	) async throws -> AutomationCaptureResult.SaveOutcome {
		guard await authorize() else { throw AutomationFailure.denied }

		let format: PageCaptureFormat = switch image.format {
		case .png: .png
		case .jpeg: .jpeg(quality: 1)
		}
		guard let destination = try await export.chooseDestination(title, format)
		else { return .declined }

		try Task.checkCancellation()
		guard await authorize() else { throw AutomationFailure.denied }
		try await export.write(image.data, destination)
		return .saved(fileName: destination.lastPathComponent)
	}

	/// An element's bounds clamped to the captured viewport; an element entirely
	/// off screen has nothing to capture.
	private static func visibleRegion(
		_ bounds: PageCaptureRegion,
		frame: PageCaptureFrame
	) throws -> PageCaptureRegion {
		let x = max(0, bounds.x)
		let y = max(0, bounds.y)
		let right = min(frame.viewportWidth, bounds.x + bounds.width)
		let bottom = min(frame.viewportHeight, bounds.y + bounds.height)
		guard right > x, bottom > y else { throw AutomationFailure.notInteractable }
		return .init(x: x, y: y, width: right - x, height: bottom - y)
	}

	/// The native PNG unchanged, or scaled and re-encoded as the request asks.
	private static func deliveredImage(
		_ image: PageCaptureImage,
		for request: AutomationCaptureRequest
	) throws -> AutomationCaptureImage {
		if request.keepsNativeEncoding { return .init(image) }

		let format: PageCaptureFormat = switch request.format {
		case .png: .png
		case .jpeg: .jpeg(quality: request.quality ?? 0.8)
		}
		let encoded = try PageCaptureCodec.encode(image, scale: request.scale, as: format)
		return .init(
			data: encoded.data,
			format: request.format,
			width: encoded.width,
			height: encoded.height
		)
	}

	private static func captureFailure(_ error: any Error) -> AutomationFailure {
		if let failure = error as? AutomationFailure { return failure }
		guard let failure = error as? PageCaptureFailure else { return .engineFailed }
		switch failure {
		case .unavailable: return .notReady
		case .busy: return .busy
		case .staleDocument: return .staleTarget
		case .limitExceeded: return .limitExceeded
		case .invalidRegion: return .invalidRequest
		case .timedOut: return .timedOut
		case .unsupportedRendering: return .unsupported
		case .invalidImage, .encodingFailed, .invalidFormat: return .engineFailed
		}
	}
}

extension AppFeature.State {
	internal func automationCaptureValidation(
		_ request: AutomationCaptureRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allowsRead, client.allowsScreenshots else { return .denied }

		// Saving needs a person to choose the destination.
		guard !request.save || !automation.isUnattended else { return .userActionRequired }
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}

		let tabID = Tab.ID(rawValue: request.targetID)
		guard
			AutomationAccess.permitsTab(tabID, client: client, organization: workspace),
			let tab = workspace.tabs[id: tabID],
			workspace.profiles.ids.contains(tab.profileID)
		else { return .denied }

		func isBusy(_ host: MainFeature.State) -> Bool {
			host.transferInProgress
			|| host.isClosing
			|| host.pendingTabCloses.contains(tabID)
			|| host.pendingFolderDeletion != nil
			|| host.archive.isWorking
		}
		guard
			!settings.isManagingOrganization,
			!isBusy(main),
			!windows.contains(where: isBusy),
			!peeks.contains(where: { $0.tab.id == tabID })
		else { return .busy }

		let item = AutomationInventoryBuilder.item(
			request.targetID,
			client: client,
			organization: workspace,
			snapshots: snapshots
		)
		guard item?.revision == request.expectedRevision
		else { return .staleTarget }
		guard let snapshot = snapshots[tabID] else { return .notLoaded }

		// DEV-873: Arx unloaded its page to free memory; `load` brings it back.
		guard !snapshot.navigation.isUnloaded else { return .notLoaded }
		guard let documentRevision = snapshot.documentRevision, documentRevision > 0
		else { return .unsupported }
		guard
			let url = snapshot.navigation.url,
			url.hasWebScheme,
			url.host != nil
		else { return .unsupported }

		// An unattended run refused an HTTP authentication or sign-in prompt
		// nobody could answer.
		guard !snapshot.navigation.requiresUserAction
		else { return .userActionRequired }

		// An offscreen capture reads a loaded page that isn't on screen.
		guard snapshot.navigation.errorCode == nil, snapshot.isVisibleForCapture || request.offscreen
		else { return .notReady }
		return nil
	}
}
