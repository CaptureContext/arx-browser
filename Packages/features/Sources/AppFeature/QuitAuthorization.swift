import BrowserCore
import _ComposableArchitecture

/// Revalidates page approvals after native confirmation dialogs run their event loop.
internal struct QuitAuthorization: Sendable {
	internal var check: @MainActor @Sendable ([BrowserCore.Tab.ID]) -> Bool
}

extension QuitAuthorization: DependencyKey {
	internal static var liveValue: Self { .init { _ in false } }
	internal static var testValue: Self { .init { _ in true } }
}

extension DependencyValues {
	internal var quitAuthorization: QuitAuthorization {
		get { self[QuitAuthorization.self] }
		set { self[QuitAuthorization.self] = newValue }
	}
}

extension AppFeature.State {
	internal func canCommitQuit(approvedTabs: [BrowserCore.Tab.ID]) -> Bool {
		checkingQuit && !shouldQuit && allTabIDs == approvedTabs
			&& (unsavedOrganization == nil || discardUnsavedChangesOnQuit)
	}
}
