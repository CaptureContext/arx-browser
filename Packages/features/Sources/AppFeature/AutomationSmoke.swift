#if DEBUG
import AppKit
import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Runs only after the runner proves ownership of a disposable profile and local HTTP fixture.
internal enum AutomationSmoke {
	/// State clears the published socket path synchronously; wait for the real host stop effect too.
	@MainActor
	internal static func disable(store: StoreOf<AppFeature>) async {
		await store.send(.automation(.ui(.enabled(false)))).finish()
	}

	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		profileDirectory: URL,
		fixtureRoot: URL
	) async throws {
		try AutomationSmokeFixture.validate(
			root: fixtureRoot,
			profile: profileDirectory,
			baseURL: baseURL,
			preferences: store.automationPreferences
		)
		guard
			!store.checkingQuit,
			!store.shouldQuit,
			store.peeks.isEmpty,
			!store.windows.contains(where: \.isPrivate),
			store.automation.pending.isEmpty,
			let source = store.main.viewer.item.tab,
			let originalURL = engine.client.snapshot(source.id)?.navigation.url,
			originalURL.scheme == baseURL.scheme,
			originalURL.host() == baseURL.host(),
			originalURL.port == baseURL.port,
			let location = AutomationAccess.location(of: source.id, in: store.workspace)
		else { throw AutomationSmokeFailure.missingSource }

		let run = Run(
			store: store,
			engine: engine,
			baseURL: baseURL,
			source: source,
			originalURL: originalURL,
			location: location
		)
		do {
			try await run.exercise()
			guard await run.cleanup() else { throw AutomationSmokeFailure.cleanupFailed }
			print("ARX_MCP_NATIVE_SMOKE_SUCCESS")
		} catch let mismatch as AutomationSmokeMismatch {
			_ = await run.cleanup()
			throw mismatch
		} catch let timeout as SmokeTimeout {
			_ = await run.cleanup()
			throw timeout
		} catch {
			let failure = error as? AutomationSmokeFailure ?? .helperFailed
			_ = await run.cleanup()
			throw failure
		}
	}
}

extension AutomationSmoke {
	/// Reasons the source couldn't be captured, each with when it started, in milliseconds.
	@MainActor
	private final class CaptureProbe {
		private var current: String?
		private var changes: [String] = []

		fileprivate init() {}

		fileprivate var sawBlocker: Bool { changes.contains { !$0.hasSuffix(":capturable") } }

		fileprivate var summary: String { changes.isEmpty ? "none" : changes.joined(separator: ",") }

		fileprivate func record(
			_ blocker: String?,
			at elapsed: Duration
		) {
			guard blocker != current else { return }

			current = blocker
			let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
			changes.append("\(milliseconds)ms:\(blocker ?? "capturable")")
		}
	}

	@MainActor
	private final class Run {
		private let store: StoreOf<AppFeature>
		private let engine: ChromiumBrowserEngine
		private let baseURL: URL
		private let source: BrowserCore.Tab
		private let originalURL: URL
		private let sourceLocation: AutomationTabLocation
		private let sourceSpace: Space.ID
		private let sourcePane: UUID
		private let profile: Profile.ID = .init(rawValue: UUID())
		private let space: Space.ID = .init(rawValue: UUID())
		private let folderSourceSpace: Space.ID = .init(rawValue: UUID())
		private let folderDestinationSpace: Space.ID = .init(rawValue: UUID())
		private var privateWindowID: UUID?
		private var privatePreparation: StoreTask?
		private var clientID: UUID?
		private var sessions: [AutomationSmokeSession] = []
		private var pending: Task<AutomationResult, Error>?
		private var cleaned: Bool = false

		internal init(
			store: StoreOf<AppFeature>,
			engine: ChromiumBrowserEngine,
			baseURL: URL,
			source: BrowserCore.Tab,
			originalURL: URL,
			location: AutomationTabLocation
		) {
			self.store = store
			self.engine = engine
			self.baseURL = baseURL
			self.source = source
			self.originalURL = originalURL
			self.sourceLocation = location
			self.sourceSpace = store.main.sidebar.spaceID
			self.sourcePane = store.main.viewer.activePaneID
		}

