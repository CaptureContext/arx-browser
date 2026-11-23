import BrowserCore
import BrowserWorkspaceClient
import Foundation
import _ComposableArchitecture

/// Keeps ``WorkspaceDocument`` in step with the reducer and saves edits made through shared keys.
///
/// The organization stays reducer-owned and is mirrored into the document after every change, so
/// resolving keys can read overrides. Automation preferences stay reducer-owned too; they reach the
/// document only when ``WorkspacePersistence`` flushes.
@Reducer
internal struct SharedPreferences {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	private enum Cancellation: Hashable { case documentChanges }

	@Dependency(\.workspaceDocument)
	private var document

	@Dependency(\.installDateEvidence)
	private var installDateEvidence

	@Dependency(\.date.now)
	private var now

	internal var body: some ReducerOf<Self> {
		Pullback(\.observeWorkspaceDocument) { _ in

			// Subscribed now, not when the effect starts, so an edit right after this action isn't missed.
			let changes = document.changes()

			return .run { send in
				for await _ in changes {
					await send(.event(.workspaceDocumentChanged))
				}
			}
			.cancellable(id: Cancellation.documentChanges, cancelInFlight: true)
		}

		Pullback(\.event.workspaceDocumentChanged) { state in
			state.saveWorkspace()
		}

		// The identity card's Member since (DEV-1323). Once recorded it never changes; an install
		// from before then takes the earliest evidence on the Mac instead of today. The edit is
		// saved like any other shared preference.
		Pullback(\.recordInstallDate) { _ in
			@Shared(.installDate)
			var installDate
			guard installDate == nil else { return .none }

			let resolved: Date = InstallDate.resolved(
				recorded: nil,
				evidence: installDateEvidence.creationDates(),
				now: now
			)
			$installDate.withLock { $0 = $0 ?? resolved }
			return .none
		}
	}
}

extension Reducer where State == AppFeature.State {
	/// Mirrors the reducer-owned organization into the document after `self` changes it,
	/// so resolving keys see overrides. AppFeature saves the organization itself.
	internal func mirroringIntoWorkspaceDocument() -> some Reducer<State, Action> {
		@Dependency(\.workspaceDocument)
		var document

		return self.onChange(of: \.workspace) { _, state in
			document.update(organization: state.workspace)
			return .none
		}
	}
}

extension AppFeature.State {
	/// The preferences a save of this state writes: every shared domain from the document,
	/// and the automation preferences AppFeature owns.
	internal var persistedPreferences: BrowserPreferences {
		@Dependency(\.workspaceDocument)
		var document

		var preferences = document.preferences
		preferences.automation = automationPreferences
		return preferences
	}

	/// Marks the workspace unsaved and asks for a save, as edits to reducer-owned values do.
	internal mutating func saveWorkspace() -> Effect<AppFeature.Action> {
		unsavedOrganization = workspace
		return .send(.delegate(.save(workspace)))
	}

	/// Replaces every preference domain together with the organization, as a migration commit does:
	/// one document transaction, so shared readers never see half of it. The caller saves the result.
	internal mutating func commit(
		organization: BrowserOrganization,
		preferences: BrowserPreferences
	) {
		@Dependency(\.workspaceDocument)
		var document

		automationPreferences = preferences.automation
		document.update(organization: organization, preferences: preferences)
	}
}
