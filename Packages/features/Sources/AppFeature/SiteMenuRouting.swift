import BrowserCore
import BrowserExtensionsClient
import Foundation
import MainFeature
import SettingsFeature
import _ComposableArchitecture

/// Where the URL bar's site menu (DEV-633) leads outside its window: the share sheet,
/// and Settings at the page's profile, for its extensions or its site settings. A Settings row
/// chosen in the command bar opens here too (DEV-1015).
@Reducer
internal struct SiteMenuRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserExtensions)
	private var extensions

	internal var body: some ReducerOf<Self> {
		Pullback(\.main.delegate) { state, delegate in
			route(delegate, from: state.main.id)
		}

		Pullback(\.windows) { _, action in
			guard case let .element(id, .delegate(delegate)) = action else { return .none }
			return route(delegate, from: id)
		}

		Pullback(\.ui.openExtensions) { state, profileID in
			guard state.workspace.profiles[id: profileID] != nil else { return .none }

			return Self.openExtensions(profileID)
		}

		Pullback(\.ui.showExtension) { state, value in
			let (profileID, extensionID) = value
			guard state.workspace.profiles[id: profileID] != nil else { return .none }

			return .concatenate(
				Self.openExtensions(profileID),
				.send(.settings(.extensions(.reveal(extensionID))))
			)
		}

		// DEV-1210: the sheet opens on the profile, and the review starts once its inventory is in.
		Pullback(\.ui.reviewExtensionUpdate) { state, value in
			let (profileID, extensionID) = value
			guard state.workspace.profiles[id: profileID] != nil else { return .none }

			return .concatenate(
				Self.openExtensions(profileID),
				.send(.settings(.extensions(.reviewUpdateRequested(extensionID))))
			)
		}

		Pullback(\.ui.openExtensionOptions) { state, value in
			let (profileID, extensionID) = value
			guard
				state.workspace.profiles[id: profileID] != nil,
				MainActor.assumeIsolated({ [extensions] in extensions.optionsAvailability() })
			else { return .none }

			// The options view needs the profile's current inventory authority, so read it first.
			// Reading replaces the authority an open sheet on that profile holds, and opening
			// consumes it even when it fails, so that sheet reads again however this ends.
			return .run { [extensions] send in
				do {
					let inventory = try await extensions.inspect(profileID)
					let canOpenOptions: Bool = inventory.extensions.contains { item in
						item.id == extensionID
						&& item.canOpenOptions
						&& item.state == .enabled
						&& !item.permissionsIncreased
					}
					if canOpenOptions {
						_ = try await extensions.openOptions(
							.init(
								inventory: inventory,
								extensionID: extensionID
							)
						)
					}
				} catch {}
				await send(.event(.extensionInventoryRead(profileID)))
			}
		}

		Pullback(\.event.extensionInventoryRead) { state, profileID in
			let sheet = state.settings.extensions
			guard sheet.isPresented, sheet.profile?.id == profileID else { return .none }

			return .send(.settings(.extensions(.ui(.refresh))))
		}

		// `arx://settings/…` and `chrome://settings/…` addresses (DEV-1189), for the window's
		// profile: a main window's, another window's or a Little Arx window's.
		Pullback(\.main.delegate.openSettingsAddress) { state, address in
			Self.open(address, profileID: state.windowProfileID(state.main.id), target: state.commandTarget(in: state.main.id))
		}

		Pullback(\.windows) { state, action in
			guard case let .element(id, .delegate(.openSettingsAddress(address))) = action else { return .none }
			return Self.open(address, profileID: state.windowProfileID(id), target: state.commandTarget(in: id))
		}

		Pullback(\.littleWindows) { state, action in
			guard
				case let .element(id, .delegate(.openSettingsAddress(address))) = action,
				let little = state.littleWindows[id: id]
			else { return .none }

			return Self.open(address, profileID: little.tab.profileID, target: state.commandTarget(in: id))
		}

		Pullback(\.ui.openSiteSettings) { state, profileID in
			guard state.workspace.profiles[id: profileID] != nil else { return .none }

			return .concatenate(
				Self.open(profileID),
				.send(.settings(.ui(.showSiteSettings(profileID))))
			)
		}
	}

	private func route(
		_ delegate: MainFeature.Action.Delegate,
		from windowID: UUID
	) -> Effect<Action> {
		switch delegate {
		case let .shareURL(url):
			.send(.ui(.shareLinks(items: [.init(title: "", url: url)], sourceWindowID: windowID)))
		case let .manageExtensions(profileID):
			.send(.ui(.openExtensions(profileID)))
		case let .showExtension(profileID, extensionID):
			.send(.ui(.showExtension(profileID, extensionID: extensionID)))
		case let .reviewExtensionUpdate(profileID, extensionID):
			.send(.ui(.reviewExtensionUpdate(profileID, extensionID: extensionID)))
		case let .openExtensionOptions(profileID, extensionID):
			.send(.ui(.openExtensionOptions(profileID, extensionID: extensionID)))
		case let .openSiteSettings(profileID):
			.send(.ui(.openSiteSettings(profileID)))
		case let .openWebstore(profileID):
			.send(.openWebstore(profileID))
		case let .clearedSiteData(profileID):
			// As Clear Browsing Data does: hover cards forget site details (DEV-1142).
			.send(.settings(.delegate(.clearedSiteData(profileID))))
		case let .openSettingsRow(id):
			// A row the command bar found (DEV-1015): Settings scrolls to it as its own search does.
			SettingsDestination(id: id).map { destination in
				Effect<Action>.concatenate(
					.send(.ui(.openSettings)),
					.send(.settings(.ui(.searchResultChosen(destination))))
				)
			} ?? .none
		case let .translatePage(tabID):
			.send(.translation(.toggle(tabID)))
		case let .pageTranslation(tabID, action):
			.send(.translation(.offer(tabID, action)))
		case .extensionsChanged:
			// DEV-891: Settings › Extensions shows the change straight away. Reading the
			// inventory there also replaced the sheet's authority, so it reads again anyway.
			.send(.settings(.extensions(.ui(.refresh))))
		default:
			.none
		}
	}

	/// Settings, on the Profiles page with that profile selected.
	private static func open(_ profileID: Profile.ID) -> Effect<Action> {
		.concatenate(
			.send(.ui(.openSettings)),
			.send(.settings(.ui(.categorySelected(.profiles)))),
			.send(.settings(.ui(.profileSelected(profileID))))
		)
	}

	/// Where a settings address leads (DEV-1189). A profile's own page or sheet opens for
	/// `profileID`, the profile of the window it came from; a private window has none, so
	/// Settings opens at Profiles. Anything Settings can't place opens it at its top.
	internal static func open(
		_ address: SettingsAddress,
		profileID: Profile.ID?,
		target: AppFeature.CommandTarget
	) -> Effect<Action> {
		switch address {
		case .top:
			return top

		case let .destination(id):
			return SettingsDestination(id: id).map(Self.open) ?? top

		case let .path(pane, item):
			let destination = MainActor.assumeIsolated { SettingsDestination(pane: pane, item: item) }
			return destination.map(Self.open) ?? top

		case let .profile(settings):
			guard let profileID else { return Self.open(.pane(.profiles)) }
			let profile = open(profileID)
			let sheet: SettingsFeature.Action.UI = switch settings {
			// The profile's own page, which holds its search engine and downloads.
			case .page: .pagePresented(.profile)
			case .siteSettings: .showSiteSettings(profileID)
			case .passwords: .showSavedPasswords(profileID)
			case .autofill: .showAutofill(profileID)
			case .clearBrowsingData: .showClearBrowsingData(profileID)
			}
			return .concatenate(profile, .send(.settings(.ui(sheet))))

		case let .command(command):
			return .send(.ui(.command(command, target)))
		}
	}

	/// Settings at a pane, row or page, as its own search goes there.
	private static func open(_ destination: SettingsDestination) -> Effect<Action> {
		.concatenate(
			.send(.ui(.openSettings)),
			.send(.settings(.ui(.searchResultChosen(destination))))
		)
	}

	/// Settings at its first pane, from the top.
	private static var top: Effect<Action> {
		SettingsCategory.available.first.map { open(.pane($0)) } ?? .send(.ui(.openSettings))
	}

	/// Settings at that profile, with its Extensions sheet presented.
	///
	/// The actions come as one flat sequence, so an action concatenated after this effect is
	/// reduced once the sheet shows the profile. Sending `.ui(.openExtensions)` instead
	/// only queues these behind whatever the caller sends next (DEV-801).
	internal static func openExtensions(_ profileID: Profile.ID) -> Effect<Action> {
		.concatenate(
			open(profileID),
			.send(.settings(.extensions(.ui(.present))))
		)
	}
}

extension AppFeature.State {
	/// The profile of the space a window shows, for commands that act on a profile.
	internal func windowProfileID(_ id: UUID) -> Profile.ID? {
		if id == main.id, windowIsOpen { return main.isPrivate ? nil : main.sidebar.space.profileID }
		guard let window = windows[id: id], !window.isPrivate else { return nil }
		return window.sidebar.space.profileID
	}
}