		internal func exercise() async throws {
			let excluded = try await makeExcludedPage()
			let privateTab = try await makePrivatePage()
			let start = url("start", sensitive: true)
			navigateSource(start)
			try await wait { self.sourceLoaded(start, title: "Arx MCP start") }

			store.send(.automation(.ui(.enabled(true))))
			try await wait { self.store.automation.socketPath != nil }
			store.send(.automation(.ui(.clientName("Disposable native smoke"))))
			store.send(.automation(.ui(.addClient)))
			try await wait {
				self.store.automationPreferences.clients.count == 1
				&& self.store.automation.configuration != nil
			}
			guard
				var client = store.automationPreferences.clients.first,
				let json = store.automation.configuration,
				let socket = store.automation.socketPath
			else { throw AutomationSmokeFailure.setupFailed }

			clientID = client.id
			let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ArxMCP")
			let configuration = try AutomationSmokeConfiguration(
				json: json,
				helper: helper,
				socket: socket,
				client: client
			)
			store.send(.automation(.ui(.dismissConfiguration)))
			client.scopes = [.tab(source.id, profileID: source.profileID, location: sourceLocation)]
			client.allowsRead = true
			client.allowsManagement = true
			client.mutationGrantUntil = Date().addingTimeInterval(90)
			await store.send(.automation(.ui(.updateClient(client)))).finish()

			// Wait for preference publication/revocation before creating the first IPC session.
			try await wait { self.store.automationPreferences.clients.first?.allowsRead == true }
			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			let focusedWindow = store.focusedWindowID
			let nativeBeforeRead = engine.client.snapshot(source.id)
			let initial = try await inventory(session, url: start, title: "Arx MCP start")
			guard
				store.focusedWindowID == focusedWindow,
				engine.client.snapshot(source.id) == nativeBeforeRead
			else { throw AutomationSmokeFailure.inventoryMismatch }

			let screenshotDenied = try await session.capture(.init(
				targetID: source.id.rawValue,
				expectedRevision: initial.revision,
				mode: .viewport
			))
			guard case .failure(.denied) = screenshotDenied
			else { throw AutomationSmokeFailure.authorizationFailed }

			let contentDenied = try await session.inspect(.init(
				targetID: source.id.rawValue,
				expectedRevision: initial.revision
			))
			guard case .failure(.denied) = contentDenied
			else { throw AutomationSmokeFailure.authorizationFailed }

			for tab in [excluded, privateTab] {
				let before = engine.client.snapshot(tab.id)
				let result = try await session.command(
					target: tab.id.rawValue,
					revision: initial.revision,
					url: url("revoked")
				)
				guard result == .failure(.denied), engine.client.snapshot(tab.id) == before
				else { throw AutomationSmokeFailure.authorizationFailed }
			}

			let next = url("next", sensitive: true)
			let operation = UUID()
			let navigated = try await session.command(
				id: operation,
				target: source.id.rawValue,
				revision: initial.revision,
				url: next
			)
			let expectedNavigation = AutomationCommandResult(
				operationID: operation,
				status: .acceptedLoading,
				targetID: source.id.rawValue
			)
			guard navigated == .command(expectedNavigation)
			else { throw AutomationSmokeFailure.navigationMismatch }

			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			let current = try await inventory(session, url: next, title: "Arx MCP next")
			guard current.revision != initial.revision
			else { throw AutomationSmokeFailure.navigationMismatch }

			let stale = try await session.command(
				target: source.id.rawValue,
				revision: initial.revision,
				url: url("revoked")
			)
			guard stale == .failure(.staleTarget), sourceLoaded(next, title: "Arx MCP next")
			else { throw AutomationSmokeFailure.authorizationFailed }

			// Updating a grant invalidates existing sessions. Reconnect with the same credential,
			// then revoke an actual native-target request while the normal approval UI is pending.
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			try await exerciseCapture(
				helper: helper,
				configuration: configuration,
				client: client,
				excluded: [excluded, privateTab]
			)
			try await exerciseInspection(
				helper: helper,
				configuration: configuration,
				client: client,
				excluded: [excluded, privateTab]
			)
			try await exerciseClick(
				helper: helper,
				configuration: configuration,
				client: client,
				excluded: [excluded, privateTab]
			)
			try await exerciseForm(
				helper: helper,
				configuration: configuration,
				client: client,
				excluded: [excluded, privateTab]
			)
			try await exerciseKeypress(
				helper: helper,
				configuration: configuration,
				client: client,
				excluded: [excluded, privateTab]
			)
			try await exerciseScroll(
				helper: helper,
				configuration: configuration,
				client: client,
				excluded: [excluded, privateTab]
			)
			try await exerciseWait(
				helper: helper,
				configuration: configuration,
				client: client
			)
			try await exerciseOrganization(
				helper: helper,
				configuration: configuration,
				client: client
			)
			guard let slowDownload = URL(string: "/downloads/slow?smoke=mcp", relativeTo: baseURL)?.absoluteURL
			else { throw AutomationSmokeFailure.setupFailed }
			try await AutomationDownloadSmoke.run(
				store: store,
				session: { try self.makeSession(helper: helper, configuration: configuration) },
				client: client,
				profileID: source.profileID,
				url: slowDownload
			)
			try await AutomationSettingsSmoke.run(
				store: store,
				session: { try self.makeSession(helper: helper, configuration: configuration) },
				client: client,
				profileID: source.profileID,
				spaceID: sourceSpace
			)
			guard let developerPage = URL(string: "/developer/page", relativeTo: baseURL)?.absoluteURL
			else { throw AutomationSmokeFailure.setupFailed }
			try await AutomationDeveloperSmoke.run(
				store: store,
				session: { try self.makeSession(helper: helper, configuration: configuration) },
				client: client,
				tab: source,
				page: developerPage,
				navigate: { self.navigateSource($0) },
				pageLoaded: { self.sourceLoaded(developerPage, title: "Arx developer") },
				restore: {
					self.navigateSource(next)
					try await self.wait { self.sourceLoaded(next, title: "Arx MCP next") }
				}
			)
			client.mutationGrantUntil = nil
			await store.send(.automation(.ui(.updateClient(client)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let approvalSession = try makeSession(helper: helper, configuration: configuration)
			try await approvalSession.connect(grantedBy: store.automationPreferences)
			let fresh = try await inventory(approvalSession, url: next, title: "Arx MCP next")
			let blockedOperation = UUID()
			let target = source.id.rawValue
			let blockedURL = url("revoked")
			pending = Task {
				try await approvalSession.command(
					id: blockedOperation,
					target: target,
					revision: fresh.revision,
					url: blockedURL
				)
			}
			try await wait {
				self.store.automation.pending.values.contains {
					guard case let .command(command) = $0.request.operation else { return false }
					return command.operationID == blockedOperation && $0.awaitingApproval
				}
			}
			guard sourceLoaded(next, title: "Arx MCP next")
			else { throw AutomationSmokeFailure.authorizationFailed }

			store.send(.automation(.ui(.revokeClient(client.id))))
			guard let pending else { throw AutomationSmokeFailure.setupFailed }
			let rejected = try await pending.value
			self.pending = nil
			guard
				case let .failure(reason) = rejected,
				[.disconnected, .denied, .invalidCredential].contains(reason)
			else { throw AutomationSmokeFailure.authorizationFailed }

			try await wait {
				self.store.automation.pending.isEmpty
				&& self.store.automation.sessions.isEmpty
			}
			guard
				try await approvalSession.inventory() == .failure(.invalidCredential),
				sourceLoaded(next, title: "Arx MCP next")
			else { throw AutomationSmokeFailure.authorizationFailed }

			guard await approvalSession.close() else { throw AutomationSmokeFailure.helperFailed }
			let revokedSession = try makeSession(helper: helper, configuration: configuration)
			try await revokedSession.verifyCredentialRejected()
			guard await revokedSession.close() else { throw AutomationSmokeFailure.helperFailed }
		}

		private func exerciseCapture(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient,
			excluded: [BrowserCore.Tab]
		) async throws {
			var scoped = client
			scoped.allowsScreenshots = true
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }

			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			let captureURL = baseURL.deletingLastPathComponent().appendingPathComponent("capture/viewport.html")

			// Fixture setup selects its own host before testing a strictly focus-free read.
			store.send(.ui(.focusWindow(store.main.id)))
			navigateSource(captureURL)
			try await wait {
				self.sourceLoaded(captureURL, title: "Arx capture viewport")
				&& self.engine.client.snapshot(self.source.id)?.isVisibleForCapture == true
			}
			let item = try await inventory(session, url: captureURL, title: "Arx capture viewport")
			let request = AutomationCaptureRequest(
				targetID: source.id.rawValue,
				expectedRevision: item.revision,
				mode: .viewport
			)
			guard
				let original = engine.client.snapshot(source.id),
				let documentRevision = original.documentRevision
			else { throw AutomationSmokeFailure.missingSource }
			let focusedWindow = store.focusedWindowID
			let viewport = try await capture("viewport", request, session: session)
			try AutomationCaptureSmoke.verifyPixels(viewport, region: false)

			var crop = request
			crop.mode = .region
			crop.region = .init(x: 40, y: 140, width: 20, height: 20)
			let region = try await capture("region", crop, session: session)
			try AutomationCaptureSmoke.verifyPixels(region, region: true)
			let horizontalScale = Double(viewport.image.width) / viewport.metadata.viewportWidth
			let verticalScale = Double(viewport.image.height) / viewport.metadata.viewportHeight
			try require(
				"viewport.sessionRevision",
				viewport.metadata.sessionRevision,
				equals: String(original.revision)
			)
			try require("region.sessionRevision", region.metadata.sessionRevision, equals: String(original.revision))
			try require(
				"viewport.documentRevision",
				viewport.metadata.documentRevision,
				equals: String(documentRevision)
			)
			try require(
				"region.documentRevision",
				region.metadata.documentRevision,
				equals: String(documentRevision)
			)
			try require("region.documentID", region.metadata.documentID, equals: viewport.metadata.documentID)
			guard viewport.metadata.snapshotID != region.metadata.snapshotID else {
				throw mismatch("region.snapshotID", expected: "distinct", actual: "same as viewport")
			}

			try require(
				"region.imageWidth",
				region.image.width,
				equals: Int(ceil(60 * horizontalScale) - floor(40 * horizontalScale))
			)
			try require(
				"region.imageHeight",
				region.image.height,
				equals: Int(ceil(160 * verticalScale) - floor(140 * verticalScale))
			)
			try requireUnchanged("viewport.sourceSnapshot", original)
			try require("viewport.focusedWindowID", store.focusedWindowID, equals: focusedWindow)

			for tab in excluded {
				var denied = request
				denied.targetID = tab.id.rawValue
				guard case .failure(.denied) = try await session.capture(denied)
				else { throw AutomationSmokeFailure.authorizationFailed }
			}

			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			guard case .failure(.staleTarget) = try await session.capture(request)
			else { throw AutomationSmokeFailure.authorizationFailed }
			try await exerciseDocumentCapture(session: session, excluded: excluded)
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_CAPTURE_NATIVE_SMOKE_SUCCESS")
		}

		private func exerciseDocumentCapture(
			session: AutomationSmokeSession,
			excluded: [BrowserCore.Tab]
		) async throws {
			guard engine.capture.fullDocumentIsAvailable() else {
				throw mismatch("appDocument.available", expected: "true", actual: "false")
			}

			let documentURL = baseURL.deletingLastPathComponent().appendingPathComponent("capture/document.html")
			store.send(.ui(.focusWindow(store.main.id)))
			navigateSource(documentURL)
			try await wait {
				let snapshot = self.engine.client.snapshot(self.source.id)
				let title = snapshot?.navigation.title
				return self.sourceLoaded(documentURL)
				&& title?.hasPrefix("Arx capture document | 125,300,") == true
				&& snapshot?.isVisibleForCapture == true
			}
			guard let appOriginal = engine.client.snapshot(source.id)
			else { throw AutomationSmokeFailure.missingSource }
			let target = AppFeature.CommandTarget.window(
				store.main.id,
				paneID: store.main.viewer.activePaneID
			)
			let existing = Set(store.captureSessions.ids)

			// Capture Page… captures the whole page straight away and shows the menu.
			store.send(.ui(.capturePage(target, region: false)))
			try await wait {
				self.store.captureSessions.contains { session in
					!existing.contains(session.id) && session.phase == .captured
				}
			}
			guard let id = store.captureSessions.first(where: { !existing.contains($0.id) })?.id else {
				throw mismatch("appDocument.session", expected: "new capture session", actual: "none")
			}
			defer { store.send(.ui(.closeCapture(id))) }

			try require("appDocument.fullPage", store.captureSessions[id: id]?.isFullPage, equals: true)
			try require("appDocument.visibleAreaReason", store.captureSessions[id: id]?.visibleAreaReason, equals: nil)
			guard let full = store.captureSessions[id: id] else {
				throw mismatch("appDocument.capture", expected: "present", actual: "nil")
			}

			try require("appDocument.mode", full.request?.mode, equals: .fullDocument)
			guard let frame = full.frame else {
				throw mismatch("appDocument.frame", expected: "present", actual: "nil")
			}

			try require("appDocument.frameMode", frame.request.mode, equals: .fullDocument)
			guard full.image == frame.image else {
				throw mismatch(
					"appDocument.image",
					expected: "frame image \(frame.image.width)x\(frame.image.height)",
					actual: full.image.map { "\($0.width)x\($0.height), other pixels" } ?? "nil"
				)
			}
			guard let geometry = frame.documentGeometry else {
				throw mismatch("appDocument.geometry", expected: "present", actual: "nil")
			}

			try SmokeDiagnostics.focused {
				try AutomationCaptureSmoke.verifyDocument(
					image: frame.image,
					geometry: geometry,
					deviceScale: frame.deviceScale
				)
			}
			print("ARX_APP_DOCUMENT_CAPTURE_FULL_PREVIEW")
			let documentID = frame.documentID
			let crop = PageCaptureRegion(
				x: geometry.documentRect.width / 2 - 10,
				y: geometry.documentRect.height * 5 / 6 - 10,
				width: 20,
				height: 20
			)

			// The app crops with the capture client's crop, the same as Copy and Save use.
			let preview = try engine.capture.crop(frame, crop)
			try require("appCrop.previewSize", "\(preview.width)x\(preview.height)", equals: "20x20")

			try CaptureSmokePixels.expect(
				PageCaptureCodec.decode(preview),
				x: 10,
				y: 10,
				patch: .init(x: 10, y: 10, red: 0, green: 0, blue: 255)
			)
			guard try PageCaptureCodec.encode(preview, as: .png) == preview.png else {
				throw mismatch("appCrop.pngEncoding", expected: "stored PNG", actual: "different bytes")
			}

			// Retake resolves a fresh revision of the same page; capturing again reads the same document.
			store.send(.captureSessions(.element(id: id, action: .ui(.retake))))
			try await wait { self.store.captureSessions[id: id]?.phase == .selecting }
			store.send(.captureSessions(.element(id: id, action: .capture(nil))))
			try await wait { self.store.captureSessions[id: id]?.phase == .captured }
			try require(
				"appRecapture.documentID",
				store.captureSessions[id: id]?.frame?.documentID,
				equals: documentID
			)
			if full.request?.beyondViewport == true {
				// The whole page beyond the viewport (DEV-1172) lays the page out at its whole height
				// for one frame and back, and the fixture's title reports its size on each resize. Both
				// title changes move the tab's revision, as any change of the page does, and how many
				// of them a look catches is timing (one app smoke saw 24->26, the next 23->27). Chromium
				// also reports the colors of the frames the page draws again, which can arrive after
				// the title is back (engine batch 7 saw `changed navigation`). So once the page
				// settles, it must be as it was in everything but that revision and its colors.
				try await requireSettled("appRecapture.sourceSnapshot", appOriginal)
			} else {
				try requireUnchanged("appRecapture.sourceSnapshot", appOriginal)
			}
			print("ARX_APP_DOCUMENT_CAPTURE_CROP_AND_RECAPTURE")
			store.send(.ui(.closeCapture(id)))
			store.send(.ui(.focusWindow(store.main.id)))
			try await wait { self.engine.client.snapshot(self.source.id)?.isVisibleForCapture == true }

			let item = try await inventory(session, url: documentURL)
			let request = AutomationCaptureRequest(
				targetID: source.id.rawValue,
				expectedRevision: item.revision,
				mode: .fullDocument
			)
			guard
				let original = engine.client.snapshot(source.id),
				let revision = original.documentRevision
			else { throw AutomationSmokeFailure.missingSource }

			let focusedWindow = store.focusedWindowID
			let captured = try await capture("mcpDocument", request, session: session)
			try SmokeDiagnostics.focused { try AutomationCaptureSmoke.verifyDocument(captured) }
			print("ARX_MCP_DOCUMENT_CAPTURE_FULL_IMAGE")
			let metadata = captured.metadata
			try require("mcpDocument.sessionRevision", metadata.sessionRevision, equals: String(original.revision))
			try require("mcpDocument.documentRevision", metadata.documentRevision, equals: String(revision))
			try require("mcpDocument.documentID", metadata.documentID, equals: documentID)

			// MCP records the document (ABI16). Capture Page renders the whole page beyond the
			// viewport when the engine can (DEV-1172): the same document, scroll and scale, with the
			// visible area measured another way.
			if full.request?.beyondViewport == true {
				try require("mcpDocument.documentRect", metadata.documentGeometry?.documentRect, equals: geometry.documentRect)
				try require("mcpDocument.scrollX", metadata.documentGeometry?.scrollX, equals: geometry.scrollX)
				try require("mcpDocument.scrollY", metadata.documentGeometry?.scrollY, equals: geometry.scrollY)
				try require("mcpDocument.zoomLevel", metadata.documentGeometry?.zoomLevel, equals: geometry.zoomLevel)
			} else {
				try require("mcpDocument.documentGeometry", metadata.documentGeometry, equals: geometry)
			}
			try require("mcpDocument.viewportWidth", metadata.viewportWidth, equals: frame.viewportWidth)
			try require("mcpDocument.viewportHeight", metadata.viewportHeight, equals: frame.viewportHeight)
			try require("mcpDocument.deviceScale", metadata.deviceScale, equals: frame.deviceScale)
			try requireUnchanged("mcpDocument.sourceSnapshot", original)
			try require("mcpDocument.focusedWindowID", store.focusedWindowID, equals: focusedWindow)
			for tab in excluded {
				var denied = request
				denied.targetID = tab.id.rawValue
				guard case .failure(.denied) = try await session.capture(denied)
				else { throw AutomationSmokeFailure.authorizationFailed }
			}

			// Reopen the real preview and retain its pixels while navigation invalidates
			// the capture authority. Frozen encoding remains independent of the page.
			let beforeReopen = Set(store.captureSessions.ids)
			store.send(.ui(.capturePage(target, region: false)))
			try await wait {
				self.store.captureSessions.contains { session in
					!beforeReopen.contains(session.id) && session.phase == .captured
				}
			}
			guard let stale = store.captureSessions.first(where: { !beforeReopen.contains($0.id) })?.id else {
				throw mismatch("staleDocument.session", expected: "new capture session", actual: "none")
			}
			defer { store.send(.ui(.closeCapture(stale))) }
			try await wait {
				self.store.captureSessions[id: stale]?.image?.height == frame.image.height
			}
			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			let staleCapture = store.captureSessions[id: stale]
			try require("staleDocument.phase", staleCapture?.phase, equals: .captured)
			try require("staleDocument.documentID", staleCapture?.frame?.documentID, equals: documentID)
			try require("staleDocument.imageHeight", staleCapture?.image?.height, equals: frame.image.height)
			guard case .failure(.staleTarget) = try await session.capture(request)
			else { throw AutomationSmokeFailure.authorizationFailed }
			try CaptureSmokePixels.expectSamePixels(preview, engine.capture.crop(frame, crop))
			print("ARX_APP_DOCUMENT_CAPTURE_SMOKE_SUCCESS")
			print("ARX_MCP_DOCUMENT_CAPTURE_NATIVE_SMOKE_SUCCESS")
		}

		/// Captures through MCP while sampling why the source couldn't be captured, if ever.
		///
		/// A reply that isn't an image names the capture and lists every reason seen while it
		/// ran, with timestamps; a successful capture logs any it saw as
		/// `ARX_MCP_CAPTURE_VISIBILITY_GAP`.
		private func capture(
			_ name: String,
			_ request: AutomationCaptureRequest,
			session: AutomationSmokeSession
		) async throws -> AutomationCaptureSmoke.Snapshot {
			let probe = CaptureProbe()
			let start = ContinuousClock.now
			let sampling = Task { [weak self] in
				while !Task.isCancelled, let self {
					probe.record(captureBlocker(), at: ContinuousClock.now - start)
					try? await Task.sleep(for: .milliseconds(5))
				}
			}
			defer { sampling.cancel() }

			probe.record(captureBlocker(), at: .zero)
			let reply = try await session.capture(request)
			probe.record(captureBlocker(), at: ContinuousClock.now - start)
			sampling.cancel()

			do {
				let snapshot = try AutomationCaptureSmoke.verify(reply, request: request, profileID: source.profileID)
				if probe.sawBlocker {
					let message = "ARX_MCP_CAPTURE_VISIBILITY_GAP capture=\(name) [\(probe.summary)]\n"
					FileHandle.standardError.write(Data(message.utf8))
				}
				return snapshot
			} catch var mismatch as AutomationSmokeMismatch {
				mismatch.check = "\(name).\(mismatch.check)"
				mismatch.actual += " blockersDuringCapture=[\(probe.summary)] \(waitState())"
				mismatch.focus = SmokeDiagnostics.focus()
				throw mismatch
			}
		}

		/// Why the engine would refuse to capture the source on screen now, or `nil`.
		/// Mirrors `ChromiumBrowserEngine.isVisibleForCapture` through the fixture view.
		private func captureBlocker() -> String? {
			guard engine.capture.isAvailable() else { return "captureUnavailable" }
			guard let view = engine.contentHostFixtureView(source.id) else { return "notHosted" }
			guard let window = view.window else { return "noWindow" }

			var reasons: [String] = []
			if !window.isVisible { reasons.append("windowHidden") }
			if window.isMiniaturized { reasons.append("miniaturized") }
			var ancestor: NSView? = view
			while let current = ancestor {
				if current.isHidden {
					reasons.append("hidden:\(type(of: current))")
					break
				}
				ancestor = current.superview
			}
			if view.visibleRect.isEmpty { reasons.append("emptyVisibleRect:\(view.visibleRect.size)") }
			return reasons.isEmpty ? nil : reasons.joined(separator: "+")
		}

		/// A capture mismatch that names its check and records the focus now, before any `defer` moves it.
		private func mismatch(
			_ check: String,
			expected: String,
			actual: String
		) -> AutomationSmokeMismatch {
			AutomationSmokeMismatch(
				.captureMismatch,
				check: check,
				expected: expected,
				actual: actual,
				focus: SmokeDiagnostics.focus()
			)
		}

		private func require<Value: Equatable>(
			_ check: String,
			_ actual: Value,
			equals expected: Value
		) throws {
			try SmokeDiagnostics.focused {
				try AutomationSmokeMismatch.require(check, actual, equals: expected)
			}
		}

		/// Capture must leave the source's session snapshot exactly as it was. A whole-page capture's
		/// resize uses `requireSettled` instead.
		private func requireUnchanged(
			_ check: String,
			_ original: BrowserSessionSnapshot
		) throws {
			let current = engine.client.snapshot(source.id)
			guard current != original else { return }

			throw mismatch(
				check,
				expected: "unchanged",
				actual: "changed " + SmokeDiagnostics.snapshotChanges(from: original, to: current)
			)
		}

		/// After a capture beyond the viewport: waits as long as `wait` for the source page to come
		/// back as it was, then requires it but for its revision and the colors it reports
		/// (`SmokeSnapshotDifference`). Colors that stay changed are logged, not failed.
		private func requireSettled(
			_ check: String,
			_ original: BrowserSessionSnapshot
		) async throws {
			func look() -> SmokeSnapshotDifference {
				.between(original, engine.client.snapshot(source.id), ignoringRevision: true)
			}
			var difference = look()
			var looks = 1
			while difference != .none, looks < 100 {
				try await Task.sleep(for: .milliseconds(100))
				difference = look()
				looks += 1
			}

			guard !difference.isUnchanged(check: check) else { return }
			guard case let .changed(fields) = difference else { return }

			throw mismatch(check, expected: "unchanged", actual: "changed " + fields)
		}

		private func exerciseInspection(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient,
			excluded: [BrowserCore.Tab]
		) async throws {
			var scoped = client
			scoped.allowsPageContent = true
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }

			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			let inspectionURL = baseURL.deletingLastPathComponent().appendingPathComponent("inspection/main")

			// Establish the owned fixture first; the read itself must never change presentation.
			store.send(.ui(.focusWindow(store.main.id)))
			navigateSource(inspectionURL)
			try await wait { self.sourceLoaded(inspectionURL, title: "Arx inspection ready") }
			let item = try await inventory(session, url: inspectionURL, title: "Arx inspection ready")
			let request = AutomationInspectionRequest(
				targetID: source.id.rawValue,
				expectedRevision: item.revision
			)
			guard
				let original = engine.client.snapshot(source.id),
				let documentRevision = original.documentRevision
			else { throw AutomationSmokeFailure.missingSource }
			let focusedWindow = store.focusedWindowID
			let snapshot = try AutomationInspectionSmoke.verify(
				await session.inspect(request),
				request: request,
				profileID: source.profileID
			)
			try AutomationInspectionSmoke.verifyFixtureContent(snapshot)
			guard
				snapshot.sessionRevision == original.revision,
				snapshot.documentRevision == documentRevision
			else { throw AutomationSmokeFailure.inspectionMismatch }

			// Reads are windowed since DEV-673: a small node budget returns the first window
			// of the same projection instead of failing.
			var bounded = request
			bounded.maximumNodes = 1
			let window = try AutomationInspectionSmoke.verify(
				await session.inspect(bounded),
				request: bounded,
				profileID: source.profileID
			)
			guard
				window.content.nodes.count == 1,
				window.content.windowStart == 0,
				window.content.totalNodes == snapshot.content.totalNodes,
				window.content.totalNodes > 1,
				window.content.documentID == snapshot.content.documentID
			else { throw AutomationSmokeFailure.inspectionMismatch }

			for tab in excluded {
				var denied = request
				denied.targetID = tab.id.rawValue
				let before = engine.client.snapshot(tab.id)
				guard
					case .failure(.denied) = try await session.inspect(denied),
					engine.client.snapshot(tab.id) == before
				else { throw AutomationSmokeFailure.authorizationFailed }
			}
			guard
				store.focusedWindowID == focusedWindow,
				engine.client.snapshot(source.id) == original
			else { throw AutomationSmokeFailure.inspectionMismatch }

			let replacementURL = baseURL.deletingLastPathComponent().appendingPathComponent("inspection/replacement")
			navigateSource(replacementURL)
			try await wait { self.sourceLoaded(replacementURL, title: "Arx inspection replacement") }
			guard case .failure(.staleTarget) = try await session.inspect(request)
			else { throw AutomationSmokeFailure.authorizationFailed }
			let fresh = try await inventory(session, url: replacementURL, title: "Arx inspection replacement")
			let freshRequest = AutomationInspectionRequest(
				targetID: source.id.rawValue,
				expectedRevision: fresh.revision
			)
			let replacement = try AutomationInspectionSmoke.verify(
				await session.inspect(freshRequest),
				request: freshRequest,
				profileID: source.profileID
			)
			guard
				replacement.content.documentID != snapshot.content.documentID,
				replacement.documentRevision != snapshot.documentRevision
			else { throw AutomationSmokeFailure.inspectionMismatch }

			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_INSPECTION_NATIVE_SMOKE_SUCCESS")
		}

		private func exerciseClick(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient,
			excluded: [BrowserCore.Tab]
		) async throws {
			var scoped = client
			scoped.allowsPageContent = true
			scoped.mutationGrantUntil = nil
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let readSession = try makeSession(helper: helper, configuration: configuration)
			try await readSession.connect(grantedBy: store.automationPreferences)

			let fixtureURL = baseURL.deletingLastPathComponent().appendingPathComponent("reference-click/main")

			// A fresh document has received no native input; fixture setup precedes the assertion.
			store.send(.ui(.focusWindow(store.main.id)))
			navigateSource(fixtureURL)
			try await wait { self.sourceLoaded(fixtureURL, title: "Arx reference ready") }
			guard
				let before = engine.client.snapshot(source.id),
				let initialDocument = before.documentRevision
			else { throw AutomationSmokeFailure.missingSource }
			let readOnly = try await clickSnapshot(
				readSession,
				url: fixtureURL,
				title: "Arx reference ready"
			)
			print("ARX_MCP_CLICK_PHASE_CONTENT_ONLY_SNAPSHOT")
			let deniedRequest = try AutomationClickSmoke.request(for: readOnly, name: "Arx reference click")
			let denied = try await readSession.click(deniedRequest)
			guard
				denied.disposition == .notDispatched,
				denied.failure == .denied,
				engine.client.snapshot(source.id) == before
			else { throw AutomationSmokeFailure.authorizationFailed }
			guard await readSession.close() else { throw AutomationSmokeFailure.helperFailed }

			print("ARX_MCP_CLICK_PHASE_CONTENT_ONLY_DENIED")
			scoped.allowsPageInteraction = true
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			let old = try await clickSnapshot(session, url: fixtureURL, title: "Arx reference ready")
			let snapshot = try await clickSnapshot(session, url: fixtureURL, title: "Arx reference ready")
			print("ARX_MCP_CLICK_PHASE_NEW_SNAPSHOT")
			let oldRequest = try AutomationClickSmoke.request(for: old, name: "Arx reference click")
			let stale = try await session.click(oldRequest)
			guard stale.disposition == .notDispatched, stale.failure == .staleReference
			else { throw AutomationSmokeFailure.authorizationFailed }

			var request = try AutomationClickSmoke.request(for: snapshot, name: "Arx reference click")
			for tab in excluded {
				var foreign = request
				foreign.operationID = UUID()
				foreign.targetID = tab.id.rawValue
				let original = engine.client.snapshot(tab.id)
				let result = try await session.click(foreign)
				guard
					result.disposition == .notDispatched,
					result.failure == .denied,
					engine.client.snapshot(tab.id) == original
				else { throw AutomationSmokeFailure.authorizationFailed }
			}
			print("ARX_MCP_CLICK_PHASE_SCOPE_DENIED")
			let focusedWindow = store.focusedWindowID
			let focusedPane = store.main.viewer.activePaneID
			let declined = try await AutomationClickSmoke.approvedClick(
				request,
				session: session,
				store: store,
				engine: engine,
				approve: false
			)
			guard
				declined.disposition == .notDispatched,
				declined.failure == .approvalDeclined,
				engine.client.snapshot(source.id) == before
			else { throw AutomationSmokeFailure.authorizationFailed }

			print("ARX_MCP_CLICK_PHASE_APPROVAL_DECLINED")
			request.operationID = UUID()
			let activated = try await AutomationClickSmoke.approvedClick(
				request,
				session: session,
				store: store,
				engine: engine,
				approve: true
			)
			print("""
			ARX_MCP_CLICK_RESULT activation=\(activated.disposition.rawValue) \
			failure=\(activated.failure?.rawValue ?? "none")
			""")
			guard activated.disposition == .dispatched, activated.failure == nil
			else { throw AutomationSmokeFailure.clickMismatch }
			let counterTitle = "Arx reference count=1 trusted=true activation=false"
			try await wait { self.sourceLoaded(fixtureURL, title: counterTitle) }
			print("ARX_MCP_CLICK_PHASE_COUNTER_VERIFIED")
			let duplicate = try await session.click(request)
			guard
				duplicate.disposition == .dispatched,
				duplicate.failure == .duplicateOperation,
				sourceLoaded(fixtureURL, title: counterTitle)
			else { throw AutomationSmokeFailure.clickMismatch }

			print("ARX_MCP_CLICK_PHASE_DUPLICATE_VERIFIED")
			let updated = try await clickSnapshot(session, url: fixtureURL, title: counterTitle)
			let navigation = try AutomationClickSmoke.request(for: updated, name: "Arx reference navigation")
			let navigated = try await AutomationClickSmoke.approvedClick(
				navigation,
				session: session,
				store: store,
				engine: engine,
				approve: true
			)
			print("""
			ARX_MCP_CLICK_RESULT navigation=\(navigated.disposition.rawValue) \
			failure=\(navigated.failure?.rawValue ?? "none")
			""")
			try AutomationClickSmoke.verifyNavigationReceipt(navigated)
			let destination = fixtureURL.deletingLastPathComponent().appendingPathComponent("destination")
			try await wait { self.sourceLoaded(destination, title: "Arx reference destination") }
			print("ARX_MCP_CLICK_PHASE_NAVIGATION_VERIFIED")
			var obsolete = navigation
			obsolete.operationID = UUID()
			let rejected = try await session.click(obsolete)
			let finalSnapshot = engine.client.snapshot(source.id)
			let finalEvidence: [(String, Bool)] = [
				(
					"rejected",
					rejected.disposition == .notDispatched
					&& [.staleTarget, .staleReference].contains(rejected.failure)
				),
				("window", store.focusedWindowID == focusedWindow),
				("pane", store.main.viewer.activePaneID == focusedPane),
				("tab", store.main.viewer.item.tab?.id == source.id),
				(
					"profile",
					store.workspace.tabs[id: source.id]?.profileID == source.profileID
				),
				("revision", finalSnapshot.map { $0.revision > before.revision } ?? false),
				(
					"document",
					finalSnapshot?.documentRevision != nil
					&& finalSnapshot?.documentRevision != initialDocument
				),
				(
					"previousEntry",
					finalSnapshot?.navigation.history.contains {
						$0.url == fixtureURL && !$0.isCurrent
					} == true
				),
				(
					"currentEntry",
					finalSnapshot?.navigation.history.contains {
						$0.url == destination && $0.isCurrent
					} == true
				),
			]
			for (name, passed) in finalEvidence {
				print("ARX_MCP_CLICK_FINAL \(name)=\(passed)")
			}
			guard finalEvidence.allSatisfy(\.1)
			else { throw AutomationSmokeFailure.clickMismatch }

			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_CLICK_NATIVE_SMOKE_SUCCESS")
		}

		private func exerciseForm(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient,
			excluded: [BrowserCore.Tab]
		) async throws {
			var scoped = client
			scoped.allowsPageContent = true
			scoped.allowsPageInteraction = false
			scoped.mutationGrantUntil = nil
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let readSession = try makeSession(helper: helper, configuration: configuration)
			try await readSession.connect(grantedBy: store.automationPreferences)

			let token = UUID().uuidString.lowercased()
			let root = baseURL.deletingLastPathComponent().appendingPathComponent("reference-form")
			let fixtureURL = root
				.appendingPathComponent("main")
				.appending(queryItems: [.init(name: "run", value: token)])
			let evidenceURL = root.appendingPathComponent("state").appendingPathComponent(token)
			store.send(.ui(.focusWindow(store.main.id)))
			navigateSource(fixtureURL)
			try await wait { self.sourceLoaded(fixtureURL, title: "Arx form ready") }
			let readSnapshot = try await clickSnapshot(
				readSession,
				url: fixtureURL,
				title: "Arx form ready"
			)
			var request = AutomationFormRequest(
				target: try AutomationClickSmoke.request(for: readSnapshot, name: "Arx form text"),
				kind: .replaceText,
				value: "replacement"
			)
			let denied = try await readSession.form(request)
			guard denied.disposition == .notDispatched, denied.failure == .denied
			else { throw AutomationSmokeFailure.authorizationFailed }
			try await AutomationFormSmoke.evidence(at: evidenceURL, targets: [])
			guard await readSession.close() else { throw AutomationSmokeFailure.helperFailed }

			scoped.allowsPageInteraction = true
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			let snapshot = try await clickSnapshot(session, url: fixtureURL, title: "Arx form ready")
			request.target = try AutomationClickSmoke.request(for: snapshot, name: "Arx form text")
			for tab in excluded {
				var foreign = request
				foreign.target.operationID = UUID()
				foreign.target.targetID = tab.id.rawValue
				let before = engine.client.snapshot(tab.id)
				let result = try await session.form(foreign)
				guard
					result.disposition == .notDispatched,
					result.failure == .denied,
					engine.client.snapshot(tab.id) == before
				else { throw AutomationSmokeFailure.authorizationFailed }
			}
			print("ARX_MCP_FORM_PHASE_SCOPE_DENIED")

			let fresh = try await clickSnapshot(session, url: fixtureURL, title: "Arx form ready")
			let stale = try await session.form(request)
			guard stale.disposition == .notDispatched, stale.failure == .staleReference
			else { throw AutomationSmokeFailure.authorizationFailed }
			request.target = try AutomationClickSmoke.request(for: fresh, name: "Arx form text")
			let focusedWindow = store.focusedWindowID
			let focusedPane = store.main.viewer.activePaneID
			let nativeWindow = NSApp.keyWindow
			let document = engine.client.snapshot(source.id)?.documentRevision
			let declined = try await AutomationFormSmoke.approvedForm(
				request,
				session: session,
				store: store,
				engine: engine,
				approve: false
			)
			guard declined.disposition == .notDispatched, declined.failure == .approvalDeclined
			else { throw AutomationSmokeFailure.authorizationFailed }
			try await AutomationFormSmoke.evidence(at: evidenceURL, targets: [])

			request.target.operationID = UUID()
			let replaced = try await AutomationFormSmoke.approvedForm(
				request,
				session: session,
				store: store,
				engine: engine,
				approve: true
			)
			guard replaced.disposition == .dispatched, replaced.failure == nil
			else { throw AutomationSmokeFailure.formMismatch }
			try await AutomationFormSmoke.evidence(at: evidenceURL, targets: ["text"])
			print("ARX_MCP_FORM_PHASE_TEXT_VERIFIED")

			let unchangedSnapshot = try await clickSnapshot(
				session,
				url: fixtureURL,
				title: "Arx form ready"
			)
			request.target = try AutomationClickSmoke.request(
				for: unchangedSnapshot,
				name: "Arx form text"
			)
			let unchanged = try await AutomationFormSmoke.approvedForm(
				request,
				session: session,
				store: store,
				engine: engine,
				approve: true
			)
			guard unchanged.disposition == .unchanged, unchanged.failure == nil
			else { throw AutomationSmokeFailure.formMismatch }
			let duplicate = try await session.form(request)
			guard duplicate.disposition == .unchanged, duplicate.failure == .duplicateOperation
			else { throw AutomationSmokeFailure.formMismatch }

			var changed = request
			changed.value = "other fixture value"
			let wrongPayload = try await session.form(changed)
			changed.kind = .selectValue
			changed.value = "b"
			let wrongKind = try await session.form(changed)
			let repliesAreDuplicates = [wrongPayload, wrongKind].allSatisfy { reply in
				reply.disposition == .possiblyDispatched && reply.failure == .duplicateOperation
			}
			guard repliesAreDuplicates
			else { throw AutomationSmokeFailure.formMismatch }

			try await AutomationFormSmoke.evidence(at: evidenceURL, targets: ["text"])
			print("ARX_MCP_FORM_PHASE_UNCHANGED_AND_REPLAY_VERIFIED")

			var targets = ["text"]
			for target in ["search", "textarea", "select"] {
				let current = try await clickSnapshot(
					session,
					url: fixtureURL,
					title: "Arx form ready"
				)
				let value: String = switch target {
				case "textarea": "replacement\nline"
				case "select": "b"
				default: "replacement"
				}
				let next = AutomationFormRequest(
					target: try AutomationClickSmoke.request(for: current, name: "Arx form " + target),
					kind: target == "select" ? .selectValue : .replaceText,
					value: value
				)
				let result = try await AutomationFormSmoke.approvedForm(
					next,
					session: session,
					store: store,
					engine: engine,
					approve: true
				)
				guard result.disposition == .dispatched, result.failure == nil
				else { throw AutomationSmokeFailure.formMismatch }
				targets.append(target)
				try await AutomationFormSmoke.evidence(at: evidenceURL, targets: targets)
			}
			print("ARX_MCP_FORM_PHASE_CONTROLS_VERIFIED")

			let selected = try await clickSnapshot(session, url: fixtureURL, title: "Arx form ready")
			let ambiguous = AutomationFormRequest(
				target: try AutomationClickSmoke.request(for: selected, name: "Arx form select"),
				kind: .selectValue,
				value: "duplicate"
			)
			let rejected = try await AutomationFormSmoke.approvedForm(
				ambiguous,
				session: session,
				store: store,
				engine: engine,
				approve: true
			)
			guard rejected.disposition == .notDispatched, rejected.failure == .ambiguousOption
			else { throw AutomationSmokeFailure.formMismatch }
			try await AutomationFormSmoke.evidence(at: evidenceURL, targets: targets)
			guard
				store.focusedWindowID == focusedWindow,
				store.main.viewer.activePaneID == focusedPane,
				NSApp.keyWindow === nativeWindow,
				store.main.viewer.item.tab?.id == source.id,
				store.workspace.tabs[id: source.id]?.profileID == source.profileID,
				document != nil,
				engine.client.snapshot(source.id)?.documentRevision == document
			else { throw AutomationSmokeFailure.formMismatch }

			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_FORM_NATIVE_SMOKE_SUCCESS")
		}

		private func exerciseKeypress(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient,
			excluded: [BrowserCore.Tab]
		) async throws {
			var scoped = client
			scoped.allowsPageContent = true
			scoped.allowsPageInteraction = true
			scoped.mutationGrantUntil = nil
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)

			let root = baseURL.deletingLastPathComponent().appendingPathComponent("reference-keypress")
			for mode in ["unicode", "beforeinput-focus"] {
				let token = UUID().uuidString.lowercased()
				let fixtureURL = root
					.appendingPathComponent(mode)
					.appending(queryItems: [.init(name: "run", value: token)])
				let evidenceURL = root.appendingPathComponent("state").appendingPathComponent(token)
				store.send(.ui(.focusWindow(store.main.id)))
				navigateSource(fixtureURL)
				try await wait { self.sourceLoaded(fixtureURL, title: "Arx keypress ready") }
				let snapshot = try await clickSnapshot(
					session,
					url: fixtureURL,
					title: "Arx keypress ready"
				)
				var request = AutomationFormRequest(
					target: try AutomationClickSmoke.request(for: snapshot, name: "Arx keypress target"),
					kind: .keyPress,
					value: mode == "unicode" ? "🙂" : "x"
				)
				for tab in excluded {
					var foreign = request
					foreign.target.operationID = UUID()
					foreign.target.targetID = tab.id.rawValue
					let before = engine.client.snapshot(tab.id)
					let result = try await session.form(foreign)
					guard
						result.disposition == .notDispatched,
						result.failure == .denied,
						engine.client.snapshot(tab.id) == before
					else { throw AutomationSmokeFailure.authorizationFailed }
				}

				let fresh = try await clickSnapshot(
					session,
					url: fixtureURL,
					title: "Arx keypress ready"
				)
				let stale = try await session.form(request)
				guard stale.disposition == .notDispatched, stale.failure == .staleReference
				else { throw AutomationSmokeFailure.authorizationFailed }
				request.target = try AutomationClickSmoke.request(for: fresh, name: "Arx keypress target")
				let declined = try await AutomationFormSmoke.approvedForm(
					request,
					session: session,
					store: store,
					engine: engine,
					approve: false
				)
				guard declined.disposition == .notDispatched, declined.failure == .approvalDeclined
				else { throw AutomationSmokeFailure.authorizationFailed }

				request.target.operationID = UUID()
				let focusedWindow = store.focusedWindowID
				let nativeWindow = NSApp.keyWindow
				let focusedPane = store.main.viewer.activePaneID
				let document = engine.client.snapshot(source.id)?.documentRevision
				let result = try await AutomationFormSmoke.approvedForm(
					request,
					session: session,
					store: store,
					engine: engine,
					approve: true
				)
				let redirected = mode == "beforeinput-focus"
				guard
					result.disposition == (redirected ? .possiblyDispatched : .dispatched),
					result.failure == (redirected ? .staleReference : nil)
				else { throw AutomationSmokeFailure.formMismatch }
				let evidence = try await AutomationKeypressSmoke.evidence(
					at: evidenceURL,
					redirected: redirected
				)
				let duplicate = try await session.form(request)
				guard
					duplicate.disposition == result.disposition,
					duplicate.failure == .duplicateOperation,
					try await AutomationKeypressSmoke.evidence(
						at: evidenceURL,
						redirected: redirected
					) == evidence,
					store.focusedWindowID == focusedWindow,
					store.main.viewer.activePaneID == focusedPane,
					NSApp.keyWindow === nativeWindow,
					store.main.viewer.item.tab?.id == source.id,
					document != nil,
					engine.client.snapshot(source.id)?.documentRevision == document
				else { throw AutomationSmokeFailure.formMismatch }
			}
			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_KEYPRESS_NATIVE_SMOKE_SUCCESS")
		}

