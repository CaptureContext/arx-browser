import BrowserCore
import Foundation
import _Dependencies

public struct BrowserPageInspectionClient: Sendable {
	public typealias Inspect = @MainActor @Sendable (
		AutomationInspectionRequest,
		PageInspectionSource,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> PageInspectionSnapshot

	public var isAvailable: @MainActor @Sendable () -> Bool
	public var inspectAuthorized: Inspect

	/// Checks native page/document/scope liveness, not whether the renderer DOM has changed.
	public var documentIsCurrent: @MainActor @Sendable (AutomationInspectionResult) -> Bool
	public var revokeScope: @MainActor @Sendable (UUID) -> Void

	public init(
		isAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		inspectAuthorized: @escaping Inspect = { _, _, _ in throw AutomationFailure.unsupported },
		documentIsCurrent: @escaping @MainActor @Sendable (AutomationInspectionResult) -> Bool = { _ in false },
		revokeScope: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
	) {
		self.isAvailable = isAvailable
		self.inspectAuthorized = inspectAuthorized
		self.documentIsCurrent = documentIsCurrent
		self.revokeScope = revokeScope
	}
}

extension BrowserPageInspectionClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserPageInspection: BrowserPageInspectionClient {
		get { self[BrowserPageInspectionClient.self] }
		set { self[BrowserPageInspectionClient.self] = newValue }
	}

	/// Node bounds for on-page capture, owned by the live capture session rather than an
	/// automation grant. Unavailable unless the host installs it.
	public var pageCaptureInspection: BrowserPageInspectionClient {
		get { self[PageCaptureInspectionKey.self] }
		set { self[PageCaptureInspectionKey.self] = newValue }
	}
}

private enum PageCaptureInspectionKey: DependencyKey {
	internal static var liveValue: BrowserPageInspectionClient { .init() }
	internal static var testValue: BrowserPageInspectionClient { .init() }
	internal static var previewValue: BrowserPageInspectionClient { .init() }
}
