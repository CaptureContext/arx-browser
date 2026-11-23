import BrowserCore
import Darwin
import Foundation

public actor LocalAutomationSocket {
	public typealias Handler = @Sendable (AutomationIPC.Envelope) async -> AutomationIPC.Reply

	private var listener: Int32?
	private var loop: Task<Void, Never>?
	private var connections: [UUID: Task<Void, Never>] = [:]
	private var path: String?

	public init() {}

	public func start(
		directory: URL,
		handler: @escaping Handler
	) throws -> String {
		guard listener == nil else { throw AutomationFailure.busy }
		let path = directory.appendingPathComponent("ipc.sock").path
		try SocketIO.prepareDirectory(directory.path)
		try SocketIO.removeStaleSocket(path)
		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw AutomationFailure.appUnavailable }
		var ownsSocket = false
		do {
			var address = try SocketIO.address(path)
			let result = withUnsafePointer(to: &address) {
				$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
					Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
				}
			}
			guard result == 0 else { throw AutomationFailure.appUnavailable }
			ownsSocket = true
			guard
				chmod(path, 0o600) == 0,
				listen(descriptor, Int32(AutomationIPC.maximumConnections)) == 0,
				fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
			else { throw AutomationFailure.appUnavailable }
			self.listener = descriptor
			self.path = path
			self.loop = Task { await acceptConnections(handler: handler) }
			return path
		} catch {
			Darwin.close(descriptor)
			if ownsSocket { unlink(path) }
			throw error
		}
	}

	public func stop() async {
		let loop = self.loop
		self.loop = nil
		loop?.cancel()

		// The accept loop's readiness wait must detach from the listener before it closes.
		await loop?.value
		if let listener { Darwin.close(listener) }
		listener = nil
		if let path { unlink(path) }
		path = nil
		for task in connections.values { task.cancel() }
		connections.removeAll()
	}

	private func acceptConnections(handler: @escaping Handler) async {
		while !Task.isCancelled, let listener {
			let descriptor = accept(listener, nil, nil)
			guard descriptor >= 0 else {
				if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR { return }
				do {
					try await DescriptorReadiness.wait(for: .readable, on: listener)
				} catch {
					return
				}
				continue
			}
			guard
				connections.count < AutomationIPC.maximumConnections,
				SocketIO.sameUser(descriptor)
			else {
				Darwin.close(descriptor)
				continue
			}
			let id = UUID()
			connections[id] = Task.detached { [weak self] in
				defer { Darwin.close(descriptor) }
				let reply: AutomationIPC.Reply
				do {
					try SocketIO.configure(descriptor)
					let data = try await SocketIO.read(
						descriptor,
						limit: AutomationIPC.maximumRequestBytes,
						deadline: .now + .seconds(2)
					)
					let envelope = try JSONDecoder().decode(AutomationIPC.Envelope.self, from: data)
					guard envelope.version == AutomationIPC.protocolVersion
					else { throw AutomationFailure.invalidRequest }

					try Task.checkCancellation()
					let monitor = Task.detached {
						guard case .request = envelope.payload else { return }
						while !Task.isCancelled {
							// A peer that hangs up makes the socket readable with zero bytes.
							do {
								try await DescriptorReadiness.wait(for: .readable, on: descriptor)
							} catch {
								return
							}

							var byte: UInt8 = 0
							if recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 {
								var disconnected = envelope
								disconnected.payload = .disconnect
								_ = await handler(disconnected)
								return
							}

							// Unexpected extra bytes stay readable; check again later instead of spinning.
							do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
						}
					}
					reply = await handler(envelope)
					monitor.cancel()
					await monitor.value
				} catch {
					reply = .failure(error as? AutomationFailure ?? .invalidRequest)
				}
				if var data = try? JSONEncoder().encode(reply) {
					if data.count > AutomationIPC.maximumFrameBytes {
						data = (try? JSONEncoder().encode(AutomationIPC.Reply.failure(.limitExceeded))) ?? Data()
					}

					// The peer may already be gone; there is nobody left to report a failed reply to.
					try? await SocketIO.write(
						descriptor,
						data: data,
						limit: AutomationIPC.maximumFrameBytes,
						// An image frame is megabytes; a live peer drains it well within this.
						deadline: .now + .seconds(10)
					)
				}
				await self?.finished(id)
			}
		}
	}

	private func finished(_ id: UUID) { connections[id] = nil }

	public static func exchange(
		path: String,
		envelope: AutomationIPC.Envelope
	) async throws -> AutomationIPC.Reply {
		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw AutomationFailure.appUnavailable }
		defer { Darwin.close(descriptor) }
		try SocketIO.configure(descriptor)
		try await SocketIO.connect(descriptor, path: path, deadline: .now + .seconds(2))
		guard SocketIO.sameUser(descriptor) else { throw AutomationFailure.denied }
		try await SocketIO.write(
			descriptor,
			data: JSONEncoder().encode(envelope),
			limit: AutomationIPC.maximumRequestBytes,
			deadline: .now + .seconds(2)
		)
		let data = try await SocketIO.read(
			descriptor,
			limit: AutomationIPC.maximumFrameBytes,
			deadline: .now + .seconds(35)
		)
		return try JSONDecoder().decode(AutomationIPC.Reply.self, from: data)
	}
}

