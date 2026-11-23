import Foundation

/// An explicit bounded form action, guarded keypress or pointer action. No implicit focused target.
public struct AutomationFormRequest: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Sendable {
		case replaceText
		case selectValue
		case keyPress

		/// Real mouse input. Hover keeps its snapshot current until the DOM changes.
		case hover
		case pointerClick
		case drag

		/// Arx focuses the field and types each character at the end.
		case typeText

		/// Arx focuses the reference and presses one key with `keyModifiers`.
		case keyChord

		/// The exact whole selection of a native multiple select, from `values`.
		case selectValues

		/// A checkbox or radio's explicit state, from `checked`.
		case setChecked

		/// Answers the file chooser the page holds with the absolute paths in
		/// `values`, or cancels it with none. The reference names the file input.
		case upload

		public var isPointer: Bool {
			switch self {
			case .hover, .pointerClick, .drag: true
			case .replaceText, .selectValue, .keyPress, .typeText, .keyChord, .selectValues, .setChecked, .upload:
				false
			}
		}
	}

	/// Control is allowed here: chords with it reach page listeners only.
	public enum KeyModifier: String, Codable, CaseIterable, Sendable {
		case shift
		case control
		case option
		case command
	}

	/// Key names a chord accepts besides one printable character.
	public static let chordKeys: Set<String> = [
		"Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
		"Home", "End", "PageUp", "PageDown", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
		"F11", "F12",
	]

	public var target: AutomationClickRequest
	public var kind: Kind

	/// Retained only while the bounded operation is pending; never echoed in a receipt.
	/// Empty for pointer kinds.
	public var value: String

	/// Present exactly for pointer kinds.
	public var pointer: AutomationPointer?

	/// Key chords only.
	public var keyModifiers: [KeyModifier]?

	/// `selectValues` only; never echoed in a receipt.
	public var values: [String]?

	/// `setChecked` only.
	public var checked: Bool?

	public init(
		target: AutomationClickRequest,
		kind: Kind,
		value: String,
		pointer: AutomationPointer? = nil,
		keyModifiers: [KeyModifier]? = nil,
		values: [String]? = nil,
		checked: Bool? = nil
	) {
		self.target = target
		self.kind = kind
		self.value = value
		self.pointer = pointer
		self.keyModifiers = keyModifiers
		self.values = values
		self.checked = checked
	}

	public var operationID: UUID { target.operationID }

	/// A pointer point addresses the frame's viewport through the snapshot's own ID.
	public var targetsViewport: Bool {
		kind.isPointer && pointer?.point != nil && target.reference == target.snapshotID
	}

	public func validate() throws {
		try target.validate()
		if kind.isPointer {
			guard
				value.isEmpty,
				let pointer,
				(pointer.point != nil) == (target.reference == target.snapshotID),
				pointer.isValid(for: kind)
			else { throw AutomationFailure.invalidValue }
			return
		}
		guard
			pointer == nil,
			(kind == .keyChord) == (keyModifiers != nil),
			(kind == .selectValues || kind == .upload) == (values != nil),
			(kind == .setChecked) == (checked != nil)
		else { throw AutomationFailure.invalidValue }

		if kind == .upload, let values {
			guard
				value.isEmpty,
				values.count <= 32,
				Set(values).count == values.count,
				values.allSatisfy(Self.isUploadPath)
			else { throw AutomationFailure.invalidValue }
			return
		}
		if let values {
			let bytes = values.reduce(0) { $0 + $1.utf8.count + 3 }
			guard
				value.isEmpty,
				values.count <= 64,
				Set(values).count == values.count,
				bytes <= 4_000,
				!values.contains(where: { $0.utf8.contains(0) })
			else { throw AutomationFailure.invalidValue }
			return
		}
		if checked != nil {
			guard value.isEmpty else { throw AutomationFailure.invalidValue }
			return
		}

		if kind == .typeText {
			guard
				!value.isEmpty,
				value.utf8.prefix(1_025).count <= 1_024,
				value.unicodeScalars.allSatisfy({ $0 == "\n" || Self.isPrintable($0) })
			else { throw AutomationFailure.invalidValue }
			return
		}
		if kind == .keyChord {
			guard
				let keyModifiers,
				Set(keyModifiers).count == keyModifiers.count,
				Self.chordKeys.contains(value) || (value.unicodeScalars.count == 1 && value.unicodeScalars.allSatisfy(Self.isPrintable))
			else { throw AutomationFailure.invalidValue }
			return
		}
		let maximum: Int = switch kind {
		case .replaceText: 32_768
		case .selectValue: 4_096
		case .keyPress: 32
		case .hover, .pointerClick, .drag, .typeText, .keyChord, .selectValues, .setChecked, .upload: 0
		}
		guard
			value.utf8.prefix(maximum + 1).count <= maximum,
			!value.utf8.contains(0),
			kind != .replaceText || !value.utf8.contains(13),
			kind != .keyPress || Self.isSupportedKeypress(value)
		else { throw AutomationFailure.invalidValue }
	}

	/// An absolute path without parent references or NUL, at most 4096 bytes.
	public static func isUploadPath(_ path: String) -> Bool {
		path.hasPrefix("/")
		&& path.utf8.count <= 4_096
		&& !path.utf8.contains(0)
		&& !path.split(separator: "/").contains("..")
	}

	public static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
		let value = scalar.value
		return value >= 0x20
		&& !(0x7F...0x9F).contains(value)
		&& value != 0x2028
		&& value != 0x2029
		&& value & 0xFFFF < 0xFFFE
	}

	public static func isSupportedKeypress(_ value: String) -> Bool {
		guard value.utf8.prefix(33).count <= 32 else { return false }
		let named: Set<String> = [
			"Backspace", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Home", "End", "Enter",
		]
		if named.contains(value) { return true }
		guard
			value.unicodeScalars.count == 1,
			let scalar = value.unicodeScalars.first?.value
		else { return false }
		return scalar >= 0x20
		&& !(0x7F...0x9F).contains(scalar)
		&& scalar != 0x2028
		&& scalar != 0x2029
		&& scalar & 0xFFFF < 0xFFFE
	}
}

