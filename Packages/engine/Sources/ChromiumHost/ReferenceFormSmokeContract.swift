import AppKit
import ChromiumEngine

internal enum ReferenceFormSmokeContract {
	internal static func reference(
		in snapshot: ChromiumInspectionSnapshot,
		target: String
	) throws -> String {
		let matches = snapshot.nodes.filter { $0.name == "Arx form \(target)" }
		guard
			matches.count == 1,
			let reference = matches.first?.reference
		else { throw Failure.missingReference }
		return reference
	}

	internal static func require(
		_ result: ChromiumReferenceFormResult,
		disposition: ChromiumReferenceFormDisposition,
		failure: ChromiumReferenceFormFailure? = nil
	) throws {
		guard result.disposition == disposition, result.failure == failure
		else { throw Failure.unexpectedReceipt }
	}

	internal static func events(_ data: Data) throws -> [Event] {
		guard data.count <= 16_384
		else { throw Failure.invalidFixture }
		let envelope = try JSONDecoder().decode(Envelope.self, from: data)
		guard
			envelope.events.count <= 32,
			envelope.events.allSatisfy({ event in
				["text", "search", "textarea", "select", "mutation"].contains(event.target)
				&& ["input", "change", "mutation"].contains(event.event)
			})
		else { throw Failure.invalidFixture }
		return envelope.events
	}

	internal static func requireEvents(
		_ events: [Event],
		target: String
	) throws {
		guard
			events.count == 2,
			events.map(\.event).sorted() == ["change", "input"],
			events.allSatisfy({ event in
				event.target == target
				&& event.trusted
				&& !event.activation
				&& !event.focused
				&& event.correct
			})
		else { throw Failure.unexpectedEvents }
	}

	internal static func inputPoint(
		currentURL: URL?,
		expectedURL: URL,
		bounds: CGRect,
		isFlipped: Bool
	) throws -> CGPoint {
		let modes = [
			"value",
			"selection",
			"readonly",
			"maxlength",
			"type",
			"selected",
			"option-value",
			"replace",
		]
		let components = URLComponents(url: expectedURL, resolvingAgainstBaseURL: false)
		guard
			currentURL == expectedURL,
			expectedURL.scheme == "http",
			expectedURL.host == "127.0.0.1",
			let port = expectedURL.port,
			(1...65_535).contains(port),
			expectedURL.user == nil,
			expectedURL.password == nil,
			expectedURL.fragment == nil,
			modes.contains(expectedURL.lastPathComponent),
			expectedURL.deletingLastPathComponent().path == "/reference-form",
			components?.queryItems?.count == 1,
			components?.queryItems?.first?.name == "run",
			let run = components?.queryItems?.first?.value,
			UUID(uuidString: run)?.uuidString.lowercased() == run,
			bounds.origin == .zero,
			bounds.width.isFinite,
			bounds.height.isFinite,
			bounds.width >= 400,
			bounds.height >= 100
		else { throw Failure.invalidFixture }
		return .init(x: 96, y: isFlipped ? 34 : bounds.height - 34)
	}

	internal struct Event: Decodable, Equatable {
		internal let target: String
		internal let event: String
		internal let trusted: Bool
		internal let activation: Bool
		internal let focused: Bool
		internal let correct: Bool

		internal init(
			target: String,
			event: String,
			trusted: Bool,
			activation: Bool,
			focused: Bool,
			correct: Bool
		) {
			self.target = target
			self.event = event
			self.trusted = trusted
			self.activation = activation
			self.focused = focused
			self.correct = correct
		}
	}

	private struct Envelope: Decodable {
		internal let events: [Event]

		internal init(events: [Event]) {
			self.events = events
		}
	}

	internal enum Failure: Error, Equatable {
		case invalidFixture
		case missingReference
		case unexpectedReceipt
		case unexpectedEvents
		case changedWindow
		case changedDOM
		case timeout
		case unavailable
	}
}
