import BrowserAutomationClient
import BrowserCore
import Darwin
import Foundation
import _MCP

public actor BoundedStdioTransport: Transport {
	public nonisolated let logger: Logger = .init(
		label: "arx.mcp",
		factory: { _ in SwiftLogNoOpLogHandler() }
	)

	private let input: Int32
	private let output: Int32
	private let stream: AsyncThrowingStream<Data, any Error>
	private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
	private var reader: Task<Void, Never>?
	private var writer: Task<Void, any Error>?
	private var activeRequests: Set<Value> = []
	private var isConnected: Bool = false

	public init(
		input: Int32 = STDIN_FILENO,
		output: Int32 = STDOUT_FILENO
	) {
		self.input = input
		self.output = output
		(self.stream, self.continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(32))
	}

	public func connect() throws {
		guard !isConnected else { return }
		for descriptor in [input, output] {
			let flags = fcntl(descriptor, F_GETFL)
			guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
			else { throw AutomationFailure.disconnected }
		}

		// Suppress EPIPE signals on this pipe only; the embedding process keeps its signal policy.
		guard fcntl(output, F_SETNOSIGPIPE, 1) == 0 else { throw AutomationFailure.disconnected }
		isConnected = true
		reader = Task { await readMessages() }
	}

	public func disconnect() {
		isConnected = false
		reader?.cancel()
		writer?.cancel()
		continuation.finish()
	}

	public func receive() -> AsyncThrowingStream<Data, any Error> { stream }

	public func send(_ data: Data) async throws {
		// Tool results are bounded before they get here; captures may use the larger image frame.
		guard isConnected, data.count <= AutomationIPC.maximumImageResponseBytes
		else { throw AutomationFailure.limitExceeded }
		let response = try? JSONDecoder().decode([String: Value].self, from: data)
		let isResponse = response?["result"] != nil || response?["error"] != nil
		if isResponse, let id = response?["id"] { activeRequests.remove(id) }
		let previous = writer
		let descriptor = output
		let task = Task {
			try await previous?.value
			try await Self.writeFrame(data, to: descriptor)
		}
		writer = task
		try await task.value
	}

	private func readMessages() async {
		var pending = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		while isConnected && !Task.isCancelled {
			let count = Darwin.read(input, &buffer, buffer.count)
			if count == 0 { break }
			if count < 0 {
				if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
					// Waits for the agent instead of waking 100 times a second while idle.
					do {
						try await DescriptorReadiness.wait(for: .readable, on: input)
					} catch {
						break
					}
					continue
				}
				break
			}
			pending.append(contentsOf: buffer.prefix(count))
			while let newline = pending.firstIndex(of: 10) {
				var frame = Data(pending[..<newline])
				pending.removeSubrange(...newline)
				guard frame.count <= 65_536 else {
					await reject(id: .null, code: -32600, message: "Message exceeds the 64 KiB limit")
					continuation.finish()
					return
				}
				if frame.isEmpty { continue }
				guard
					let object = try? JSONDecoder().decode([String: Value].self, from: frame),
					object["jsonrpc"] == .string("2.0")
				else {
					await reject(id: .null, code: -32700, message: "Expected one JSON-RPC object")
					continue
				}
				if
					let compatible = Self.compatibleHandshake(object),
					let data = try? JSONEncoder().encode(compatible)
				{
					frame = data
				}
				if object["method"] != nil, let id = object["id"] {
					let validID: Bool
					switch id {
					case let .string(value): validID = !value.isEmpty && value.utf8.count <= 128
					case .int: validID = true
					default: validID = false
					}
					guard validID, activeRequests.count < 16, activeRequests.insert(id).inserted else {
						await reject(id: .null, code: -32600, message: "Too many requests or duplicate request ID")
						continue
					}
				}
				if case .dropped = continuation.yield(frame) {
					await reject(id: object["id"] ?? .null, code: -32600, message: "Request buffer is full")
				}
			}
			if pending.count > 65_536 {
				await reject(id: .null, code: -32600, message: "Message exceeds the 64 KiB limit")
				break
			}
		}
		continuation.finish()
	}

	/// The `initialize` request without the client's `experimental` capabilities, or `nil` when
	/// the message needs no change.
	///
	/// The MCP specification lets each experimental capability be any object, but the SDK reads
	/// them only as strings and would refuse the whole handshake. Codex 0.167 announces
	/// `"codex/auth-change": {}`, so its `initialize` failed and Codex, which requires Arx's
	/// server, never started a turn (DEV-643). Arx reads none of these capabilities.
	public static func compatibleHandshake(_ object: [String: Value]) -> [String: Value]? {
		guard
			object["method"] == .string("initialize"),
			case var .object(parameters) = object["params"],
			case var .object(capabilities) = parameters["capabilities"],
			capabilities["experimental"] != nil
		else { return nil }

		capabilities["experimental"] = nil
		parameters["capabilities"] = .object(capabilities)
		var compatible: [String: Value] = object
		compatible["params"] = .object(parameters)
		return compatible
	}

	private func reject(
		id: Value,
		code: Int,
		message: String
	) async {
		let response: Value = .object([
			"jsonrpc": .string("2.0"),
			"id": id,
			"error": .object(["code": .int(code), "message": .string(message)]),
		])
		if let data = try? JSONEncoder().encode(response) { try? await send(data) }
	}

	private static func writeFrame(
		_ data: Data,
		to descriptor: Int32
	) async throws {
		var frame = data
		frame.append(10)
		var offset = 0
		let deadline = ContinuousClock.now + .seconds(30)
		while offset < frame.count {
			try Task.checkCancellation()
			guard ContinuousClock.now < deadline else { throw AutomationFailure.timedOut }
			let count = frame.withUnsafeBytes { bytes in
				Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
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
