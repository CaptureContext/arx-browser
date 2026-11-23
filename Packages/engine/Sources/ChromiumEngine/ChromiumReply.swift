import Foundation
import IssueReporting

/// JSON exchanged with Arx's own native bridge (DEV-969). Both sides are ours, so a reply that
/// doesn't decode, or a request that doesn't encode, breaks the bridge's contract: it's reported,
/// and the caller turns the nil into its own failure.
internal enum ChromiumReply {
	internal static func decode<Value: Decodable>(
		_ type: Value.Type,
		from data: Data
	) -> Value? {
		do {
			return try JSONDecoder().decode(type, from: data)
		} catch {
			reportIssue(error)
			return nil
		}
	}

	internal static func encode(
		_ value: some Encodable,
		with encoder: JSONEncoder = JSONEncoder()
	) -> Data? {
		do {
			return try encoder.encode(value)
		} catch {
			reportIssue(error)
			return nil
		}
	}

	/// The reason a failure reply gives, if it gives one. A failure may come with no body or
	/// with a body that names no reason, so nothing is reported for a missing one.
	internal static func failureReason(from body: Data) -> String? {
		struct Failure: Decodable {
			var reason: String?
		}

		// Optional detail: the status alone already says what failed.
		return (try? JSONDecoder().decode(Failure.self, from: body))?.reason
	}
}