public enum AutomationFormDisposition: String, Codable, Equatable, Sendable {
	case notDispatched
	case dispatched
	case possiblyDispatched

	/// The validated value was already equal. No setter or events ran; the ID is consumed.
	case unchanged
}

/// A bounded acknowledgment with no supplied or current page values.
public struct AutomationFormResult: Codable, Equatable, Sendable {
	public var operationID: UUID
	public var disposition: AutomationFormDisposition
	public var failure: AutomationFailure?

	public init(
		operationID: UUID,
		disposition: AutomationFormDisposition,
		failure: AutomationFailure? = nil
	) {
		self.operationID = operationID
		self.disposition = disposition
		self.failure = failure
	}
}

/// Pointer input in the main frame widget's viewport points: the space of
/// inspection bounds and screenshots. Without a point the target reference's
/// visible centre is used.
public struct AutomationPointer: Codable, Equatable, Sendable {
	public struct Point: Codable, Equatable, Sendable {
		public var x: Double
		public var y: Double

		public init(x: Double, y: Double) {
			self.x = x
			self.y = y
		}

		public var isValid: Bool {
			x.isFinite && y.isFinite && (0...100_000).contains(x) && (0...100_000).contains(y)
		}
	}

	/// Control is not offered: on macOS it turns a click into a context menu.
	public enum Modifier: String, Codable, CaseIterable, Sendable {
		case shift
		case option
		case command
	}

	public var point: Point?

	/// Drag only: exactly one of these.
	public var destinationReference: String?
	public var destinationPoint: Point?

	/// Click only, 1...3.
	public var clickCount: Int

	/// Not for hover.
	public var modifiers: [Modifier]

	/// Drag only, 1...32 intermediate moves.
	public var steps: Int

	public init(
		point: Point? = nil,
		destinationReference: String? = nil,
		destinationPoint: Point? = nil,
		clickCount: Int = 1,
		modifiers: [Modifier] = [],
		steps: Int = 1
	) {
		self.point = point
		self.destinationReference = destinationReference
		self.destinationPoint = destinationPoint
		self.clickCount = clickCount
		self.modifiers = modifiers
		self.steps = steps
	}

	public func isValid(for kind: AutomationFormRequest.Kind) -> Bool {
		let drag = kind == .drag
		let destinations = [destinationReference != nil, destinationPoint != nil].filter { $0 }.count
		return point?.isValid ?? true
		&& destinationPoint?.isValid ?? true
		&& destinationReference.map { !$0.isEmpty && $0.utf8.count <= 128 } ?? true
		&& (drag ? destinations == 1 : destinations == 0)
		&& (1...3).contains(clickCount)
		&& (kind == .pointerClick || clickCount == 1)
		&& (1...32).contains(steps)
		&& (drag || steps == 1)
		&& (kind != .hover || modifiers.isEmpty)
		&& Set(modifiers).count == modifiers.count
	}

	/// Canonical fields for the mutation binding.
	public var bindingFields: [String] {
		func number(_ value: Double?) -> String {
			value.map { String($0.bitPattern, radix: 16) } ?? "-"
		}
		return [
			number(point?.x),
			number(point?.y),
			destinationReference ?? "-",
			number(destinationPoint?.x),
			number(destinationPoint?.y),
			String(clickCount),
			modifiers.map(\.rawValue).sorted().joined(separator: ","),
			String(steps),
		]
	}
}
