import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Trusted application controls; webpage content cannot send these actions.
internal struct AutomationSignInView: View {
	internal let store: StoreOf<AppFeature>

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	internal var body: some View {
		if let record {
			panel {
				Text(localized: .appUI.automation.signIn.title)
					.font(.headline)
				Text(record.request.origin ?? "")
					.font(.body.monospaced())
					.textSelection(.enabled)
				if let client = client(record.clientID) {
					Text(localized: .appUI.automation.signIn.requestedBy(client.name))
						.bold()
				}
				Text(localized: .appUI.automation.signIn.originNote)
				Text(localized: .appUI.automation.signIn.pauseNote)
					.font(.callout)

				status(record)

				if record.isActive {
					Button(String.localized(.appUI.automation.signIn.cancel)) {
						store.send(.automation(.signIn(.ui(.cancel(record.request.operationID)))))
					}
					.accessibilityIdentifier(Control.cancel.rawValue)
				}
				if store.state.automationPrivacyIsLocked, !record.isActive {
					endLockControls
				}
			}

		} else if store.state.automationPrivacyIsLocked {
			panel {
				Text(localized: .appUI.automation.signIn.lockTitle)
					.font(.headline)
				Text(localized: .appUI.automation.signIn.lockNote)
				endLockControls
			}
		}
	}

	@ViewBuilder
	private func status(_ record: AutomationSignInState.Record) -> some View {
		let id = record.request.operationID
		switch record.status {
		case .approvalRequired:
			Button(String.localized(.appUI.automation.signIn.approve)) {
				store.send(.automation(.signIn(.ui(.approve(id)))))
			}
			.buttonStyle(.borderedProminent)
			.accessibilityIdentifier(Control.approve.rawValue)

		case .securingPrivacy:
			Text(localized: .appUI.automation.signIn.securing)

		case .userActionRequired:
			Text(localized: .appUI.automation.signIn.userAction)
			Button(String.localized(.appUI.automation.signIn.confirm)) {
				store.send(.automation(.signIn(.ui(.confirm(id)))))
			}
			.accessibilityIdentifier(Control.confirm.rawValue)

		case .blocked:
			Text(localized: .appUI.automation.signIn.blocked)

		case .userConfirmed:
			Text(localized: .appUI.automation.signIn.confirmed)

		case .cancelled, .expired:
			Text(localized: .appUI.automation.signIn.ended)
		}
	}

	private func panel(@ViewBuilder _ content: () -> some View) -> some View {
		let buildsAccessibilityElements = Self.buildsAccessibilityElements
		return VStack(alignment: .leading, spacing: 8, content: content)
			.padding()
			.frame(maxWidth: 560, alignment: .leading)
			.pagePopupSurface()
			.accessibilityIdentifier(Control.panel.rawValue)
			.transformEnvironment(\.accessibilityEnabled) { enabled in
				if buildsAccessibilityElements { enabled = true }
			}
	}

	private func client(_ id: UUID) -> AutomationClient? {
		store.automationPreferences.clients.first { $0.id == id }
	}

	/// A finished handoff stays visible only while it still holds the privacy lock.
	private var record: AutomationSignInState.Record? {
		let records = store.automation.signIn.records.values
		if let active = records.first(where: \.isActive) { return active }
		guard store.state.automationPrivacyIsLocked
		else { return nil }

		return records
			.filter { $0.lockID != nil }
			.max(by: { $0.expiresAt < $1.expiresAt })
	}

	@ViewBuilder
	private var endLockControls: some View {
		let clients = store.automationPreferences.clients
		if !clients.isEmpty {
			Divider()
			Text(localized: .appUI.automation.signIn.keepTitle)
				.bold()
			Text(localized: .appUI.automation.signIn.keepNote)
				.font(.callout)
			ForEach(clients) { client in
				Toggle(
					client.name,
					isOn: Binding(
						get: { store.automation.signIn.keptClientIDs.contains(client.id) },
						set: { store.send(.automation(.signIn(.ui(.keepClient(client.id, $0))))) }
					)
				)
				.toggleStyle(.checkbox)
				.disabled(store.automation.signIn.resumingLockID != nil)
				.accessibilityIdentifier(Control.keepIdentifier(client.id))
			}
		}
		resumeButton
	}

	private var resumeButton: some View {
		Button(String.localized(.appUI.automation.signIn.resume)) {
			store.send(.automation(.signIn(.ui(.resume))))
		}
		.disabled(store.automation.signIn.resumingLockID != nil)
		.accessibilityIdentifier(Control.resume.rawValue)
	}
}

extension AutomationSignInView {
	/// SwiftUI builds a window's accessibility elements only once an assistive
	/// client connects. The Debug sign-in smoke's interface driver runs in process
	/// and is no client, so it turns them on for this panel, as a client would.
	/// Always false outside that smoke.
	@MainActor
	internal static var buildsAccessibilityElements: Bool = false

	/// Stable accessibility identifiers. The Debug sign-in smoke's interface
	/// driver finds and presses these controls instead of sending store actions.
	internal enum Control: String, CaseIterable, Sendable {
		case panel = "automation.signIn.panel"
		case approve = "automation.signIn.approve"
		case confirm = "automation.signIn.confirm"
		case cancel = "automation.signIn.cancel"
		case resume = "automation.signIn.resume"

		internal static func keepIdentifier(_ clientID: UUID) -> String {
			"automation.signIn.keep.\(clientID.uuidString)"
		}
	}
}
