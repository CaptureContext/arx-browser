import Foundation
import MainFeature
import _ComposableArchitecture

extension AppFeature.State {
	internal mutating func publishOrganization(from originID: UUID) -> Effect<AppFeature.Action> {
		guard
			let origin = originID == main.id ? main : windows[id: originID],
			!origin.isPrivate
		else { return .none }

		// The delegate's snapshot may precede a promotion or another local edit.
		// Publish the current source even when only its older notification arrives.
		let organization = origin.sidebar.organization

		// Which window the tabs it opened are in, before the others reconcile (DEV-822). A space
		// moved to another profile gives its tabs new IDs; they stay in their windows.
		remapOpenTabOwners(from: workspace, to: organization)
		claimOpenedTabs(from: originID, previous: workspace, current: organization)
		workspace = organization
		unsavedOrganization = organization
		let recipients = ([main.id] + windows.filter { !$0.isPrivate }.map(\.id))
			.filter { $0 != originID }
		var effects: [Effect<AppFeature.Action>] = []

		for id in recipients {
			let action = MainFeature.Action.reconcile(organization)

			// Reconcile state now: a queued full snapshot could overwrite a recipient's
			// next edit before that recipient publishes its own current organization.
			effects.append(AppFeature()._reduce(
				into: &self,
				action: id == main.id ? .main(action) : .windows(.element(id: id, action: action))
			))
		}

		return .merge(effects + [.send(.delegate(.save(organization)))])
	}
}
