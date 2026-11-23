import BrowserCore
import Foundation

extension AutomationSecurity {
	/// Canonical, domain-separated, length-prefixed fields. Values are hashed only;
	/// callers retain the digest, never the temporary payload buffer.
	public static func mutationBinding(_ operation: AutomationOperation) -> String? {
		var fields: [String?] = ["Arx automation mutation v1"]
		switch operation {
		case let .command(command):
			fields += [
				"command",
				command.action.rawValue,
				command.operationID.uuidString,
				command.targetID.uuidString,
				command.expectedRevision,
				command.destinationID?.uuidString,
				command.destinationRevision,
				command.url?.absoluteString,
				command.name,
				command.focus ? "true" : "false",
				command.sourceTabID?.uuidString,
				command.sourceRevision,
				command.presentationID?.uuidString,
				command.presentationRevision,
			]

			// Appended only when set, so unrouted bindings keep their v1 digest.
			if command.route { fields.append("route") }

			// Appended only when set, so other commands keep their digest.
			if let theme = command.theme { fields += ["theme", theme] }
			if let appearance = command.appearance { fields += ["appearance", canonical(appearance)] }
			if let splitTabs = command.splitTabs {
				fields += ["splitTabs", String(splitTabs.count)]
				fields += splitTabs.flatMap { [$0.id.uuidString, $0.revision] }
			}
			if let orientation = command.orientation { fields += ["orientation", orientation.rawValue] }
			if let windowID = command.windowID { fields += ["windowID", windowID.uuidString] }

		case let .click(request):
			fields += referenceFields(request, kind: "click", value: nil)

		case let .form(request):
			fields += referenceFields(request.target, kind: request.kind.rawValue, value: request.value)

			// Appended only for pointer kinds, so existing form bindings keep their digest.
			if let pointer = request.pointer { fields += ["pointer"] + pointer.bindingFields }
			if let values = request.values {
				fields += ["values", String(values.count)] + values
			}
			if let checked = request.checked { fields += ["checked", checked ? "true" : "false"] }
			if let modifiers = request.keyModifiers {
				fields += ["modifiers", modifiers.map(\.rawValue).sorted().joined(separator: ",")]
			}

		case let .scroll(request):
			fields += referenceFields(request.target, kind: "scroll", value: nil)
			fields += [request.axis.rawValue, String(request.canonicalDelta.bitPattern, radix: 16)]

		case let .media(request):
			guard let operationID = request.operationID else { return nil }
			fields += [
				"media",
				request.action.rawValue,
				operationID.uuidString,
				request.targetID?.uuidString,
				request.expectedRevision,
				request.token,
			]

			// Appended only for a seek, so other controls keep their digest.
			if let seconds = request.seconds { fields.append(String((seconds + 0).bitPattern, radix: 16)) }

		case let .dialog(request):
			guard let operationID = request.operationID else { return nil }
			fields += [
				"dialog",
				request.action.rawValue,
				operationID.uuidString,
				request.targetID.uuidString,
				request.expectedRevision,
				request.token,
				request.text,
			]

		case let .settings(request):
			guard let change = request.change else { return nil }
			fields += [
				"settings",
				change.edit.name,
				change.operationID.uuidString,
				change.expectedRevision,
				canonical(change.edit),
			]

		case let .script(request):
			// The approval covers this exact script and its bounds.
			fields += [
				"script",
				request.operationID.uuidString,
				request.targetID.uuidString,
				request.expectedRevision,
				request.script,
				String(request.maximumResultBytes),
				String(request.timeoutMilliseconds),
			]

		case let .passwordSignIn(request):
			fields += [
				"passwordSignIn",
				request.operationID.uuidString,
				request.targetID.uuidString,
				request.expectedRevision,
				request.origin,
				request.frameID,
			]

		case .inventory, .capture, .inspect, .wait, .signIn, .batch, .data, .link, .load, .pdf, .findInPage, .logs:
			return nil
		}

		var bytes = Data()
		for field in fields {
			let encoded = field.map { Data($0.utf8) }
			var length = encoded.map { UInt64($0.count) } ?? UInt64.max
			length = length.bigEndian
			withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
			if let encoded { bytes.append(encoded) }
		}
		return digest(bytes)
	}

	/// Sorted-key JSON, so equal values always bind the same.
	private static func canonical(_ value: some Encodable) -> String? {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
	}

	private static func referenceFields(
		_ request: AutomationClickRequest,
		kind: String,
		value: String?
	) -> [String?] {
		[
			kind,
			request.operationID.uuidString,
			request.targetID.uuidString,
			request.expectedRevision,
			request.snapshotID,
			request.reference,
			value,
		]
	}
}
