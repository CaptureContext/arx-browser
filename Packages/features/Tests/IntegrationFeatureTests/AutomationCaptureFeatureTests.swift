import BrowserAutomationClient
import BrowserCaptureClient
import BrowserCore
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationCaptureFeatureTests {
	@Test
	internal func screenshotToggleRotatesPermissionRevisionAndKeepsExistingSession() async throws {
		let fixture = Fixture(screenshotsAllowed: false)
		let original = fixture.store.automationPreferences.clients[0]
		let before = fixture.store.automation.sessions
		#expect(!before.isEmpty)
		var updated = original
		updated.allowsScreenshots = true
		await fixture.store.send(.automation(.ui(.updateClient(updated)))).finish()
		let saved = try #require(fixture.store.automationPreferences.clients.first)
		#expect(saved.grantRevision != original.grantRevision)
		expectNoDifference(saved.allowsScreenshots, true)
		expectNoDifference(fixture.store.automation.sessions, before)
	}

	@Test(arguments: [false, true])
	internal func explicitCaptureKeepsPresentationAndWorkspaceUnchanged(region: Bool) async throws {
		let fixture = Fixture()
		let before = fixture.store.state
		let request = try fixture.request(region: region)
		await fixture.send(request).finish()
		let response = try #require(fixture.responses.first)
		guard case let .capture(result) = response else {
			Issue.record("Authorized capture did not return pixels")
			return
		}

		expectNoDifference(fixture.calls.count, 1)
		expectNoDifference(fixture.calls[0].ordinaryProfileID, fixture.tab.profileID)
		expectNoDifference(fixture.calls[0].documentRevision, 8)
		expectNoDifference(result.image.width, 1)
		expectNoDifference(result.image.height, 1)
		expectNoDifference(result.documentID, "fixture-document")
		expectNoDifference(fixture.store.workspace, before.workspace)
		expectNoDifference(fixture.store.main, before.main)
		expectNoDifference(fixture.store.windows, before.windows)
		expectNoDifference(fixture.store.focusedWindowID, before.focusedWindowID)
		#expect(fixture.store.automation.pending.isEmpty)
		#expect(fixture.store.automation.activity.allSatisfy { $0.operation == "capture" && $0.outcome == "captured" })
	}

	@Test(arguments: [
		"grant", "foreign", "private", "unloaded", "epoch",
		"privileged", "failed", "hidden", "nativeUnavailable", "authentication",
	])
	internal func deniedOrUnavailableSourcesNeverCapture(reason: String) async throws {
		let fixture = Fixture(screenshotsAllowed: reason != "grant")
		if reason == "unloaded" { fixture.snapshots = [:] }
		if reason == "epoch" { fixture.snapshots[fixture.tab.id]?.documentRevision = nil }
		if reason == "privileged" { fixture.snapshots[fixture.tab.id]?.navigation.url = URL(string: "chrome://settings") }
		if reason == "hidden" { fixture.snapshots[fixture.tab.id]?.isVisibleForCapture = false }
		if reason == "failed" { fixture.snapshots[fixture.tab.id]?.navigation.errorCode = -1 }
		if reason == "authentication" { fixture.snapshots[fixture.tab.id]?.navigation.authenticationCancelled = true }
		if reason == "nativeUnavailable" { fixture.available = false }
		var request = try fixture.request()
		if reason == "foreign" || reason == "private" {
			guard case var .capture(capture) = request.operation else { return }
			capture.targetID = reason == "foreign" ? fixture.other.id.rawValue : UUID(90)
			request.operation = .capture(capture)
		}
		await fixture.send(request).finish()

		let failure: AutomationFailure = switch reason {
		case "grant", "foreign", "private": .denied
		case "unloaded": .notLoaded
		case "failed", "hidden": .notReady
		case "authentication": .userActionRequired
		default: .unsupported
		}
		expectNoDifference(fixture.responses, [.failure(failure)])
		expectNoDifference(fixture.calls, [])
	}

	@Test(arguments: ["cancel", "disconnect", "revoke", "grant", "navigation", "closeReopen", "hidden"])
	internal func inFlightCaptureCannotOutliveAuthorityOrNativeDocument(change: String) async throws {
		let fixture = Fixture()
		fixture.holdsCapture = true
		let request = try fixture.request()
		let task = fixture.send(request)
		try await fixture.waitForCapture()

		switch change {
		case "cancel":
			fixture.store.send(.automation(.event(.host(.cancel(request.id)))))

		case "disconnect":
			fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID)))))

		case "revoke":
			fixture.store.send(.automation(.ui(.revokeClient(request.clientID))))

		case "grant":
			var client = fixture.store.automationPreferences.clients[0]
			client.allowsScreenshots = false
			fixture.store.send(.automation(.ui(.updateClient(client))))

		case "hidden":
			fixture.snapshots[fixture.tab.id]?.isVisibleForCapture = false

		case "navigation":
			// Native epoch advances before the queued navigation callback updates URL or revision.
			fixture.snapshots[fixture.tab.id]?.documentRevision = 9

		default:
			fixture.snapshots[fixture.tab.id] = .init(
				navigation: .init(url: fixture.tab.restoration.url),
				revision: 20,
				documentRevision: 8,
				isVisibleForCapture: true
			)
		}
		fixture.releaseCapture()
		await task.finish()
		#expect(!fixture.responses.contains { if case .capture = $0 { true } else { false } })
		#expect(fixture.store.automation.pending.isEmpty)
		expectNoDifference(fixture.calls.count, 1)
	}

	@Test(arguments: ["navigation", "closeReopen", "grant", "disconnect", "hidden"])
	internal func finalResponseRechecksAuthorityAfterSuccessfulCapture(change: String) async throws {
		let fixture = Fixture()
		let request = try fixture.request()
		fixture.beforeRelease = {
			switch change {
			case "hidden": fixture.snapshots[fixture.tab.id]?.isVisibleForCapture = false
			case "navigation": fixture.snapshots[fixture.tab.id]?.documentRevision = 9
			case "closeReopen": fixture.snapshots[fixture.tab.id]?.revision = 20
			case "grant": fixture.store.send(.automation(.ui(.revokeClient(request.clientID))))
			default: fixture.store.send(.automation(.event(.host(.disconnected(sessionID: request.sessionID)))))
			}
		}
		defer { fixture.beforeRelease = nil }
		await fixture.send(request).finish()
		expectNoDifference(fixture.calls.count, 1)
		let expected: AutomationFailure = switch change {
		case "grant", "disconnect": .denied
		case "hidden": .notReady
		default: .staleTarget
		}
		expectNoDifference(fixture.responses, [.failure(expected)])
	}

	@Test(arguments: [1, 0.5])
	internal func jpegCapturesAreReEncodedInTheApp(scale: Double) async throws {
		let fixture = Fixture()
		var request = try fixture.request()
		guard case var .capture(capture) = request.operation else { return }
		capture.format = .jpeg
		capture.quality = 0.5
		capture.scale = scale
		request.operation = .capture(capture)
		await fixture.send(request).finish()
		guard case let .capture(result) = try #require(fixture.responses.first) else {
			Issue.record("JPEG capture did not return pixels")
			return
		}

		expectNoDifference(result.image.format, .jpeg)
		expectNoDifference(Array(result.image.data.prefix(2)), [0xFF, 0xD8])
		expectNoDifference(result.image.width, 1)

		// The native frame is allowed past the delivered cap, so scale and JPEG can shrink it.
		expectNoDifference(fixture.calls.first?.limits.maximumEncodedBytes, 16 * 1024 * 1024)
	}

	@Test
	internal func offscreenCapturesReadAHiddenPageWithoutShowingIt() async throws {
		let fixture = Fixture()
		fixture.snapshots[fixture.tab.id]?.isVisibleForCapture = false
		await fixture.send(try fixture.request()).finish()
		expectNoDifference(fixture.responses, [.failure(.notReady)])

		var request = try fixture.request()
		guard case var .capture(capture) = request.operation else { return }
		capture.offscreen = true
		request.operation = .capture(capture)
		let before = fixture.store.state
		await fixture.send(request).finish()
		guard case let .capture(result) = fixture.responses.last else {
			Issue.record("Offscreen capture did not return pixels")
			return
		}
		expectNoDifference(result.request.offscreen, true)
		expectNoDifference(fixture.calls.last?.offscreen, true)
		expectNoDifference(fixture.store.main, before.main)
		expectNoDifference(fixture.store.focusedWindowID, before.focusedWindowID)
	}

	@Test
	internal func elementCapturesNeedAReleasedSnapshotWithBounds() async throws {
		let fixture = Fixture()
		var request = try fixture.request()
		guard case var .capture(capture) = request.operation else { return }
		capture.mode = .element
		capture.element = .init(snapshotID: "snapshot", reference: "opaque")
		request.operation = .capture(capture)
		await fixture.send(request).finish()
		expectNoDifference(fixture.responses, [.failure(.staleReference)])
		expectNoDifference(fixture.calls, [])
	}

	@Test
	internal func savingAsksThePersonAndReportsOnlyTheFileName() async throws {
		let fixture = Fixture()
		fixture.destination = URL(fileURLWithPath: "/Users/person/Private Folder/Chosen Name.png")
		await fixture.send(try fixture.request(save: true)).finish()
		guard case let .capture(result) = try #require(fixture.responses.first) else {
			Issue.record("Saved capture did not return pixels")
			return
		}

		expectNoDifference(result.save, .saved(fileName: "Chosen Name.png"))
		expectNoDifference(fixture.chooserTitles, ["Example"])
		expectNoDifference(fixture.writes.map(\.url), [fixture.destination])
		expectNoDifference(fixture.writes.map(\.data), [result.image.data])
		let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
		#expect(!encoded.contains("Private Folder"))
	}

	@Test
	internal func cancellingTheSavePanelWritesNothing() async throws {
		let fixture = Fixture()
		fixture.destination = nil
		await fixture.send(try fixture.request(save: true)).finish()
		guard case let .capture(result) = try #require(fixture.responses.first) else {
			Issue.record("Declined save did not return pixels")
			return
		}

		expectNoDifference(result.save, .declined)
		expectNoDifference(fixture.chooserTitles.count, 1)
		expectNoDifference(fixture.writes.count, 0)
	}

	@Test
	internal func unattendedRunsCannotSave() async throws {
		let fixture = Fixture()
		await fixture.store.send(.automation(.ui(.unattended))).finish()
		await fixture.send(try fixture.request(save: true)).finish()
		expectNoDifference(fixture.responses, [.failure(.userActionRequired)])
		expectNoDifference(fixture.calls, [])
		expectNoDifference(fixture.chooserTitles, [])
		expectNoDifference(fixture.writes.count, 0)

		// An ordinary capture still works unattended.
		await fixture.send(try fixture.request()).finish()
		guard case .capture = fixture.responses.last else {
			Issue.record("Unattended capture without save failed")
			return
		}
	}

	@Test
	internal func revokingWhileThePanelIsOpenWritesNothing() async throws {
		let fixture = Fixture()
		let request = try fixture.request(save: true)
		fixture.whileChoosing = {
			fixture.store.send(.automation(.ui(.revokeClient(request.clientID))))
		}
		await fixture.send(request).finish()
		expectNoDifference(fixture.chooserTitles.count, 1)
		expectNoDifference(fixture.writes.count, 0)
		#expect(!fixture.responses.contains { if case .capture = $0 { true } else { false } })
	}

	@Test
	internal func nativeEpochChangeBeforeEffectEntryPreventsCapture() async throws {
		let fixture = Fixture()
		let request = try fixture.request()
		fixture.snapshots[fixture.tab.id]?.documentRevision = 9
		await fixture.send(request).finish()
		expectNoDifference(fixture.calls, [])
		expectNoDifference(fixture.responses, [.failure(.staleTarget)])
	}
}

