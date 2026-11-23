import AppUI
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Settings › Developer › Security data (DEV-874): the certificate revocation list, PKI
/// metadata and certificate error help the engine keeps updating, and the versions it uses.
@Reducer
internal struct SettingsSecurityData {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.loadSecurityComponents) { _ in
			.run { [engine] send in
				await send(.event(.securityComponentsLoaded(engine.securityComponents())))
			}
			.cancellable(id: Cancellation.load, cancelInFlight: true)
		}

		Pullback(\.event.securityComponentsLoaded) { state, components in
			state.securityComponents = components
			return .none
		}
	}

	private enum Cancellation: Hashable {
		case load
	}
}

extension BrowserSecurityComponent.Kind {
	internal var title: String {
		switch self {
		case .revocationList: String.localized(.appUI.developer.securityDataRevocationList)
		case .pkiMetadata: String.localized(.appUI.developer.securityDataCertificateTransparency)
		case .certificateErrorAssistant: String.localized(.appUI.developer.securityDataErrorAssistant)
		}
	}
}

extension BrowserSecurityComponent {
	internal var versionText: String {
		guard let version
		else { return String.localized(.appUI.developer.securityDataMissing) }
		guard let installed
		else { return String.localized(.appUI.developer.securityDataVersionOnly(version)) }

		return String.localized(
			.appUI.developer.securityDataVersion(version, installed.formatted(date: .abbreviated, time: .shortened))
		)
	}
}
