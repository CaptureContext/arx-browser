import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

extension BrowserAutomation {
	/// Prints the page to PDF or reads the text of the PDF document it shows.
	/// The tab is never shown, focused or selected.
	internal func pdf(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .pdf(request) = pending.request.operation,
			let tab = state.workspace.tabs[id: .init(rawValue: request.targetID)],
			let snapshot = pending.snapshots[tab.id],
			let documentRevision = snapshot.documentRevision
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		@Dependency(\.browserCapture)
		var capture

		state.automation.pending[requestID]?.executing = true
		let native = PagePDFRequest(
			tabID: tab.id,
			revision: snapshot.revision,
			documentRevision: documentRevision,
			kind: request.kind == .export
			? .export(landscape: request.landscape, printsBackground: request.printsBackground, scale: request.scale)
			: .source,
			maximumBytes: request.kind == .export ? AutomationPDFRequest.maximumExportBytes : 33_554_432
		)
		return .run { [control] send in
			do {
				try Task.checkCancellation()
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				guard await capture.pdfIsAvailable()
				else { throw AutomationFailure.unsupported }

				let pdf = try await capture.pdfAuthorized(native) { control.authorize(requestID) }
				let result = try Self.pdfResult(pdf, request: request, profileID: tab.profileID)
				try result.validate()

				try Task.checkCancellation()
				guard await control.authorize(requestID)
				else { throw AutomationFailure.denied }
				await send(.automation(.event(.finished(requestID, .pdf(result)))))

			} catch is CancellationError {
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))

			} catch {
				await send(.automation(.event(.finished(requestID, .failure(Self.pdfFailure(error))))))
			}
		}
		.cancellable(id: requestID)
	}

	private static func pdfResult(
		_ pdf: PagePDF,
		request: AutomationPDFRequest,
		profileID: Profile.ID
	) throws -> AutomationPDFResult {
		switch request.kind {
		case .export:
			return .init(
				request: request,
				profileID: profileID,
				documentRevision: pdf.request.documentRevision,
				documentID: pdf.documentID,
				data: pdf.data,
				totalBytes: pdf.data.count,
				pageCount: PagePDFText.extract(pdf.data)?.pageCount ?? 0,
				digest: pdf.digest
			)

		case .text:
			guard let document = PagePDFText.extract(pdf.data)
			else { throw AutomationFailure.unsupported }
			guard let (chunk, next) = PagePDFText.chunk(
				document.text,
				offset: request.offset,
				maximumBytes: request.maximumBytes
			)
			else { throw AutomationFailure.staleCursor }

			return .init(
				request: request,
				profileID: profileID,
				documentRevision: pdf.request.documentRevision,
				documentID: pdf.documentID,
				text: chunk,
				totalBytes: document.text.utf8.count,
				nextOffset: next,
				pageCount: document.pageCount,
				digest: pdf.digest
			)
		}
	}

	private static func pdfFailure(_ error: any Error) -> AutomationFailure {
		if let failure = error as? AutomationFailure { return failure }
		guard let failure = error as? PageCaptureFailure else { return .engineFailed }
		switch failure {
		case .unavailable: return .notReady
		case .busy: return .busy
		case .staleDocument: return .staleTarget
		case .limitExceeded: return .limitExceeded
		case .timedOut: return .timedOut
		case .unsupportedRendering: return .unsupported
		case .invalidRegion, .invalidFormat: return .invalidRequest
		case .invalidImage, .encodingFailed: return .engineFailed
		}
	}

	/// Native find in page. Waits at most 2 seconds for the page's result.
	internal func findInPage(
		requestID: UUID,
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[requestID],
			case let .findInPage(request) = pending.request.operation,
			let tab = state.workspace.tabs[id: .init(rawValue: request.targetID)],
			let snapshot = pending.snapshots[tab.id]
		else { return finish(requestID, result: .failure(.staleTarget), state: &state) }

		let command: BrowserEngineClient.Command
		if request.stop {
			command = .stopFind
			state.automation.findInPageTexts[tab.id] = nil
		} else if let text = request.text {
			command = .find(text, forward: request.forward, newSession: true)
			state.automation.findInPageTexts[tab.id] = text
		} else if let text = state.automation.findInPageTexts[tab.id] {
			command = .find(text, forward: request.forward, newSession: false)
		} else {
			return finish(requestID, result: .failure(.invalidRequest), state: &state)
		}

		state.automation.pending[requestID]?.executing = true
		let previous = snapshot.navigation.findResult
		return .run { [engine, control, clock] send in
			do {
				let events = await engine.events(tab.id)
				try await engine.commandAuthorized(tab.id, snapshot.revision, command) {
					control.authorize(requestID)
				}
				var observed: BrowserNavigation.FindResult?
				if !request.stop {
					observed = await withTaskGroup(of: BrowserNavigation.FindResult?.self) { group in
						group.addTask {
							for await navigation in events {
								if let result = navigation.findResult, result != previous { return result }
							}
							return nil
						}
						group.addTask {
							try? await clock.sleep(for: .seconds(2))
							return nil
						}
						let first = await group.next() ?? nil
						group.cancelAll()
						return first
					}
				}
				let result = AutomationFindInPageResult(
					targetID: request.targetID,
					matches: observed?.matches,
					active: observed.flatMap { $0.matches > 0 ? $0.active : nil },
					stopped: request.stop
				)
				await send(.automation(.event(.finished(requestID, .findInPage(result)))))

			} catch is CancellationError {
				await send(.automation(.event(.finished(requestID, .failure(.cancelled)))))

			} catch {
				let failure = error as? AutomationFailure ?? .engineFailed
				await send(.automation(.event(.finished(requestID, .failure(failure)))))
			}
		}
		.cancellable(id: requestID)
	}
}

