import BrowserCore
import Foundation
import _MCP

extension AutomationTools {
	/// `browser_click` arguments that switch it from accessibility activation to real pointer input.
	internal static let pointerClickKeys: Set<String> = ["x", "y", "clickCount", "modifiers"]

	internal static var hoverDefinition: Tool {
		.init(
			name: "browser_hover",
			title: "Hover over an approved page reference or point",
			description: """
			Moves the mouse pointer over the visible centre of a reference, or over a point (x, y) in viewport points \
			of the main frame (the space of inspect bounds and screenshots); a point replaces the reference. \
			This is real mouse input through the page's own widget: :hover styles, mouseover and pointer events run, \
			and website handlers may change state. The point must hit the reference (or, for a point, the snapshot's \
			document), otherwise the result is obscured; Arx doesn't scroll first. \
			Hover doesn't consume its snapshot: while the page's DOM is unchanged, its references stay valid for the \
			next action. A hover that mutates the DOM (a menu that opens) retires them; inspect again. \
			Uses this connection's latest released browser_inspect snapshot, explicit tab/revision and a unique operationID. \
			Requires read, page-content and page-interaction grants plus mutation approval. \
			Dispatched describes event delivery, not website success; possiblyDispatched preserves uncertainty. Never replay.
			""",
			inputSchema: schema(
				properties: targetProperties.merging(pointProperties) { $1 },
				required: ["operationID", "targetID", "expectedRevision", "snapshotID"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	internal static var dragDefinition: Tool {
		.init(
			name: "browser_drag",
			title: "Drag between approved page references or points",
			description: """
			Presses the left mouse button on a reference (or a point x, y), moves in steps (1 to 32, default 8) and \
			releases on a destination reference (toReference) or point (toX, toY). Points are viewport points of the \
			main frame. Pointer-driven sliders and sortable lists see real mouse events; HTML drag and drop \
			(dragstart, dragover, drop, dragend) completes inside the page and never starts a macOS drag session. \
			Both ends must hit their reference (or the snapshot's document) when the drag starts, otherwise the result \
			is obscured. Modifiers: shift, option, command. Real input gives the page user activation. \
			Consumes the snapshot. Uses this connection's latest released browser_inspect snapshot, explicit \
			tab/revision and a unique operationID. Requires read, page-content and page-interaction grants plus \
			mutation approval. Dispatched describes event delivery, not website success; possiblyDispatched preserves \
			uncertainty. Never replay.
			""",
			inputSchema: schema(
				properties: targetProperties
					.merging(pointProperties) { $1 }
					.merging([
						"toReference": string(maximum: 128),
						"toX": coordinate,
						"toY": coordinate,
						"steps": integerSchema(1...32, default: 8),
						"modifiers": modifiersSchema,
					]) { $1 },
				required: ["operationID", "targetID", "expectedRevision", "snapshotID"]
			),
			annotations: .init(
				readOnlyHint: false,
				destructiveHint: true,
				idempotentHint: false,
				openWorldHint: true
			)
		)
	}

	/// Click properties for real pointer input; see `browser_click`.
	internal static var pointerClickProperties: [String: Value] {
		pointProperties.merging([
			"clickCount": integerSchema(1...3, default: 1),
			"modifiers": modifiersSchema,
		]) { $1 }
	}

	internal static func pointerOperation(
		name: String,
		arguments: [String: Value]
	) throws -> AutomationOperation {
		let kind: AutomationFormRequest.Kind
		var allowed: Set<String> = ["operationID", "targetID", "expectedRevision", "snapshotID", "reference", "x", "y"]
		switch name {
		case "browser_hover":
			kind = .hover

		case "browser_drag":
			kind = .drag
			allowed.formUnion(["toReference", "toX", "toY", "steps", "modifiers"])

		case "browser_click":
			kind = .pointerClick
			allowed.formUnion(["clickCount", "modifiers"])

		default:
			throw AutomationFailure.invalidRequest
		}
		guard
			Set(arguments.keys).isSubset(of: allowed),
			let operationID = try optionalString("operationID", in: arguments, maximum: 36).flatMap(UUID.init(uuidString:)),
			let targetID = try optionalString("targetID", in: arguments, maximum: 36).flatMap(UUID.init(uuidString:)),
			let revision = try optionalString("expectedRevision", in: arguments, maximum: 64),
			let snapshotID = try optionalString("snapshotID", in: arguments, maximum: 128)
		else { throw AutomationFailure.invalidRequest }

		let point = try point(x: "x", y: "y", in: arguments)
		let reference = try optionalString("reference", in: arguments, maximum: 128)

		// Exactly one of a reference and a point; a point uses the snapshot's own ID.
		guard (reference == nil) != (point == nil) else { throw AutomationFailure.invalidRequest }

		let pointer = AutomationPointer(
			point: point,
			destinationReference: try optionalString("toReference", in: arguments, maximum: 128),
			destinationPoint: try self.point(x: "toX", y: "toY", in: arguments),
			clickCount: try integer("clickCount", in: arguments, default: 1),
			modifiers: try modifiers(arguments["modifiers"]),
			steps: try integer("steps", in: arguments, default: kind == .drag ? 8 : 1)
		)
		let request = AutomationFormRequest(
			target: .init(
				operationID: operationID,
				targetID: targetID,
				expectedRevision: revision,
				snapshotID: snapshotID,
				reference: reference ?? snapshotID
			),
			kind: kind,
			value: "",
			pointer: pointer
		)
		try request.validate()
		return .form(request)
	}

	private static var targetProperties: [String: Value] {
		[
			"operationID": string(maximum: 36),
			"targetID": string(maximum: 36),
			"expectedRevision": string(maximum: 64),
			"snapshotID": string(maximum: 128),
			"reference": string(maximum: 128),
		]
	}

	private static var pointProperties: [String: Value] {
		["x": coordinate, "y": coordinate]
	}

	private static var coordinate: Value {
		.object([
			"type": .string("number"),
			"minimum": .int(0),
			"maximum": .int(100_000),
		])
	}

	private static var modifiersSchema: Value {
		.object([
			"type": .string("array"),
			"items": .object([
				"type": .string("string"),
				"enum": .array(AutomationPointer.Modifier.allCases.map { .string($0.rawValue) }),
			]),
			"maxItems": .int(3),
			"uniqueItems": .bool(true),
		])
	}

	private static func point(
		x: String,
		y: String,
		in arguments: [String: Value]
	) throws -> AutomationPointer.Point? {
		switch (arguments[x], arguments[y]) {
		case (nil, nil):
			return nil

		case let (first?, second?):
			guard
				let first = number(first),
				let second = number(second)
			else { throw AutomationFailure.invalidRequest }
			return .init(x: first, y: second)

		default:
			throw AutomationFailure.invalidRequest
		}
	}

	private static func modifiers(_ value: Value?) throws -> [AutomationPointer.Modifier] {
		guard let value else { return [] }
		guard let items = value.arrayValue, items.count <= 3
		else { throw AutomationFailure.invalidRequest }
		return try items.map { item in
			guard let modifier = item.stringValue.flatMap(AutomationPointer.Modifier.init(rawValue:))
			else { throw AutomationFailure.invalidRequest }
			return modifier
		}
	}
}
