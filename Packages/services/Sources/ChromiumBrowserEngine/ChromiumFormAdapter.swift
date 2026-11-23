import BrowserCore
import BrowserPageInteractionClient
import ChromiumEngine
import Foundation

internal enum ChromiumFormAdapter {
	@MainActor
	internal static func action(
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		keypressIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		sourceIsCurrent: @escaping @MainActor @Sendable (PageInspectionSource) -> Bool,
		perform: @escaping @MainActor @Sendable (
			ChromiumReferenceFormRequest,
			PageInspectionSource,
			@escaping @MainActor @Sendable () -> Bool
		) async -> ChromiumReferenceFormResult,
		upload: @escaping @MainActor @Sendable (
			AutomationFormRequest,
			PageInspectionSource,
			@escaping @MainActor @Sendable () -> Bool
		) async -> AutomationFormResult = { request, _, _ in
			.init(operationID: request.operationID, disposition: .notDispatched, failure: .unsupported)
		}
	) -> BrowserPageInteractionClient.Form {
		{ request, inspection, authorize in
			func rejected(_ failure: AutomationFailure) -> AutomationFormResult {
				.init(
					operationID: request.operationID,
					disposition: .notDispatched,
					failure: failure
				)
			}

			do {
				try request.validate()
				try inspection.validate()
			} catch {
				return rejected(error as? AutomationFailure ?? .invalidRequest)
			}

			guard !Task.isCancelled else { return rejected(.cancelled) }
			guard isAvailable(), request.kind != .keyPress || keypressIsAvailable()
			else { return rejected(.unsupported) }
			guard
				request.target.targetID == inspection.request.targetID,
				request.target.snapshotID == inspection.snapshot.snapshotID,
				request.targetsViewport
					|| inspection.snapshot.nodes.contains(where: { $0.reference == request.target.reference }),
				request.pointer?.destinationReference.map({ destination in
					inspection.snapshot.nodes.contains(where: { $0.reference == destination })
				}) ?? true,
				sourceIsCurrent(inspection.source)
			else { return rejected(.staleReference) }

			if request.kind == .upload {
				return await upload(request, inspection.source) {
					isAvailable() && sourceIsCurrent(inspection.source) && authorize()
				}
			}
			guard let action = action(request) else { return rejected(.invalidValue) }
			let result = await perform(
				.init(
					operationID: request.operationID,
					snapshot: .init(inspection.snapshot),
					reference: request.target.reference,
					action: action
				),
				inspection.source
			) {
				isAvailable()
				&& (request.kind != .keyPress || keypressIsAvailable())
				&& sourceIsCurrent(inspection.source)
				&& authorize()
			}
			guard result.operationID == request.operationID else {
				return .init(
					operationID: request.operationID,
					disposition: .possiblyDispatched,
					failure: .engineFailed
				)
			}
			return .init(
				operationID: result.operationID,
				disposition: disposition(result.disposition),
				failure: result.failure.map(failure)
			)
		}
	}

	private static func action(_ request: AutomationFormRequest) -> ChromiumReferenceFormAction? {
		switch request.kind {
		case .replaceText:
			return .replaceText(request.value)

		case .selectValue:
			return .selectValue(request.value)

		case .keyPress:
			return .keyPress(request.value)

		case .typeText:
			return .typeText(request.value)

		case .keyChord:
			return .keyChord(request.value, modifiers: keyModifiers(request.keyModifiers ?? []))

		case .selectValues:
			return request.values.map(ChromiumReferenceFormAction.selectValues)

		case .setChecked:
			return request.checked.map(ChromiumReferenceFormAction.setChecked)

		case .upload:
			return nil

		case .hover, .pointerClick, .drag:
			guard let pointer = request.pointer else { return nil }
			return .pointer(pointerAction(request.kind, pointer))
		}
	}

	private static func keyModifiers(_ modifiers: [AutomationFormRequest.KeyModifier]) -> ChromiumKeyModifiers {
		modifiers.reduce(into: ChromiumKeyModifiers()) { result, modifier in
			switch modifier {
			case .shift: result.insert(.shift)
			case .control: result.insert(.control)
			case .option: result.insert(.option)
			case .command: result.insert(.command)
			}
		}
	}

	private static func pointerAction(
		_ kind: AutomationFormRequest.Kind,
		_ pointer: AutomationPointer
	) -> ChromiumPointerAction {
		let point = pointer.point.map { ChromiumPointerPoint(x: $0.x, y: $0.y) }
		let modifiers = pointer.modifiers.reduce(into: ChromiumPointerModifiers()) { result, modifier in
			switch modifier {
			case .shift: result.insert(.shift)
			case .option: result.insert(.option)
			case .command: result.insert(.command)
			}
		}
		switch kind {
		case .pointerClick:
			return .click(at: point, count: pointer.clickCount, modifiers: modifiers)

		case .drag:
			let destination: ChromiumPointerDestination = if let reference = pointer.destinationReference {
				.reference(reference)
			} else {
				.point(.init(x: pointer.destinationPoint?.x ?? 0, y: pointer.destinationPoint?.y ?? 0))
			}
			return .drag(from: point, to: destination, steps: pointer.steps, modifiers: modifiers)

		case .hover, .replaceText, .selectValue, .keyPress, .typeText, .keyChord, .selectValues, .setChecked, .upload:
			return .hover(at: point)
		}
	}

	private static func disposition(
		_ value: ChromiumReferenceFormDisposition
	) -> AutomationFormDisposition {
		switch value {
		case .notDispatched: .notDispatched
		case .dispatched: .dispatched
		case .possiblyDispatched: .possiblyDispatched
		case .unchanged: .unchanged
		}
	}

	private static func failure(_ value: ChromiumReferenceFormFailure) -> AutomationFailure {
		switch value {
		case .unavailable, .unsupportedDocument: .unsupported
		case .notReady: .notReady
		case .staleReference: .staleReference
		case .notInteractable: .notInteractable
		case .notAuthorized: .denied
		case .busy: .busy
		case .limitExceeded: .limitExceeded
		case .duplicateOperation: .duplicateOperation
		case .cancelled: .cancelled
		case .timedOut: .timedOut
		case .invalidResponse: .engineFailed
		case .unsupportedControl: .unsupportedControl
		case .invalidValue: .invalidValue
		case .optionNotFound: .optionNotFound
		case .ambiguousOption: .ambiguousOption
		case .obscured: .obscured
		}
	}
}