extension AppFeature.State {
	/// Whether the client may still reach the tab and its profile still exists.
	internal func automationPermitsLiveTab(
		_ targetID: UUID,
		client: AutomationClient
	) -> Bool {
		let tabID = Tab.ID(rawValue: targetID)
		guard
			AutomationAccess.permitsTab(tabID, client: client, organization: workspace),
			let tab = workspace.tabs[id: tabID]
		else { return false }

		return workspace.profiles.ids.contains(tab.profileID)
	}

	/// Shared by PDF reads, native find and dialogs: a permitted, loaded ordinary page.
	///
	/// Pass a nil `expectedRevision` only for a reply whose own action moved the
	/// tab's revision, such as a find updating the page's find state.
	internal func automationPageValidation(
		targetID: UUID,
		expectedRevision: String?,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allowsRead, client.allowsPageContent else { return .denied }
		guard automationPermitsLiveTab(targetID, client: client) else { return .denied }

		let tabID = Tab.ID(rawValue: targetID)

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
			!windows.contains(where: isBusy)
		else { return .busy }

		if let expectedRevision {
			let item = AutomationInventoryBuilder.item(
				targetID,
				client: client,
				organization: workspace,
				snapshots: snapshots
			)
			guard item?.revision == expectedRevision
			else { return .staleTarget }
		}
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
		guard !snapshot.navigation.requiresUserAction
		else { return .userActionRequired }
		guard snapshot.navigation.errorCode == nil, !snapshot.navigation.isLoading
		else { return .notReady }
		return nil
	}

	internal func automationPDFValidation(
		_ request: AutomationPDFRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		return automationPageValidation(
			targetID: request.targetID,
			expectedRevision: request.expectedRevision,
			client: client,
			snapshots: snapshots
		)
	}

	internal func automationFindInPageValidation(
		_ request: AutomationFindInPageRequest,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allows([.read, .pageContent, .interact]) else { return .denied }
		do {
			try request.validate()
		} catch {
			return .invalidRequest
		}
		return automationPageValidation(
			targetID: request.targetID,
			expectedRevision: request.expectedRevision,
			client: client,
			snapshots: snapshots
		)
	}

	/// A PDF is page content: it's released only for the document it was made
	/// from, in the profile the tab still belongs to.
	internal func automationPDFResponseValidation(
		_ request: AutomationPDFRequest,
		response: AutomationPDFResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		if let failure = automationPDFValidation(request, client: client, snapshots: snapshots) {
			return failure
		}
		guard
			response.request == request,
			let tab = workspace.tabs[id: .init(rawValue: request.targetID)],
			response.profileID == tab.profileID,
			let snapshot = snapshots[tab.id],
			response.documentRevision == snapshot.documentRevision
		else { return .staleTarget }

		do {
			try response.validate()
			return nil
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}
	}

	/// Finding updates the page's find state, which moves the tab's revision, so
	/// the reply is checked against the page as it is now rather than the request's revision.
	internal func automationFindInPageResponseValidation(
		_ request: AutomationFindInPageRequest,
		response: AutomationFindInPageResult,
		client: AutomationClient,
		snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	) -> AutomationFailure? {
		guard client.allows([.read, .pageContent, .interact]) else { return .denied }
		do {
			try request.validate()
			try response.validate()
		} catch {
			return error as? AutomationFailure ?? .invalidRequest
		}
		guard
			response.targetID == request.targetID,
			response.stopped == request.stop
		else { return .invalidRequest }

		return automationPageValidation(
			targetID: request.targetID,
			expectedRevision: nil,
			client: client,
			snapshots: snapshots
		)
	}
}
