import AppKit
import ChromiumEngine

internal enum ReferenceClickSmokeContract {
	internal static let buttonName: String = "Arx reference click"
	internal static let navigationName: String = "Arx reference navigation"
	internal static let readyTitle: String = "Arx reference ready"
	internal static let clickedTitle: String = "Arx reference count=1 trusted=true activation=false"

	internal static func reference(
		in snapshot: ChromiumInspectionSnapshot,
		named name: String,
		role: String = "button"
	) throws -> String {
		let matches = snapshot.nodes.filter { $0.role == role && $0.name == name }
		guard
			matches.count == 1,
			let reference = matches.first?.reference
		else { throw Failure.missingReference }
		return reference
	}

	internal static func require(
		_ result: ChromiumReferenceClickResult,
		disposition: ChromiumReferenceClickDisposition,
		failure: ChromiumReferenceClickFailure? = nil
	) throws {
		guard
			result.disposition == disposition,
			result.failure == failure
		else { throw Failure.unexpectedReceipt }
	}

	internal static func requireNavigationReceipt(_ result: ChromiumReferenceClickResult) throws {
		let confirmed = result.disposition == .dispatched && result.failure == nil
		let navigatedBeforeReply = result.disposition == .possiblyDispatched
		&& result.failure == .staleReference

		guard confirmed || navigatedBeforeReply
		else { throw Failure.unexpectedReceipt }
	}

	internal static func inputPoint(
		currentURL: URL?,
		expectedURL: URL,
		bounds: CGRect,
		isFlipped: Bool,
		reinsert: Bool
	) throws -> CGPoint {
		guard
			currentURL == expectedURL,
			expectedURL.scheme == "http",
			expectedURL.host == "127.0.0.1",
			let port = expectedURL.port,
			(1...65_535).contains(port),
			expectedURL.user == nil,
			expectedURL.password == nil,
			expectedURL.query == nil,
			expectedURL.fragment == nil,
			expectedURL.path == "/reference-click/main",
			bounds.origin == .zero,
			bounds.width.isFinite,
			bounds.height.isFinite,
			bounds.width >= 400,
			bounds.height >= 100
		else { throw Failure.invalidFixture }
		return .init(x: reinsert ? 280 : 96, y: isFlipped ? 34 : bounds.height - 34)
	}

	internal enum Failure: Error, Equatable {
		case invalidFixture
		case missingReference
		case unexpectedReceipt
		case changedWindow
		case timeout
		case unavailable
	}
}