@MainActor
private final class Fixture {
	fileprivate let tab: BrowserCore.Tab
	fileprivate let other: BrowserCore.Tab
	fileprivate var store: StoreOf<BrowserAutomation>!
	fileprivate var snapshots: [BrowserCore.Tab.ID: BrowserSessionSnapshot]
	fileprivate var calls: [PageCaptureRequest] = []
	fileprivate var responses: [AutomationResult] = []
	fileprivate var available: Bool = true
	fileprivate var holdsCapture: Bool = false
	fileprivate var beforeRelease: (@MainActor () -> Void)?
	fileprivate var destination: URL? = URL(fileURLWithPath: "/Users/person/Pictures/Capture.png")
	fileprivate var chooserTitles: [String] = []
	fileprivate var writes: [(data: Data, url: URL)] = []
	fileprivate var whileChoosing: (@MainActor () -> Void)?
	private var continuation: CheckedContinuation<Void, Never>?
	private var requests: [UUID: AutomationRequest] = [:]
	private var clients: [UUID: AutomationClient] = [:]

	fileprivate init(screenshotsAllowed: Bool = true) {
		let organization = IntegrationFeatureTests().fixture()
		self.tab = organization.tabs[0]
		self.other = organization.tabs[1]
		self.snapshots = [
			tab.id: .init(
				navigation: .init(url: tab.restoration.url),
				revision: 3,
				documentRevision: 8,
				isVisibleForCapture: true
			),
		]
		let client = AutomationClient(
			id: UUID(80),
			name: "Fixture",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [.tab(tab.id, profileID: tab.profileID, location: .space(organization.spaces[0].id))],
			allowsRead: true,
			allowsScreenshots: screenshotsAllowed,
			grantRevision: UUID(82)
		)
		var state = AppFeature.State(
			main: .init(organization: organization, spaceID: organization.spaces[0].id, id: UUID(70)),
			automation: .init(isEnabled: true, clients: [client])
		)
		state.automation.sessions[UUID(81)] = client.id
		self.store = Store(initialState: state) { BrowserAutomation() } withDependencies: { [weak self] dependencies in
			dependencies.uuid = .incrementing
			dependencies.date.now = Date(timeIntervalSince1970: 100)
			dependencies.browserEngine.snapshot = { self?.snapshots[$0] }
			dependencies.browserEngine.open = { _ in Issue.record("Capture loaded a tab") }
			dependencies.browserEngine.command = { _, _ in Issue.record("Capture navigated or scrolled") }
			dependencies.browserCapture.isAvailable = { self?.available == true }
			dependencies.browserCapture.offscreenIsAvailable = { true }
			dependencies.browserCapture.captureAuthorized = { request, authorize in
				guard let self, authorize() else { throw PageCaptureFailure.staleDocument }
				self.calls.append(request)
				if self.holdsCapture {
					await withCheckedContinuation { self.continuation = $0 }
				}
				try Task.checkCancellation()
				guard authorize() else { throw PageCaptureFailure.staleDocument }
				return .init(
					request: request,
					documentID: "fixture-document",
					image: .init(
						png: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!,
						width: 1,
						height: 1
					),
					viewportWidth: 1,
					viewportHeight: 1,
					deviceScale: 1,
					wasLoading: false
				)
			}
			dependencies.pageCaptureExport.chooseDestination = { title, _ in
				guard let self else { return nil }
				self.chooserTitles.append(title)
				self.whileChoosing?()
				return self.destination
			}
			dependencies.pageCaptureExport.write = { data, url in
				await MainActor.run { self?.writes.append((data, url)) }
			}
			dependencies.automationControl.authorize = { id in
				guard let self else { return false }
				return self.store.state.automationCanExecute(id, snapshots: self.snapshots, now: Date(timeIntervalSince1970: 100))
			}
			dependencies.automationControl.respond = { id, result in
				guard let self, let request = self.requests[id] else { return }
				self.beforeRelease?()
				let current = self.store.automationPreferences.clients.first { $0.id == request.clientID }
				let failure = current == self.clients[id]
				? self.store.state.automationResponseValidation(request, result: result, snapshots: self.snapshots)
				: .denied
				self.responses.append(failure.map(AutomationResult.failure) ?? result)
			}
		}
	}

	fileprivate func request(
		region: Bool = false,
		save: Bool = false
	) throws -> AutomationRequest {
		let client = store.automationPreferences.clients[0]
		let item = try #require(AutomationInventoryBuilder.items(
			client: client,
			organization: store.workspace,
			snapshots: snapshots
		).first { $0.id == tab.id.rawValue })
		return .init(
			id: UUID(84),
			clientID: client.id,
			sessionID: UUID(81),
			operation: .capture(.init(
				targetID: item.id,
				expectedRevision: item.revision,
				mode: region ? .region : .viewport,
				region: region ? .init(x: 0, y: 0, width: 1, height: 1) : nil,
				save: save
			))
		)
	}

	fileprivate func send(_ request: AutomationRequest) -> StoreTask {
		requests[request.id] = request
		clients[request.id] = store.automationPreferences.clients.first { $0.id == request.clientID }
		return store.send(.automation(.event(.host(.request(request)))))
	}

	fileprivate func waitForCapture() async throws {
		for _ in 0..<1000 {
			if continuation != nil { return }
			await Task.yield()
		}
		throw AutomationFailure.timedOut
	}

	fileprivate func releaseCapture() {
		continuation?.resume()
		continuation = nil
	}
}