		private func clickSnapshot(
			_ session: AutomationSmokeSession,
			url: URL,
			title: String
		) async throws -> AutomationInspectionSmoke.Snapshot {
			let item = try await inventory(session, url: url, title: title)
			let request = AutomationInspectionRequest(
				targetID: source.id.rawValue,
				expectedRevision: item.revision
			)
			return try AutomationInspectionSmoke.verify(
				await session.inspect(request),
				request: request,
				profileID: source.profileID
			)
		}

		private func exerciseScroll(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient,
			excluded: [BrowserCore.Tab]
		) async throws {
			var scoped = client
			scoped.allowsPageContent = true
			scoped.allowsPageInteraction = false
			scoped.mutationGrantUntil = nil
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let readSession = try makeSession(helper: helper, configuration: configuration)
			try await readSession.connect(grantedBy: store.automationPreferences)

			let token = UUID().uuidString.lowercased()
			let root = baseURL.deletingLastPathComponent().appendingPathComponent("reference-scroll")
			let fixtureURL = root
				.appendingPathComponent("main")
				.appending(queryItems: [.init(name: "run", value: token)])
			let evidenceURL = root.appendingPathComponent("state").appendingPathComponent(token)
			store.send(.ui(.focusWindow(store.main.id)))
			navigateSource(fixtureURL)
			try await wait { self.sourceLoaded(fixtureURL, title: "Arx scroll ready") }
			let readSnapshot = try await clickSnapshot(
				readSession,
				url: fixtureURL,
				title: "Arx scroll ready"
			)
			let denied = AutomationScrollRequest(
				target: try AutomationClickSmoke.request(for: readSnapshot, name: "Arx scroll anchor"),
				axis: .vertical,
				deltaCSSPixels: 120.5
			)
			try AutomationScrollSmoke.require(
				await readSession.scroll(denied),
				.notDispatched,
				failure: .denied
			)
			_ = try await AutomationScrollSmoke.evidence(at: evidenceURL) { evidence in
				evidence.matches() && evidence.events == 0
			}
			guard await readSession.close() else { throw AutomationSmokeFailure.helperFailed }

			scoped.allowsPageInteraction = true
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			let old = try await clickSnapshot(session, url: fixtureURL, title: "Arx scroll ready")
			let stale = AutomationScrollRequest(
				target: try AutomationClickSmoke.request(for: old, name: "Arx scroll anchor"),
				axis: .vertical,
				deltaCSSPixels: 120.5
			)
			let current = try await clickSnapshot(session, url: fixtureURL, title: "Arx scroll ready")
			try AutomationScrollSmoke.require(
				await session.scroll(stale),
				.notDispatched,
				failure: .staleReference
			)
			try await AutomationScrollSmoke.run(
				store: store,
				engine: engine,
				session: session,
				source: source,
				snapshot: current,
				refreshSnapshot: {
					try await clickSnapshot(session, url: fixtureURL, title: "Arx scroll ready")
				},
				evidenceURL: evidenceURL,
				excluded: excluded
			)

			let beforeNavigation = try await clickSnapshot(
				session,
				url: fixtureURL,
				title: "Arx scroll ready"
			)
			let obsolete = AutomationScrollRequest(
				target: try AutomationClickSmoke.request(
					for: beforeNavigation,
					name: "Arx scroll anchor"
				),
				axis: .vertical,
				deltaCSSPixels: 120.5
			)
			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			let rejected = try await session.scroll(obsolete)
			guard
				rejected.disposition == .notDispatched,
				[.staleTarget, .staleReference].contains(rejected.failure)
			else { throw AutomationSmokeFailure.authorizationFailed }
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_SCROLL_NATIVE_SMOKE_SUCCESS")
		}

