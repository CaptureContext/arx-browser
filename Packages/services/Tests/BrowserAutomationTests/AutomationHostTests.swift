import BrowserAutomationClient
import BrowserCore
import CustomDump
import Darwin
import Foundation
import Testing
import _Dependencies
import _TestSupport

@MainActor
internal struct AutomationHostTests {
	@Test(.timeLimit(.minutes(1)), arguments: ["allowed", "large", "grant", "document", "encodedSize"])
	internal func captureReleaseChecksLiveAuthorityAndExactFrame(change: String) async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-capture-" + UUID().uuidString.prefix(10))
		defer { try? FileManager.default.removeItem(at: directory) }

		var client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		client.allowsScreenshots = true
		let authority = CaptureReleaseAuthority(
			preferences: AutomationPreferences(isEnabled: true, clients: [client])
		)
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { authority.preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in authority.failure }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}

		var capture = AutomationCaptureTests.result()
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .capture(capture.request))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}

		switch change {
		case "grant":
			authority.preferences.clients[0].allowsScreenshots = false

		case "document":
			authority.failure = .staleTarget

		case "large":
			// Far above the plain 256 KiB frame, within the image frame.
			capture.image.data = Data(repeating: 0x41, count: AutomationCaptureTests.largeImageBytes)

		case "encodedSize":
			// The image meets its byte limit, but JSON's escaped base64 exceeds the frame limit.
			capture.image.data = Data(repeating: 255, count: AutomationCaptureResult.maximumImageBytes)
			let encodedReply = try JSONEncoder().encode(AutomationIPC.Reply.result(.capture(capture)))
			#expect(encodedReply.count > AutomationIPC.maximumImageResponseBytes)

		default: break
		}

		host.respond(requestID, result: .capture(capture))
		let reply = try await request.value
		switch (change, reply) {
		case let ("allowed", .result(.capture(value))), let ("large", .result(.capture(value))):
			#expect(value == capture)
		case ("grant", .failure(.denied)), ("document", .failure(.staleTarget)), ("encodedSize", .failure(.limitExceeded)): break
		default: Issue.record("Capture escaped its final release boundary")
		}
		await host.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func authenticationRevocationCancellationAndRestartRejectStaleSessions() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		let sessionID = UUID(10)
		func exchange(
			_ payload: AutomationIPC.Payload,
			epoch: UUID? = nil,
			token: String = String(repeating: "0", count: 64),
			session: UUID = sessionID
		) async throws -> AutomationIPC.Reply {
			try await LocalAutomationSocket.exchange(
				path: path,
				envelope: .init(
					clientID: client.id,
					credential: token,
					sessionID: session,
					epoch: epoch,
					payload: payload
				)
			)
		}

		guard case .failure(.invalidCredential) = try await exchange(.hello, token: String(repeating: "1", count: 64)) else {
			Issue.record("Forged credential accepted")
			await host.stop()
			return
		}
		guard case let .hello(epoch) = try await exchange(.hello) else {
			Issue.record("Valid hello denied")
			await host.stop()
			return
		}
		let wrongEpochReply = try await exchange(.request(UUID(11), .inventory(cursor: nil, limit: 1)), epoch: UUID())
		guard case .failure(.staleSession) = wrongEpochReply else {
			Issue.record("Wrong epoch accepted")
			await host.stop()
			return
		}
		let requestID = UUID(12)
		let request = Task { try await exchange(.request(requestID, .inventory(cursor: nil, limit: 1)), epoch: epoch) }
		for await event in events {
			if case let .request(value) = event, value.id == requestID { break }
		}
		host.revoke(client.id)
		guard case .failure(.disconnected) = try await request.value else {
			Issue.record("Revoked request was not cancelled")
			await host.stop()
			return
		}
		guard case .failure(.staleSession) = try await exchange(.ping, epoch: epoch) else {
			Issue.record("Revoked session reused")
			await host.stop()
			return
		}
		await host.stop()
		host.configure(preferences: { .init() }, receive: { _ in })
		await #expect(throws: AutomationFailure.disabled) { try await host.enable() }
	}

	@Test(.timeLimit(.minutes(1)))
	internal func stopCancelsPendingRequestAndNewHostRejectsOldEpoch() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		envelope.epoch = epoch
		envelope.payload = .request(UUID(), .inventory(cursor: nil, limit: 1))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		await host.stop()
		do {
			guard case .failure(.disabled) = try await request.value else {
				Issue.record("Stop did not terminate pending request")
				return
			}
		} catch AutomationFailure.disconnected {
			// Stopping also cancels socket I/O; the connection may close before its disabled frame is written.
		}
		let replacement = BrowserAutomationHost(directory: directory)
		replacement.configure(preferences: { preferences }, receive: { _ in })
		_ = try await replacement.enable()
		guard case .failure(.staleSession) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Stale request survived restart")
			await replacement.stop()
			return
		}
		await replacement.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func explicitCancellationAndDeadlineEndPendingWork() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let clock: TestClock<Duration> = .init()
		let host = BrowserAutomationHost(directory: directory, clock: AnyClock(clock))
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		envelope.epoch = epoch
		let requestID = UUID()
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		envelope.payload = .cancel(requestID)
		guard case .acknowledged = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Cancellation denied")
			await host.stop()
			return
		}
		guard case .failure(.cancelled) = try await request.value else {
			Issue.record("Cancelled request survived")
			await host.stop()
			return
		}
		let earlyID = UUID()
		envelope.payload = .cancel(earlyID)
		guard case .acknowledged = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Early cancellation denied")
			await host.stop()
			return
		}
		envelope.payload = .request(earlyID, .inventory(cursor: nil, limit: 1))
		guard case .failure(.cancelled) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Request outran cancellation")
			await host.stop()
			return
		}
		envelope.payload = .request(UUID(), .inventory(cursor: nil, limit: 1))
		let expiringEnvelope = envelope
		let expiring = Task { try await LocalAutomationSocket.exchange(path: path, envelope: expiringEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		await clock.advance(by: .seconds(30))
		guard case .failure(.timedOut) = try await expiring.value else {
			Issue.record("Request deadline not enforced")
			await host.stop()
			return
		}
		await host.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func disconnectedPeerCancelsTheSessionBeforeTheRequestDeadline() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		envelope.epoch = epoch
		let requestID = UUID()
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard connected == 0 else {
			Darwin.close(descriptor)
			await host.stop()
			throw AutomationFailure.appUnavailable
		}
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var frame = try JSONEncoder().encode(envelope)
		frame.append(10)
		try handle.write(contentsOf: frame)
		var iterator = events.makeAsyncIterator()
		while let event = await iterator.next() {
			if case .request = event { break }
		}
		try handle.close()
		var cancelled = false
		while let event = await iterator.next() {
			if case let .cancel(id) = event, id == requestID {
				cancelled = true
				break
			}
		}
		#expect(cancelled)
		envelope.payload = .ping
		guard case .failure(.staleSession) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Disconnected peer retained its session")
			await host.stop()
			return
		}
		await host.stop()
	}

	@Test(.timeLimit(.minutes(1)), arguments: ["enabled", "client", "grant", "read", "scope", "credential"])
	internal func responseRechecksAuthorityBeforeReleasingQueuedContent(change: String) async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		var preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}

		// The app's preference edit is synchronous, but its revoke/stop effect has not run yet.
		switch change {
		case "enabled": preferences.isEnabled = false
		case "client": preferences.clients.removeAll()
		case "grant": preferences.clients[0].grantRevision = UUID()
		case "read": preferences.clients[0].allowsRead = false
		case "scope": preferences.clients[0].scopes.removeAll()
		default: preferences.clients[0].credentialDigest = String(repeating: "1", count: 64)
		}
		host.respond(requestID, result: .inventory(.init(items: [])))
		let reply = try await request.value
		if case .failure = reply {} else { Issue.record("Queued content escaped after authority changed") }
		await host.stop()
	}

	@Test(.timeLimit(.minutes(1)), arguments: [false, true])
	internal func responseRequiresLiveApplicationAuthorization(callbackConfigured: Bool) async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		var observed: [UUID] = []
		if callbackConfigured {
			host.configure(
				preferences: { preferences },
				receive: { continuation.yield($0) },
				authorizeResponse: { request, _ in
					observed.append(request.id)
					return .staleTarget
				}
			)
		} else {
			host.configure(preferences: { preferences }, receive: { continuation.yield($0) })
		}
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		for await event in events {
			if case .request = event { break }
		}
		host.respond(requestID, result: .inventory(.init(items: [])))
		guard case let .failure(failure) = try await request.value else {
			Issue.record("Unauthorized response escaped")
			await host.stop()
			return
		}
		expectNoDifference(failure, callbackConfigured ? .staleTarget : .denied)
		expectNoDifference(observed, callbackConfigured ? [requestID] : [])
		await host.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func concurrentSocketClientsDoNotBlockTheCooperativeExecutor() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let socket = LocalAutomationSocket()
		let path = try await socket.start(directory: directory) { _ in .acknowledged }
		try await withThrowingTaskGroup(of: Void.self) { group in
			for _ in 0..<24 {
				group.addTask {
					let reply = try await LocalAutomationSocket.exchange(
						path: path,
						envelope: .init(
							clientID: UUID(),
							credential: "synthetic",
							sessionID: UUID(),
							payload: .hello
						)
					)
					guard case .acknowledged = reply else { throw AutomationFailure.invalidRequest }
				}
			}
			try await group.waitForAll()
		}
		await socket.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func cancellingAnExchangeClosesThePeerAndCancelsPendingWork() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let pendingEnvelope = envelope
		let request = Task { try await LocalAutomationSocket.exchange(path: path, envelope: pendingEnvelope) }
		var iterator = events.makeAsyncIterator()
		while let event = await iterator.next() {
			if case .request = event { break }
		}
		request.cancel()
		await #expect(throws: CancellationError.self) { try await request.value }
		while let event = await iterator.next() {
			if case let .cancel(id) = event, id == requestID { break }
		}
		await host.stop()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func lateReplyToClosedPeerDoesNotTerminateTheHost() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserAutomationTests.client(BrowserAutomationTests.organization())
		let preferences = AutomationPreferences(isEnabled: true, clients: [client])
		let host = BrowserAutomationHost(directory: directory)
		let (events, continuation) = AsyncStream<AutomationHostEvent>.makeStream()
		host.configure(
			preferences: { preferences },
			receive: { continuation.yield($0) },
			authorizeResponse: { _, _ in nil }
		)
		let path = try await host.enable()
		var envelope = AutomationIPC.Envelope(
			clientID: client.id,
			credential: String(repeating: "0", count: 64),
			sessionID: UUID(),
			payload: .hello
		)
		guard case let .hello(epoch) = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Handshake failed")
			await host.stop()
			return
		}
		let requestID = UUID()
		envelope.epoch = epoch
		envelope.payload = .request(requestID, .inventory(cursor: nil, limit: 1))
		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		try #require(descriptor >= 0)
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var enabled: Int32 = 1
		try #require(setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0)
		var address = sockaddr_un()
		address.sun_family = sa_family_t(AF_UNIX)
		address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
		let connected = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		try #require(connected == 0)
		var frame = try JSONEncoder().encode(envelope)
		frame.append(10)
		try handle.write(contentsOf: frame)
		for await event in events {
			if case .request = event { break }
		}
		try handle.close()

		// Release the response synchronously, before the peer-disconnect monitor gets another turn.
		host.respond(requestID, result: .failure(.denied))
		envelope.sessionID = UUID()
		envelope.epoch = nil
		envelope.payload = .hello
		guard case .hello = try await LocalAutomationSocket.exchange(path: path, envelope: envelope) else {
			Issue.record("Late write prevented the next client from connecting")
			await host.stop()
			return
		}
		await host.stop()
	}

	@Test
	internal func socketRejectsWorldReadableDirectoryAndOversizedFrames() async throws {
		let directory = URL(fileURLWithPath: "/tmp/arx-mcp-test-" + UUID().uuidString.prefix(12))
		defer { try? FileManager.default.removeItem(at: directory) }
		try FileManager.default.createDirectory(
			at: directory,
			withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o755]
		)
		let socket = LocalAutomationSocket()
		await #expect(throws: AutomationFailure.denied) {
			try await socket.start(directory: directory) { _ in .acknowledged }
		}
		try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
		let path = try await socket.start(directory: directory) { _ in .acknowledged }
		let envelope = AutomationIPC.Envelope(
			clientID: UUID(),
			credential: String(repeating: "x", count: 70_000),
			sessionID: UUID(),
			payload: .hello
		)
		await #expect(throws: AutomationFailure.limitExceeded) {
			try await LocalAutomationSocket.exchange(path: path, envelope: envelope)
		}
		await socket.stop()
	}
}

@MainActor
private final class CaptureReleaseAuthority {
	internal var preferences: AutomationPreferences
	internal var failure: AutomationFailure?

	internal init(preferences: AutomationPreferences) {
		self.preferences = preferences
		self.failure = nil
	}
}
