import BrowserCore
import Foundation
import _Dependencies

/// The host checks the live originating placement and native revision. Denied by default.
public struct PageCaptureAuthorizationClient: Sendable {
	public var authorize: @MainActor @Sendable (UUID, PageCaptureRequest) -> Bool

	public init(
		authorize: @escaping @MainActor @Sendable (UUID, PageCaptureRequest) -> Bool = { _, _ in false }
	) {
		self.authorize = authorize
	}
}

extension PageCaptureAuthorizationClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init(authorize: { _, _ in true }) }
}

extension DependencyValues {
	public var pageCaptureAuthorization: PageCaptureAuthorizationClient {
		get { self[PageCaptureAuthorizationClient.self] }
		set { self[PageCaptureAuthorizationClient.self] = newValue }
	}
}