		private func exerciseWait(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient
		) async throws {
			var scoped = client
			scoped.allowsManagement = false
			scoped.allowsPageContent = false
			scoped.allowsScreenshots = false
			scoped.allowsPageInteraction = false
			scoped.mutationGrantUntil = nil
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }

			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			try await AutomationWaitSmoke.run(
				store: store,
				engine: engine,
				session: session,
				source: source,
				paneID: sourcePane,
				baseURL: baseURL
			)

			let next = url("next", sensitive: true)
			navigateSource(next)
			try await wait { self.sourceLoaded(next, title: "Arx MCP next") }
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
			print("ARX_MCP_WAIT_NATIVE_SMOKE_SUCCESS")
		}

		private func exerciseOrganization(
			helper: URL,
			configuration: AutomationSmokeConfiguration,
			client: AutomationClient
		) async throws {
			// This is an acceptance gate, not an emulated success on older runtimes.
			guard engine.client.closeAuthorized != nil
			else { throw AutomationSmokeFailure.atomicCloseUnavailable }

			let fixtureSpaces: [(Space.ID, String)] = [
				(folderSourceSpace, "MCP folder source fixture"),
				(folderDestinationSpace, "MCP folder destination fixture"),
			]
			for (id, name) in fixtureSpaces {
				store.send(.settings(.delegate(.changeOrganization(.createSpace(
					id,
					profileID: source.profileID,
					name: name,
					icon: .stack
				)))))
				try await wait {
					self.store.workspace.spaces.ids.contains(id)
					&& self.store.main.sidebar.organization.spaces.ids.contains(id)
					&& !self.store.settings.isManagingOrganization
				}
			}
			store.send(.main(.sidebar(.ui(.spaceSelected(sourceSpace)))))
			store.send(.main(.present(source.id, in: sourcePane)))
			try await wait {
				self.sourceLoaded(self.url("next", sensitive: true), title: "Arx MCP next")
			}

			var scoped = client
			scoped.scopes += [
				.space(folderSourceSpace, profileID: source.profileID),
				.space(folderDestinationSpace, profileID: source.profileID),
			]
			scoped.mutationGrantUntil = Date().addingTimeInterval(90)
			await store.send(.automation(.ui(.updateClient(scoped)))).finish()
			try await wait { self.store.automation.sessions.isEmpty }
			let session = try makeSession(helper: helper, configuration: configuration)
			try await session.connect(grantedBy: store.automationPreferences)
			try await AutomationOrganizationSmoke.run(
				store: store,
				engine: engine,
				session: session,
				profileID: source.profileID,
				sourceSpace: folderSourceSpace,
				destinationSpace: folderDestinationSpace,
				url: url("excluded")
			)
			try await AutomationHostSmoke.run(
				store: store,
				engine: engine,
				session: session,
				profileID: source.profileID,
				sourceSpace: folderSourceSpace,
				destinationSpace: folderDestinationSpace,
				url: url("excluded")
			)

			// Host promotions select other spaces; later phases expect the original source again.
			store.send(.main(.sidebar(.ui(.spaceSelected(sourceSpace)))))
			try await wait {
				self.store.main.sidebar.spaceID == self.sourceSpace
				&& self.store.main.viewer.spaceID == self.sourceSpace
			}
			store.send(.main(.present(source.id, in: sourcePane)))
			try await wait {
				self.sourceLoaded(self.url("next", sensitive: true), title: "Arx MCP next")
			}
			guard await session.close() else { throw AutomationSmokeFailure.helperFailed }
		}

