import BrowserCore
import BrowserWorkspaceClient
import Foundation
import MainFeature
import _ComposableArchitecture

@testable import AppFeature

extension WorkspaceDocument {
	/// A document that holds `preferences` and never writes: without an organization it has nothing to save.
	///
	/// Build state that reads shared preferences inside `withDependencies` with this document, and give
	/// the store the same one, so parallel cases of a parameterized test don't share a document.
	internal static func unsaved(_ preferences: BrowserPreferences = .init()) -> WorkspaceDocument {
		.init(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: nil,
			preferences: preferences
		)
	}
}

extension AppFeature.State {
	/// State built the way launch builds it: `preferences` go into the test's workspace document
	/// first, because shared preference keys (window layouts, onboarding) read them from there.
	///
	/// Seeds the document the current test resolves. Parallel cases of one parameterized test
	/// share it, so they build state inside `withDependencies` with ``WorkspaceDocument/unsaved(_:)``.
	internal static func launching(
		main: MainFeature.State,
		preferences: BrowserPreferences
	) -> Self {
		@Dependency(\.workspaceDocument)
		var document

		document.updatePreferences(requestsSave: false) { $0 = preferences }

		return .init(main: main, automation: preferences.automation)
	}
}
