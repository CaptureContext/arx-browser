import BrowserCore
import Foundation
import _Dependencies

public struct BrowserPageInteractionClient: Sendable {
	public typealias Click = @MainActor @Sendable (
		AutomationClickRequest,
		AutomationInspectionResult,
		@escaping @MainActor @Sendable () -> Bool
	) async -> AutomationClickResult

	public typealias Form = @MainActor @Sendable (
		AutomationFormRequest,
		AutomationInspectionResult,
		@escaping @MainActor @Sendable () -> Bool
	) async -> AutomationFormResult

	public typealias Scroll = @MainActor @Sendable (
		AutomationScrollRequest,
		AutomationInspectionResult,
		@escaping @MainActor @Sendable () -> Bool
	) async -> AutomationScrollResult

	public var scrollIsAvailable: @MainActor @Sendable () -> Bool
	public var scrollAuthorized: Scroll
	public var keypressIsAvailable: @MainActor @Sendable () -> Bool
	public var formIsAvailable: @MainActor @Sendable () -> Bool
	public var formAuthorized: Form
	public var isAvailable: @MainActor @Sendable () -> Bool

	/// The callback must run immediately before native submission, without suspension.
	/// A successful callback marks uncertainty until the native result resolves it.
	public var clickAuthorized: Click

	public init(
		isAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		clickAuthorized: @escaping Click = { request, _, _ in
			.init(
				operationID: request.operationID,
				disposition: .notDispatched,
				failure: .unsupported
			)
		},
		keypressIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		formIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		formAuthorized: @escaping Form = { request, _, _ in
			.init(
				operationID: request.operationID,
				disposition: .notDispatched,
				failure: .unsupported
			)
		},
		scrollIsAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		scrollAuthorized: @escaping Scroll = { request, _, _ in
			.init(
				operationID: request.operationID,
				disposition: .notDispatched,
				failure: .unsupported
			)
		}
	) {
		self.scrollIsAvailable = scrollIsAvailable
		self.scrollAuthorized = scrollAuthorized
		self.keypressIsAvailable = keypressIsAvailable
		self.formIsAvailable = formIsAvailable
		self.formAuthorized = formAuthorized
		self.isAvailable = isAvailable
		self.clickAuthorized = clickAuthorized
	}
}

extension BrowserPageInteractionClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserPageInteraction: BrowserPageInteractionClient {
		get { self[BrowserPageInteractionClient.self] }
		set { self[BrowserPageInteractionClient.self] = newValue }
	}
}