		internal func cleanup() async -> Bool {
			if cleaned { return true }
			var succeeded = true

			if let clientID { store.send(.automation(.ui(.revokeClient(clientID)))) }
			await AutomationSmoke.disable(store: store)
			pending?.cancel()
			privatePreparation?.cancel()

			for session in sessions {
				if !(await session.close()) { succeeded = false }
			}
			if let pending {
				_ = await pending.result
				self.pending = nil
			}

			if let id = privateWindowID, store.windows[id: id]?.isPrivate == true {
				store.send(.ui(.requestClosePrivateWindow(id)))
				do {
					try await wait { self.store.windows[id: id] == nil }
				} catch {
					succeeded = false
				}
			}

			let sourceIsRetained = store.workspace.spaces.ids.contains(sourceSpace)
			&& store.workspace.tabs.ids.contains(source.id)

			if sourceIsRetained {
				store.send(.main(.sidebar(.ui(.spaceSelected(sourceSpace)))))
				store.send(.main(.present(source.id, in: sourcePane)))
				navigateSource(originalURL)
				do {
					try await wait { self.sourceLoaded(self.originalURL) }
				} catch {
					succeeded = false
				}

			} else {
				succeeded = false
			}

			let ownedSpaces = [folderSourceSpace, folderDestinationSpace]
			let ownedArchive = store.workspace.archive
				.filter { ownedSpaces.contains($0.originalSpaceID) }
				.map(\.id)
			if !ownedArchive.isEmpty {
				store.send(.main(.ui(.openArchive)))
				if store.main.archive.profileID == source.profileID {
					store.send(.main(.archive(.delegate(.delete(ownedArchive)))))
					store.send(.main(.archive(.ui(.dismissed))))
					do {
						try await wait {
							!self.store.workspace.archive.contains { ownedArchive.contains($0.id) }
						}
					} catch {
						succeeded = false
					}

				} else {
					succeeded = false
				}
			}
			for id in ownedSpaces where store.workspace.spaces.ids.contains(id) {
				store.send(.settings(.delegate(.changeOrganization(.removeSpace(id)))))
				do {
					try await wait { !self.store.workspace.spaces.ids.contains(id) }
				} catch {
					succeeded = false
				}
			}

			if store.workspace.spaces.ids.contains(space) {
				store.send(.settings(.delegate(.changeOrganization(.removeSpace(space)))))
				do {
					try await wait { !self.store.workspace.spaces.ids.contains(self.space) }
				} catch {
					succeeded = false
				}
			}
			if store.workspace.profiles.ids.contains(profile) {
				store.send(.settings(.delegate(.changeOrganization(.removeProfile(profile)))))
				do {
					try await wait { !self.store.workspace.profiles.ids.contains(self.profile) }
				} catch {
					succeeded = false
				}
			}
			do {
				try await wait {
					!self.store.automationPreferences.isEnabled
					&& self.store.automationPreferences.clients.isEmpty
					&& self.store.automation.socketPath == nil
					&& self.store.automation.pending.isEmpty
					&& self.store.automation.sessions.isEmpty
				}
			} catch {
				succeeded = false
			}

			cleaned = succeeded
			return succeeded
		}

