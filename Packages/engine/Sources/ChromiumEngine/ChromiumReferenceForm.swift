import Foundation

/// Native explicit form replacement/selection or guarded keypress; no paste, IME or autofill.
/// Payloads are never echoed in results or retained in operation receipts.
public enum ChromiumReferenceFormAction: Equatable, Sendable {
	case replaceText(String)
	case selectValue(String)
	case keyPress(String)

	/// ABI27 real mouse input through the frame's own widget.
	case pointer(ChromiumPointerAction)

	/// ABI28: focuses an input, textarea or contenteditable reference and types
	/// each character at the end as a guarded key sequence. 1...1024 UTF-8 bytes;
	/// LF is Enter and is refused for single-line inputs.
	case typeText(String)

	/// ABI28: focuses the reference and presses one key with modifiers.
	case keyChord(String, modifiers: ChromiumKeyModifiers)

	/// ABI29: the exact whole selection of a native multiple select, by option
	/// values (at most 64, each matching one enabled option).
	case selectValues([String])

	/// ABI29: a checkbox or radio's explicit state. A radio can't be unchecked.
	case setChecked(Bool)
}

/// Control, Option and Command chords reach page listeners only; no default runs.
public struct ChromiumKeyModifiers: OptionSet, Equatable, Sendable {
	public let rawValue: UInt32

	public init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	public static let shift: Self = .init(rawValue: 1 << 0)
	public static let control: Self = .init(rawValue: 1 << 1)
	public static let option: Self = .init(rawValue: 1 << 2)
	public static let command: Self = .init(rawValue: 1 << 3)
}

extension ChromiumKeyModifiers {
	/// Key names the chord accepts besides a single character.
	public static let namedKeys: Set<String> = [
		"Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
		"Home", "End", "PageUp", "PageDown", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
		"F11", "F12",
	]
}

/// A point in the main frame widget's viewport, in points: the space of
/// inspection bounds and screenshots.
public struct ChromiumPointerPoint: Equatable, Sendable {
	public var x: Double
	public var y: Double

	public init(x: Double, y: Double) {
		self.x = x
		self.y = y
	}
}

/// Control is absent on purpose: on macOS it turns a click into a context menu.
public struct ChromiumPointerModifiers: OptionSet, Equatable, Sendable {
	public let rawValue: UInt32

	public init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	public static let shift: Self = .init(rawValue: 1 << 0)
	public static let option: Self = .init(rawValue: 1 << 2)
	public static let command: Self = .init(rawValue: 1 << 3)
}

public enum ChromiumPointerDestination: Equatable, Sendable {
	/// A reference of the same snapshot.
	case reference(String)
	case point(ChromiumPointerPoint)
}

/// The request's reference is the target. With a point, the reference must be
/// the snapshot's own ID: the action then addresses the frame's viewport.
/// The point (or the reference's visible centre) must hit the reference, or
/// for a point, the snapshot's document. Hover keeps its snapshot current
/// until the DOM changes; clicks and drags consume it.
public enum ChromiumPointerAction: Equatable, Sendable {
	case hover(at: ChromiumPointerPoint?)
	case click(at: ChromiumPointerPoint?, count: Int, modifiers: ChromiumPointerModifiers)
	case drag(
		from: ChromiumPointerPoint?,
		to: ChromiumPointerDestination,
		steps: Int,
		modifiers: ChromiumPointerModifiers
	)

	public var point: ChromiumPointerPoint? {
		switch self {
		case let .hover(point), let .click(point, _, _), let .drag(point, _, _, _): point
		}
	}

	public var consumesSnapshot: Bool {
		if case .hover = self { return false }
		return true
	}
}

/// The target is an explicit reference from the latest permitted snapshot.
/// The trusted scope and page are supplied separately from this request.
public struct ChromiumReferenceFormRequest: Equatable, Sendable {
	public let operationID: UUID
	public let snapshot: ChromiumInspectionSnapshot
	public let reference: String
	public let action: ChromiumReferenceFormAction
	public let timeoutMilliseconds: Int

	public init(
		operationID: UUID,
		snapshot: ChromiumInspectionSnapshot,
		reference: String,
		action: ChromiumReferenceFormAction,
		timeoutMilliseconds: Int = 2_000
	) {
		self.operationID = operationID
		self.snapshot = snapshot
		self.reference = reference
		self.action = action
		self.timeoutMilliseconds = timeoutMilliseconds
	}
}

/// `dispatched` means the native setter/event sequence started. Website handlers
/// may change its value or navigate; it does not promise a final value or success.
/// `unchanged` consumes the operation without mutation or input/change events.
public enum ChromiumReferenceFormDisposition: Equatable, Sendable {
	case notDispatched
	case dispatched
	case possiblyDispatched
	case unchanged
}

public enum ChromiumReferenceFormFailure: Error, Equatable, Sendable {
	case unavailable
	case notReady
	case unsupportedDocument
	case staleReference
	case notInteractable
	case notAuthorized
	case busy
	case limitExceeded
	case duplicateOperation
	case cancelled
	case timedOut
	case invalidResponse
	case unsupportedControl
	case invalidValue
	case optionNotFound
	case ambiguousOption

	/// ABI27: the point hit something other than the reference.
	case obscured
}

/// A click and a form action share the same lifetime replay and physical limits.
/// Cancellation cannot undo a mutation that may already have reached the page.
public struct ChromiumReferenceFormResult: Equatable, Sendable {
	public let operationID: UUID
	public let disposition: ChromiumReferenceFormDisposition
	public let failure: ChromiumReferenceFormFailure?

	public init(
		operationID: UUID,
		disposition: ChromiumReferenceFormDisposition,
		failure: ChromiumReferenceFormFailure? = nil
	) {
		self.operationID = operationID
		self.disposition = disposition
		self.failure = failure
	}
}

extension ChromiumPointerAction {
	/// The ABI27 form action kind.
	internal var kind: UInt32 {
		switch self {
		case .hover: 8
		case .click: 16
		case .drag: 32
		}
	}

	/// Canonical ASCII fields in ABI order, or nil when a value is out of range.
	internal var payload: String? {
		var fields: [(String, String)] = []
		func append(
			_ point: ChromiumPointerPoint?,
			x: String,
			y: String
		) -> Bool {
			guard let point else { return true }
			guard
				let first = Self.number(point.x),
				let second = Self.number(point.y)
			else { return false }
			fields += [(x, first), (y, second)]
			return true
		}

		switch self {
		case let .hover(point):
			guard append(point, x: "x", y: "y") else { return nil }

		case let .click(point, count, modifiers):
			guard
				append(point, x: "x", y: "y"),
				(1...3).contains(count),
				modifiers.isSubset(of: [.shift, .option, .command])
			else { return nil }
			fields += [("clicks", String(count)), ("modifiers", String(modifiers.rawValue))]

		case let .drag(point, destination, steps, modifiers):
			guard append(point, x: "x", y: "y") else { return nil }
			switch destination {
			case let .point(target):
				guard append(target, x: "tx", y: "ty") else { return nil }
			case let .reference(reference):
				fields.append(("to", reference))
			}
			guard
				(1...32).contains(steps),
				modifiers.isSubset(of: [.shift, .option, .command])
			else { return nil }
			fields += [("modifiers", String(modifiers.rawValue)), ("steps", String(steps))]
		}
		return fields.map { "\($0.0)=\($0.1);" }.joined()
	}

	private static func number(_ value: Double) -> String? {
		guard value.isFinite, (0...100_000).contains(value) else { return nil }
		return value == value.rounded() ? String(Int(value)) : String(value)
	}
}