private enum SocketIO {
	internal static func address(_ path: String) throws -> sockaddr_un {
		var value = sockaddr_un()
		let bytes = Array(path.utf8) + [0]
		guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path)
		else { throw AutomationFailure.invalidRequest }

		value.sun_family = sa_family_t(AF_UNIX)
		value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
		withUnsafeMutableBytes(of: &value.sun_path) { destination in destination.copyBytes(from: bytes) }
		return value
	}

	internal static func configure(_ descriptor: Int32) throws {
		let flags = fcntl(descriptor, F_GETFL)
		var enabled: Int32 = 1
		guard
			flags >= 0,
			fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
			setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
		else { throw AutomationFailure.appUnavailable }
	}

	internal static func connect(
		_ descriptor: Int32,
		path: String,
		deadline: ContinuousClock.Instant
	) async throws {
		try Task.checkCancellation()
		var address = try self.address(path)
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		if result == 0 { return }
		guard errno == EINPROGRESS || errno == EINTR
		else { throw AutomationFailure.appUnavailable }
		while true {
			try Task.checkCancellation()
			guard ContinuousClock.now < deadline else { throw AutomationFailure.timedOut }
			var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
			let ready = poll(&event, 1, 0)
			if ready > 0 {
				var error: Int32 = 0
				var size = socklen_t(MemoryLayout<Int32>.size)
				guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0
				else { throw AutomationFailure.appUnavailable }

				return
			}
			guard ready == 0 || errno == EINTR else { throw AutomationFailure.appUnavailable }
			try await DescriptorReadiness.wait(
				for: .writable,
				on: descriptor,
				until: deadline,
				timeout: AutomationFailure.timedOut
			)
		}
	}

	internal static func sameUser(_ descriptor: Int32) -> Bool {
		var user: uid_t = 0
		var group: gid_t = 0
		return getpeereid(descriptor, &user, &group) == 0 && user == geteuid()
	}

	internal static func prepareDirectory(_ path: String) throws {
		if mkdir(path, 0o700) != 0, errno != EEXIST { throw AutomationFailure.appUnavailable }
		var attributes = stat()
		guard
			lstat(path, &attributes) == 0,
			attributes.st_uid == geteuid(),
			(attributes.st_mode & S_IFMT) == S_IFDIR,
			(attributes.st_mode & 0o077) == 0
		else { throw AutomationFailure.denied }
	}

	internal static func removeStaleSocket(_ path: String) throws {
		var attributes = stat()
		guard lstat(path, &attributes) == 0 else {
			if errno == ENOENT { return }
			throw AutomationFailure.appUnavailable
		}
		guard attributes.st_uid == geteuid(), (attributes.st_mode & S_IFMT) == S_IFSOCK
		else { throw AutomationFailure.denied }

		let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
		guard descriptor >= 0 else { throw AutomationFailure.appUnavailable }
		defer { Darwin.close(descriptor) }
		guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
		else { throw AutomationFailure.appUnavailable }

		var address = try self.address(path)
		let result = withUnsafePointer(to: &address) {
			$0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
				Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		guard result != 0, errno == ECONNREFUSED else { throw AutomationFailure.busy }
		guard unlink(path) == 0 else { throw AutomationFailure.appUnavailable }
	}

	internal static func read(
		_ descriptor: Int32,
		limit: Int,
		deadline: ContinuousClock.Instant
	) async throws -> Data {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 65_536)
		while true {
			try Task.checkCancellation()
			guard ContinuousClock.now < deadline else { throw AutomationFailure.timedOut }
			let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
			if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
				try await DescriptorReadiness.wait(
					for: .readable,
					on: descriptor,
					until: deadline,
					timeout: AutomationFailure.timedOut
				)
				continue
			}
			guard count > 0 else { throw AutomationFailure.disconnected }
			let start = data.endIndex
			data.append(contentsOf: buffer.prefix(count))
			guard data.count <= limit else { throw AutomationFailure.limitExceeded }

			// Only the new bytes can hold the frame's end.
			if let newline = data[start...].firstIndex(of: 10) {
				guard newline == data.index(before: data.endIndex)
				else { throw AutomationFailure.invalidRequest }

				return Data(data[..<newline])
			}
		}
	}

	internal static func write(
		_ descriptor: Int32,
		data: Data,
		limit: Int,
		deadline: ContinuousClock.Instant
	) async throws {
		guard data.count < limit else { throw AutomationFailure.limitExceeded }
		var framed = data
		framed.append(10)
		var offset = 0
		while offset < framed.count {
			try Task.checkCancellation()
			guard ContinuousClock.now < deadline else { throw AutomationFailure.timedOut }
			let count = framed.withUnsafeBytes { buffer in
				Darwin.send(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, MSG_NOSIGNAL)
			}
			if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
				try await DescriptorReadiness.wait(
					for: .writable,
					on: descriptor,
					until: deadline,
					timeout: AutomationFailure.timedOut
				)
				continue
			}
			guard count > 0 else { throw AutomationFailure.disconnected }
			offset += count
		}
	}
}