		private func makeExcludedPage() async throws -> BrowserCore.Tab {
			store.send(.settings(.delegate(.changeOrganization(.createProfile(
				profile,
				name: "MCP excluded fixture"
			)))))
			try await wait { self.store.main.sidebar.organization.profiles.ids.contains(self.profile) }
			store.send(.settings(.delegate(.changeOrganization(.createSpace(
				space,
				profileID: profile,
				name: "MCP excluded fixture",
				icon: .stack
			)))))
			try await wait { self.store.main.sidebar.organization.spaces.ids.contains(self.space) }
			store.send(.ui(.openURLInSpace(url("excluded"), space, .mainBrowser)))
			try await wait {
				let tab = self.store.main.viewer.item.tab
				let isLoaded = tab.map { tab in
					self.loaded(tab.id, url: self.url("excluded"), title: "Arx MCP excluded")
				}
				return tab?.profileID == self.profile && isLoaded == true
			}
			guard let tab = store.main.viewer.item.tab
			else { throw AutomationSmokeFailure.missingSource }

			store.send(.main(.sidebar(.ui(.spaceSelected(sourceSpace)))))
			store.send(.main(.present(source.id, in: sourcePane)))
			try await wait {
				self.store.main.viewer.item.tab?.id == self.source.id
				&& self.engine.isAttached(self.source.id)
			}
			return tab
		}

