import ChromiumEngine
import Foundation

internal enum ReferenceScrollSmokeContract {
	internal static func reference(
		in snapshot: ChromiumInspectionSnapshot,
		target: String
	) throws -> String {
		let matches = snapshot.nodes.filter { $0.name == "Arx scroll \(target)" }
		guard
			matches.count == 1,
			let reference = matches.first?.reference
		else { throw Failure.missingReference }
		return reference
	}

	internal static func require(
		_ result: ChromiumReferenceScrollResult,
		disposition: ChromiumReferenceScrollDisposition,
		failure: ChromiumReferenceScrollFailure? = nil
	) throws {
		guard result.disposition == disposition, result.failure == failure
		else { throw Failure.unexpectedReceipt }
	}

	internal static func requireNavigation(_ result: ChromiumReferenceScrollResult) throws {
		let dispatched = result.disposition == .dispatched && result.failure == nil
		let uncertain = result.disposition == .possiblyDispatched && result.failure == .staleReference
		guard dispatched || uncertain
		else { throw Failure.unexpectedReceipt }
	}

	internal static func evidence(_ data: Data) throws -> Evidence {
		guard data.count <= 4_096
		else { throw Failure.invalidFixture }
		let result = try JSONDecoder().decode(Evidence.self, from: data)
		guard
			(1...10_000).contains(result.sample),
			(0...10_000).contains(result.events),
			result.offsets.allSatisfy({ $0.isFinite && abs($0) <= 100_000 })
		else { throw Failure.invalidFixture }
		return result
	}

	internal static func requireSafe(_ evidence: Evidence) throws {
		guard !evidence.focused, !evidence.activation, evidence.trusted
		else { throw Failure.unexpectedEffect }
	}

	internal struct Evidence: Decodable, Equatable {
		internal let innerX: Double
		internal let innerY: Double
		internal let outerX: Double
		internal let outerY: Double
		internal let pageX: Double
		internal let pageY: Double
		internal let sample: Int
		internal let events: Int
		internal let focused: Bool
		internal let activation: Bool
		internal let trusted: Bool
		internal let innerAtEnd: Bool

		internal init(
			innerX: Double,
			innerY: Double,
			outerX: Double,
			outerY: Double,
			pageX: Double,
			pageY: Double,
			sample: Int,
			events: Int,
			focused: Bool,
			activation: Bool,
			trusted: Bool,
			innerAtEnd: Bool
		) {
			self.innerX = innerX
			self.innerY = innerY
			self.outerX = outerX
			self.outerY = outerY
			self.pageX = pageX
			self.pageY = pageY
			self.sample = sample
			self.events = events
			self.focused = focused
			self.activation = activation
			self.trusted = trusted
			self.innerAtEnd = innerAtEnd
		}

		internal var offsets: [Double] {
			[innerX, innerY, outerX, outerY, pageX, pageY]
		}
	}

	internal enum Failure: Error, Equatable {
		case invalidFixture
		case missingReference
		case unexpectedReceipt
		case unexpectedEffect
		case changedWindow
		case timeout
		case unavailable
	}
}
