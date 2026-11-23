import BrowserCore
import BrowserMCPServer
import Darwin
import Foundation
import Testing
import _MCP

internal struct BoundedTransportTests {
	@Test(.timeLimit(.minutes(1)))
	internal func malformedBatchDuplicateAndOversizedFramesAreBounded() async throws {
		let input = Pipe()
		let output = Pipe()
		let transport = BoundedStdioTransport(
			input: input.fileHandleForReading.fileDescriptor,
			output: output.fileHandleForWriting.fileDescriptor
		)
		try await transport.connect()
		let readDescriptor = output.fileHandleForReading.fileDescriptor
		_ = fcntl(readDescriptor, F_SETFL, O_NONBLOCK)
		try input.fileHandleForWriting.write(contentsOf: Data("[]\n".utf8))
		let malformed = try await response(readDescriptor)
		#expect(malformed.contains("-32700"))
		let frame = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}\n"
		try input.fileHandleForWriting.write(contentsOf: Data((frame + frame).utf8))
		let duplicate = try await response(readDescriptor)
		#expect(duplicate.contains("duplicate request ID"))
		let oversized = Data(repeating: 120, count: 66_000)
		let writer = Task.detached { try input.fileHandleForWriting.write(contentsOf: oversized) }
		let oversizedResponse = try await response(readDescriptor)
		#expect(oversizedResponse.contains("64 KiB"))
		_ = try await writer.value
		await transport.disconnect()
	}

	@Test(.timeLimit(.minutes(1)))
	internal func frameLimitsApplyToEachMessageRatherThanACombinedRead() async throws {
		let input = Pipe()
		let output = Pipe()
		let transport = BoundedStdioTransport(
			input: input.fileHandleForReading.fileDescriptor,
			output: output.fileHandleForWriting.fileDescriptor
		)
		try await transport.connect()
		func frame(
			_ id: Int,
			count: Int
		) throws -> Data {
			var data = try JSONSerialization.data(withJSONObject: [
				"jsonrpc": "2.0",
				"id": id,
				"method": "ping",
				"padding": String(repeating: "x", count: count),
			])
			data.append(10)
			return data
		}

		let first = try frame(1, count: 65_000)
		let second = try frame(2, count: 2000)
		let writer = Task.detached { try input.fileHandleForWriting.write(contentsOf: first + second) }
		var iterator = await transport.receive().makeAsyncIterator()
		#expect(try await iterator.next()?.count == first.count - 1)
		#expect(try await iterator.next()?.count == second.count - 1)
		_ = try await writer.value
		await transport.disconnect()
	}

	/// Codex 0.167.1's `initialize`, recorded from `codex exec` (DEV-643). Its experimental
	/// capability is an object, which the SDK can't read.
	@Test(.timeLimit(.minutes(1)))
	internal func codexsHandshakeReachesTheServerWithoutExperimentalCapabilities() async throws {
		let input = Pipe()
		let output = Pipe()
		let transport = BoundedStdioTransport(
			input: input.fileHandleForReading.fileDescriptor,
			output: output.fileHandleForWriting.fileDescriptor
		)
		try await transport.connect()
		let initialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.167.1"}}}"#
		let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
		try input.fileHandleForWriting.write(contentsOf: Data((initialize + "\n" + ping + "\n").utf8))

		var iterator = await transport.receive().makeAsyncIterator()
		let received = try #require(try await iterator.next())
		let object = try JSONDecoder().decode([String: Value].self, from: received)
		guard
			case let .object(parameters) = object["params"],
			case let .object(capabilities) = parameters["capabilities"],
			case let .object(client) = parameters["clientInfo"]
		else {
			Issue.record("initialize lost its parameters")
			return
		}
		#expect(capabilities["experimental"] == nil)
		#expect(capabilities["elicitation"] != nil)
		#expect(client["name"] == .string("codex-mcp-client"))
		#expect(object["id"] == .int(0))
		// The SDK's own type now reads it.
		#expect((try? JSONDecoder().decode(Client.Capabilities.self, from: JSONEncoder().encode(parameters["capabilities"]))) != nil)

		// Other messages pass unchanged.
		#expect(try await iterator.next() == Data(ping.utf8))
		await transport.disconnect()
	}

	@Test
	internal func onlyAnInitializeWithExperimentalCapabilitiesChanges() throws {
		let claude = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{}},"clientInfo":{"name":"claude-code","version":"2"}}}"#
		let call = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"capabilities":{"experimental":{"x":{}}}}}"#
		for message in [claude, call] {
			let object = try JSONDecoder().decode([String: Value].self, from: Data(message.utf8))
			#expect(BoundedStdioTransport.compatibleHandshake(object) == nil)
		}
	}

	@Test(.timeLimit(.minutes(1)))
	internal func closingTheStdioReaderReturnsDisconnectedWithoutASignal() async throws {
		let input = Pipe()
		let output = Pipe()
		let transport = BoundedStdioTransport(
			input: input.fileHandleForReading.fileDescriptor,
			output: output.fileHandleForWriting.fileDescriptor
		)
		try await transport.connect()
		try #require(fcntl(output.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1)
		try output.fileHandleForReading.close()
		await #expect(throws: AutomationFailure.disconnected) {
			try await transport.send(Data("{}".utf8))
		}
		await transport.disconnect()
	}

	private func response(_ descriptor: Int32) async throws -> String {
		var data = Data()
		var buffer = [UInt8](repeating: 0, count: 4096)
		let deadline = ContinuousClock.now + .seconds(3)
		while !data.contains(10) {
			guard ContinuousClock.now < deadline else { throw AutomationFailure.timedOut }
			let count = read(descriptor, &buffer, buffer.count)
			if count > 0 {
				data.append(contentsOf: buffer.prefix(count))
			} else {
				try await Task.sleep(for: .milliseconds(10))
			}
		}
		return String(decoding: data, as: UTF8.self)
	}
}