		private func makePrivatePage() async throws -> BrowserCore.Tab {
			privatePreparation = store.send(.ui(.newPrivateWindow))
			try await wait { self.store.windows.contains(where: \.isPrivate) }
			guard let window = store.windows.first(where: \.isPrivate)
			else { throw AutomationSmokeFailure.missingSource }

			privateWindowID = window.id
			try await wait { self.store.windows[id: window.id]?.commandBar.isPresented == true }
			let query = url("private").absoluteString
			store.send(.windows(.element(
				id: window.id,
				action: .commandBar(.ui(.queryChanged(query)))
			)))
			store.send(.windows(.element(
				id: window.id,
				action: .commandBar(.ui(.selected("destination")))
			)))
			try await wait {
				self.store.windows[id: window.id]?.viewer.item.tab.map {
					self.loaded($0.id, url: self.url("private"), title: "Arx MCP private")
				} == true
			}
			guard
				let tab = store.windows[id: window.id]?.viewer.item.tab,
				!store.workspace.tabs.ids.contains(tab.id)
			else { throw AutomationSmokeFailure.inventoryMismatch }

			return tab
		}

		private func makeSession(
			helper: URL,
			configuration: AutomationSmokeConfiguration
		) throws -> AutomationSmokeSession {
			let session = try AutomationSmokeSession(helper: helper, configuration: configuration)
			sessions.append(session)
			return session
		}

