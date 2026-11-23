import BrowserCore
import SwiftUI

extension RoutingWindowMode {
	public var routingTitle: String {
		switch self {
		case .mainBrowser: String.localized(.appUI.routing.mainBrowser)
		case .littleArx: String.localized(.appUI.routing.littleArx)
		}
	}
}

extension RoutingDestination {
	public func routingTitle(in organization: BrowserOrganization) -> String {
		guard scope != .ask else { return scope.routingTitle(in: organization) }
		return String.localized(.appUI.routing.destinationTitle(scope.routingTitle(in: organization), mode.routingTitle))
	}
}

public func routingErrorMessage(_ error: URLRoutingError) -> String {
	switch error {
	case .invalidDefinition: String.localized(.appUI.routing.invalidDefinition)
	case .unsupportedURL: String.localized(.appUI.routing.unsupportedURL)
	case .missingDestination: String.localized(.appUI.routing.chooseDestination)
	case .missingProfile: String.localized(.appUI.routing.missingProfile)
	case .missingSpace: String.localized(.appUI.routing.missingSpace)
	}
}

/// A destination in full, for a link waiting in Incoming Links: the most recent space, or a
/// profile's most recent space or one of its spaces, each in a main window or Little Arx.
public struct RoutingDestinationMenu: View {
	public let organization: BrowserOrganization
	public let destination: RoutingDestination?
	public let onSelect: (RoutingDestination) -> Void

	public init(
		organization: BrowserOrganization,
		destination: RoutingDestination? = nil,
		onSelect: @escaping (RoutingDestination) -> Void
	) {
		self.organization = organization
		self.destination = destination
		self.onSelect = onSelect
	}

	public var body: some View {
		let title: String = destination.flatMap { $0.scope == .ask ? nil : $0.routingTitle(in: organization) }
		?? String.localized(.appUI.routing.chooseDestination)

		Menu(title) {
			destinationModes(String.localized(.appUI.routing.currentSpace), scope: .currentSpace)
			Divider()
			ForEach(organization.profiles) { profile in
				Menu(profile.name) {
					destinationModes(String.localized(.appUI.routing.currentSpace), scope: .profile(profile.id))
					Divider()
					ForEach(organization.spaces.filter { $0.profileID == profile.id }) { space in
						destinationModes(space.name, scope: .space(space.id))
					}
				}
			}
		}
	}

	private func destinationModes(
		_ name: String,
		scope: RoutingDestination.Scope
	) -> some View {
		Menu(name) {
			ForEach(RoutingWindowMode.allCases, id: \.rawValue) { mode in
				Button(mode.routingTitle) { onSelect(.init(scope: scope, mode: mode)) }
			}
		}
	}
}

extension RoutingDestination.Scope {
	/// The space a route opens in, with its profile when it's a specific space.
	public func routingTitle(in organization: BrowserOrganization) -> String {
		switch self {
		case .currentSpace:
			return String.localized(.appUI.routing.currentSpace)

		case .ask:
			return String.localized(.appUI.routing.askEveryTime)

		case let .profile(id):
			let profile = organization.profiles[id: id]?.name ?? String.localized(.appUI.routing.missingProfile)
			return String.localized(.appUI.routing.spaceOfProfile(String.localized(.appUI.routing.currentSpace), profile))

		case let .space(id):
			guard let space = organization.spaces[id: id]
			else { return String.localized(.appUI.routing.missingSpace) }

			let profile = organization.profiles[id: space.profileID]?.name ?? ""
			return organization.profiles.count > 1
			? String.localized(.appUI.routing.spaceOfProfile(space.name, profile))
			: space.name
		}
	}
}

/// Where a route opens: the most recent space, Ask for a Destination, or for each profile its most
/// recent space or one of its spaces.
public struct RoutingSpaceMenu: View {
	public let organization: BrowserOrganization
	public let scope: RoutingDestination.Scope
	public let onSelect: (RoutingDestination.Scope) -> Void

	public init(
		organization: BrowserOrganization,
		scope: RoutingDestination.Scope,
		onSelect: @escaping (RoutingDestination.Scope) -> Void
	) {
		self.organization = organization
		self.scope = scope
		self.onSelect = onSelect
	}

	public var body: some View {
		Menu {
			Button(String.localized(.appUI.routing.currentSpace)) { onSelect(.currentSpace) }
			Button(String.localized(.appUI.routing.askEveryTime)) { onSelect(.ask) }
			Divider()
			ForEach(organization.profiles) { profile in
				Menu(profile.name) {
					Button(String.localized(.appUI.routing.currentSpace)) { onSelect(.profile(profile.id)) }
					Divider()
					ForEach(organization.spaces.filter { $0.profileID == profile.id }) { space in
						Button(space.name) { onSelect(.space(space.id)) }
					}
				}
			}
		} label: {
			Label(scope.routingTitle(in: organization), systemImage: symbol)
		}

		// A system menu, since its profiles nest their spaces, drawn as an Arx button so it
		// matches the dropdowns beside it.
		.menuStyle(.button)
		.buttonStyle(.arx)
		.fixedSize()
		.arxMenuHover()
	}

	private var symbol: String {
		switch scope {
		case .currentSpace, .profile: "clock.arrow.circlepath"
		case .space: "square.stack"
		case .ask: "questionmark.circle"
		}
	}
}

/// Whether a route opens in a main window or in Little Arx, as Arx's dropdown: it sits inside a
/// rule's row, where a system pop-up looks out of place.
public struct RoutingWindowPicker: View {
	public let mode: RoutingWindowMode
	public let onSelect: (RoutingWindowMode) -> Void

	public init(
		mode: RoutingWindowMode,
		onSelect: @escaping (RoutingWindowMode) -> Void
	) {
		self.mode = mode
		self.onSelect = onSelect
	}

	public var body: some View {
		ArxDropdown(
			String.localized(.appUI.routing.openIn),
			selection: Binding(get: { mode }, set: { onSelect($0) }),
			options: RoutingWindowMode.allCases.map { .init(id: $0, title: $0.routingTitle) }
		)
		.fixedSize()
	}
}
