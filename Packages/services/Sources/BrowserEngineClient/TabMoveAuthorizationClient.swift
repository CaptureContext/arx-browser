import BrowserCore
import Foundation
import _Dependencies

/// The host denies transfer when source sessions are borrowed, shared, closing, or private.
public struct TabMoveAuthorizationClient: Sendable {
	public var check: @MainActor @Sendable (UUID, [Tab.ID]) -> Bool

	public init(
		check: @escaping @MainActor @Sendable (UUID, [Tab.ID]) -> Bool = { _, _ in false }
	) {
		self.check = check
	}
}

extension TabMoveAuthorizationClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init(check: { _, _ in true }) }
}

extension DependencyValues {
	public var tabMoveAuthorization: TabMoveAuthorizationClient {
		get { self[TabMoveAuthorizationClient.self] }
		set { self[TabMoveAuthorizationClient.self] = newValue }
	}
}