		private func inventory(
			_ session: AutomationSmokeSession,
			url: URL,
			title: String? = nil
		) async throws -> AutomationInventoryItem {
			let reply = try await session.inventory()
			guard case let .inventory(inventory) = reply else {
				let miss = if case let .failure(miss) = AutomationHostSmoke.lookUp(source.id.rawValue, in: reply) { "\(miss)" } else { "reply" }
				throw AutomationSmokeMismatch(.inventoryMismatch, check: "inventory", expected: "inventory", actual: miss, focus: SmokeDiagnostics.focus())
			}

			// Each check by name, so a failure says which (engine batch 7 saw a bare one), with
			// counts and kinds rather than IDs, URLs or titles.
			let item = inventory.items.first
			let checks: KeyValuePairs<String, Bool> = [
				"unpaged": inventory.nextCursor == nil,
				"onlySource(items=\(inventory.items.count),kinds=\(Set(inventory.items.map(\.kind.rawValue)).sorted()))":
					inventory.items.count == 1,
				"sourceID": item?.id == source.id.rawValue,
				"kind": item?.kind == .tab,
				"profile": item?.profileID == source.profileID.rawValue,
				"url": item?.url == AutomationAccess.sanitizedURL(url),
				"host": item?.host == "127.0.0.1",
				"sessionState(\(item?.sessionState?.rawValue ?? "none"))": item?.sessionState == .ready,
				"title": item?.title == store.workspace.tabs[id: source.id]?.displayTitle,
				"sourceLoaded": sourceLoaded(url, title: title),
			]
			let failed = checks.filter { !$0.value }.map(\.key)
			guard failed.isEmpty, let item else {
				throw AutomationSmokeMismatch(
					.inventoryMismatch,
					check: "inventory",
					expected: "the source alone, loaded",
					actual: "failed " + failed.joined(separator: ","),
					focus: SmokeDiagnostics.focus()
				)
			}

			return item
		}

		private func navigateSource(_ url: URL) {
			store.send(.main(.viewer(.command(.navigate(url), in: sourcePane, tabID: source.id))))
		}

		private func sourceLoaded(
			_ url: URL,
			title: String? = nil
		) -> Bool {
			loaded(source.id, url: url, title: title)
			&& store.main.viewer.item.tab?.id == source.id
			&& store.main.viewer.item.navigation.url == url
			&& !store.main.viewer.item.navigation.isLoading
			&& store.workspace.tabs[id: source.id]?.restoration.url == url
			&& (
				title == nil
				|| (
					store.main.viewer.item.navigation.title == title
					&& store.workspace.tabs[id: source.id]?.restoration.title == title
				)
			)
		}

		private func loaded(
			_ id: BrowserCore.Tab.ID,
			url: URL,
			title: String? = nil
		) -> Bool {
			guard let snapshot = engine.client.snapshot(id) else { return false }
			return snapshot.navigation.url == url
			&& !snapshot.navigation.isLoading
			&& snapshot.navigation.errorCode == nil
			&& (title == nil || snapshot.navigation.title == title)
		}

		private func url(
			_ name: String,
			sensitive: Bool = false
		) -> URL {
			let page = baseURL.deletingLastPathComponent().appendingPathComponent("mcp-\(name).html")
			guard sensitive else { return page }
			var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)!
			parts.query = "fixture-sensitive=1"
			parts.fragment = "fixture-fragment"
			return parts.url!
		}

		private func wait(
			file: StaticString = #fileID,
			line: Int = #line,
			function: StaticString = #function,
			_ ready: () -> Bool
		) async throws {
			let start = ContinuousClock.now
			for _ in 0..<100 {
				if ready() { return }
				try await Task.sleep(for: .milliseconds(100))
			}
			throw SmokeDiagnostics.timeout(
				site: "\(file):\(line) \(function)",
				since: start,
				state: waitState()
			)
		}

		/// The source tab and automation state a timed-out wait usually depends on.
		private func waitState() -> String {
			let snapshot = engine.client.snapshot(source.id)
			return [
				"sourceLoading=\(snapshot.map { "\($0.navigation.isLoading)" } ?? "noSnapshot")",
				"sourceError=\(snapshot?.navigation.errorCode.map { "\($0)" } ?? "nil")",
				"sourceVisibleForCapture=\(snapshot.map { "\($0.isVisibleForCapture)" } ?? "nil")",
				"sourceRevision=\(snapshot.map { "\($0.revision)" } ?? "nil")",
				"focusedIsMain=\(store.focusedWindowID == store.main.id)",
				"sessions=\(store.automation.sessions.count)",
				"pending=\(store.automation.pending.count)",
				"captureSessions=\(store.captureSessions.count)",
			].joined(separator: " ")
		}
	}
}
#endif
