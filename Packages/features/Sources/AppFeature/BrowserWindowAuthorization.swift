import BrowserCore
import Foundation

@MainActor
internal final class AutomationAuthorization {
	internal var check: (UUID) -> Bool = { _ in false }
}

@MainActor
internal final class QuitAuthorizationContext {
	internal var check: @MainActor @Sendable ([BrowserCore.Tab.ID]) -> Bool = { _ in false }
}

@MainActor
internal final class CaptureAuthorizationContext {
	internal var check: @MainActor @Sendable (UUID, PageCaptureRequest) -> Bool = { _, _ in false }
}

@MainActor
internal final class TabMoveAuthorizationContext {
	internal var check: @MainActor @Sendable (UUID, [BrowserCore.Tab.ID]) -> Bool = { _, _ in false }
}

@MainActor
internal final class ProfileRetirementAuthorizationContext {
	internal var check: @MainActor @Sendable (UUID) -> Bool = { _ in false }
}
