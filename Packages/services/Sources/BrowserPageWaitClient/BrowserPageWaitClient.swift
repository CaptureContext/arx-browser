import BrowserCore
import Foundation
import _Dependencies

public struct BrowserPageWaitClient: Sendable {
	public typealias Wait = @MainActor @Sendable (
		AutomationWaitRequest,
		PageWaitTarget,
		@escaping @MainActor @Sendable () -> Bool
	) async throws -> PageWaitObservation

	public var isAvailable: @MainActor @Sendable () -> Bool
	public var waitAuthorized: Wait

	/// Revalidates the original native owner and published/live epoch at response release.
	public var sourceIsCurrent: @MainActor @Sendable (PageWaitSource) -> Bool

	public init(
		isAvailable: @escaping @MainActor @Sendable () -> Bool = { false },
		waitAuthorized: @escaping Wait = { _, _, _ in throw AutomationFailure.unsupported },
		sourceIsCurrent: @escaping @MainActor @Sendable (PageWaitSource) -> Bool = { _ in false }
	) {
		self.isAvailable = isAvailable
		self.waitAuthorized = waitAuthorized
		self.sourceIsCurrent = sourceIsCurrent
	}
}

extension BrowserPageWaitClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserPageWait: BrowserPageWaitClient {
		get { self[BrowserPageWaitClient.self] }
		set { self[BrowserPageWaitClient.self] = newValue }
	}
}
