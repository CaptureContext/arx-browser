#if DEBUG
import Foundation
import _MCP

extension AutomationScrollSmoke {
	/// Geometry belongs only to the owned loopback fixture, never the public MCP receipt.
	internal struct Evidence: Equatable, Sendable {
		internal let offsets: [String: Double]
		internal let sample: Int
		internal let events: Int
		internal let innerAtEnd: Bool

		internal init(
			offsets: [String: Double],
			sample: Int,
			events: Int,
			innerAtEnd: Bool
		) {
			self.offsets = offsets
			self.sample = sample
			self.events = events
			self.innerAtEnd = innerAtEnd
		}

		internal func matches(_ changed: [String: Double] = [:]) -> Bool {
			guard Set(changed.keys).isSubset(of: Set(offsets.keys)) else { return false }
			return offsets.allSatisfy { key, value in abs(value - (changed[key] ?? 0)) <= 1 }
		}
	}

	internal static func decodeEvidence(_ data: Data) throws -> Evidence {
		let offsetKeys: Set<String> = ["innerX", "innerY", "outerX", "outerY", "pageX", "pageY"]
		let fieldKeys = offsetKeys.union(["sample", "events", "focused", "activation", "trusted", "innerAtEnd"])
		guard
			data.count <= 4096,
			case let .object(fields) = try JSONDecoder().decode(Value.self, from: data),
			Set(fields.keys) == fieldKeys,
			case let .int(sample) = fields["sample"],
			(1...10_000).contains(sample),
			case let .int(events) = fields["events"],
			(0...10_000).contains(events),
			fields["focused"] == .bool(false),
			fields["activation"] == .bool(false),
			fields["trusted"] == .bool(true),
			case let .bool(innerAtEnd) = fields["innerAtEnd"]
		else { throw AutomationSmokeFailure.invalidResponse }

		var offsets: [String: Double] = [:]
		for key in offsetKeys {
			let value: Double
			switch fields[key] {
			case let .double(number): value = number
			case let .int(number): value = Double(number)
			default: throw AutomationSmokeFailure.invalidResponse
			}
			guard value.isFinite, abs(value) <= 100_000
			else { throw AutomationSmokeFailure.invalidResponse }
			offsets[key] = value
		}
		return .init(offsets: offsets, sample: sample, events: events, innerAtEnd: innerAtEnd)
	}

	internal static func evidence(
		at url: URL,
		after sample: Int = 0,
		until ready: @Sendable (Evidence) -> Bool
	) async throws -> Evidence {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.timeoutIntervalForRequest = 2
		let connection = URLSession(configuration: configuration)
		defer { connection.invalidateAndCancel() }

		for _ in 0..<50 {
			let (data, response) = try await connection.data(from: url)
			if (response as? HTTPURLResponse)?.statusCode == 404 {
				try await Task.sleep(for: .milliseconds(40))
				continue
			}
			guard (response as? HTTPURLResponse)?.statusCode == 200
			else { throw AutomationSmokeFailure.scrollMismatch }
			let value = try decodeEvidence(data)
			if value.sample > sample && ready(value) { return value }
			try await Task.sleep(for: .milliseconds(40))
		}
		throw AutomationSmokeFailure.scrollMismatch
	}
}
#endif
