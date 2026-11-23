import AppUI
import BrowserCore
import Foundation
import MainFeature
import SwiftUI
import _ComposableArchitecture

/// The site menu of a floating window (DEV-1257): Little Arx's, or Page PiP's. It's the main
/// window's menu (DEV-633, DEV-824), the same panel and feature, with the items the window leaves
/// out (``SiteMenu/Host``). Each window keeps its own, so a clear one started finishes there.
@Reducer
public struct FloatingSiteMenu {
	/// The floating window the menu belongs to.
	public enum ID: Hashable, Sendable {
		/// A Little Arx window, floating as Page PiP or not (DEV-1112).
		case littleArx(UUID)

		/// Page PiP's window, which floats one page at a time (DEV-950).
		case pagePictureInPicture
	}

	@ObservableState
	public struct State: Equatable, Identifiable {
		public let id: ID
		public var siteMenu: SiteMenuFeature.State

		public init(
			id: ID,
			siteMenu: SiteMenuFeature.State
		) {
			self.id = id
			self.siteMenu = siteMenu
		}
	}

	@CasePathable
	public enum Action: Sendable {
		case siteMenu(SiteMenuFeature.Action)
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Scope(state: \.siteMenu, action: \.siteMenu) { SiteMenuFeature() }
	}
}

/// What a floating window's site menu sends, and where its menu's actions lead, as
/// `SiteMenuRouting` does for a main window's.
@Reducer
internal struct FloatingSiteMenuRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	/// Each window's menu in its own scope, so their effects cancel only their own.
	private var menus: some ReducerOf<Self> {
		EmptyReducer()
			.forEach(\.floatingSiteMenus, action: \.floatingSiteMenus) { FloatingSiteMenu() }
	}

	internal var body: some ReducerOf<Self> {
		menus

		// A window that goes while its menu is open, such as Page PiP returning its page, never
		// closes the popover: the menu closes here, in the same turn, so it stops reading the
		// site's settings. A clear or extension change it started still finishes.
		Reduce { state, _ in
			let orphaned = state.floatingSiteMenus
				.filter { $0.siteMenu.isOpen && state.floatingSiteMenuPage($0.id) == nil }
				.map(\.id)
			guard !orphaned.isEmpty else { return .none }

			return .merge(orphaned.map { id in
				menus.reduce(
					into: &state,
					action: .floatingSiteMenus(.element(id: id, action: .siteMenu(.ui(.menu(.closed)))))
				)
			})
		}

		Pullback(\.ui.floatingSiteMenu) { state, value in
			let (id, action) = value
			if case .opened = action {
				guard let page = state.floatingSiteMenuPage(id) else { return .none }

				state.pruneFloatingSiteMenus()
				if state.floatingSiteMenus[id: id] == nil {
					state.floatingSiteMenus.append(.init(id: id, siteMenu: .init(host: page.host)))
				}

				// What every window's menu reads from the app; Little Arx may have floated since.
				let main = state.main.siteMenu
				state.floatingSiteMenus[id: id]?.siteMenu.host = page.host
				state.floatingSiteMenus[id: id]?.siteMenu.hideElementEnabled = main.hideElementEnabled
				state.floatingSiteMenus[id: id]?.siteMenu.translatedTabs = main.translatedTabs
				state.floatingSiteMenus[id: id]?.siteMenu.fairPlayOrigins = main.fairPlayOrigins
				return .send(.floatingSiteMenus(.element(id: id, action: .siteMenu(.ui(.open(page.context))))))
			}

			guard let menu = state.floatingSiteMenus[id: id]?.siteMenu else { return .none }

			if case .runExtension = action {
				// Only for the page the menu opened over, while the window still shows it.
				guard
					let opened = menu.context,
					state.floatingSiteMenuPage(id)?.context.tabID == opened.tabID
				else { return .none }
			}
			return .send(.floatingSiteMenus(.element(id: id, action: .siteMenu(.ui(.menu(action))))))
		}

		Pullback(\.floatingSiteMenus) { state, action in
			guard case let .element(id, .siteMenu(.delegate(delegate))) = action else { return .none }

			return route(delegate, from: id, state: state)
		}
	}

	private func route(
		_ delegate: SiteMenuFeature.Action.Delegate,
		from id: FloatingSiteMenu.ID,
		state: AppFeature.State
	) -> Effect<Action> {
		switch delegate {
		case let .share(url):
			let windowID: UUID = switch id {
			case let .littleArx(windowID): windowID
			case .pagePictureInPicture: LinkSharingClient.pagePictureInPictureWindowID
			}
			return .send(.ui(.shareLinks(items: [.init(title: "", url: url)], sourceWindowID: windowID)))

		case let .command(command):
			// Only Little Arx takes the menu's commands; Page PiP's menu leaves out every item
			// that sends one.
			guard case let .littleArx(windowID) = id else { return .none }
			return .send(.ui(.command(command, .window(windowID))))

		case let .manageExtensions(profileID):
			return .send(.ui(.openExtensions(profileID)))

		case let .showExtension(profileID, extensionID):
			return .send(.ui(.showExtension(profileID, extensionID: extensionID)))

		case let .reviewExtensionUpdate(profileID, extensionID):
			return .send(.ui(.reviewExtensionUpdate(profileID, extensionID: extensionID)))

		case let .openExtensionOptions(profileID, extensionID):
			return .send(.ui(.openExtensionOptions(profileID, extensionID: extensionID)))

		case let .openSiteSettings(profileID):
			return .send(.ui(.openSiteSettings(profileID)))

		case let .clearedSiteData(profileID):
			// As Clear Browsing Data does: hover cards forget site details (DEV-1142).
			return .send(.settings(.delegate(.clearedSiteData(profileID))))

		case .extensionsChanged:
			// Settings › Extensions shows the change straight away (DEV-891).
			return .send(.settings(.extensions(.ui(.refresh))))

		case let .openWebstore(profileID):
			// DEV-1317: the store opens in a new Little Arx of the page's profile, as from a main
			// window's menu.
			return .send(.openWebstore(profileID))

		case .translatePage:
			// Translate acts on a main window's page; a floating menu leaves it out.
			return .none
		}
	}
}

extension AppFeature.State {
	/// The page a floating window's site menu describes, and the window it opens in. Nil while
	/// the window shows no page: a closed one, or Little Arx's launcher.
	internal func floatingSiteMenuPage(
		_ id: FloatingSiteMenu.ID
	) -> (context: SiteMenuFeature.Context, host: SiteMenu.Host)? {
		switch id {
		case let .littleArx(windowID):
			guard let little = littleWindows[id: windowID], !little.isCommandOnly else { return nil }

			let navigation = little.viewer.navigation
			let shown = little.viewer.tab
			let commands = commandContext(for: .window(windowID))
			return (
				context: .init(
					url: (shown == nil ? nil : navigation.url) ?? little.tab.restoration.url,
					tabID: shown?.id,
					profileID: little.tab.profileID,
					profileName: workspace.profiles[id: little.tab.profileID]?.name,
					canCapture: commands.map { BrowserCommand.captureViewport.isEnabled(in: $0) } ?? false,
					canRead: little.readingModeEnabled
					? commands.map { BrowserCommand.readingMode.isEnabled(in: $0) } ?? false
					: nil,
					loadFailed: shown != nil && navigation.errorCode != nil,
					usesWebKit: shown != nil && navigation.engine == .webKit
				),
				// Floating, Little Arx is Page PiP's window, with its menu (DEV-1112).
				host: little.isPictureInPicture ? .pagePictureInPicture : .littleArx
			)

		case .pagePictureInPicture:
			guard
				let current = pagePictureInPicture,
				current.isFloating,
				let profileID = pagePictureInPictureProfiles().current
			else { return nil }

			let source = window(current.windowID)
			let isPrivate = source?.isPrivate == true
			let url = current.navigation.url
			?? workspace.tabs[id: current.tabID]?.restoration.url
			?? source?.sidebar.organization.tabs[id: current.tabID]?.restoration.url
			?? littleWindows.first { $0.tab.id == current.tabID }?.tab.restoration.url
			?? peeks.first { $0.tab.id == current.tabID }?.tab.restoration.url
			guard let url else { return nil }

			return (
				context: .init(
					url: url,
					tabID: current.tabID,
					profileID: profileID,
					profileName: workspace.profiles[id: profileID]?.name
						?? source?.sidebar.organization.profiles[id: profileID]?.name,
					isPrivate: isPrivate,
					openerProfileID: isPrivate ? source?.privateOpenerProfileID : nil,
					// Capture and reading mode wait for the page's return to its tab.
					canCapture: false,
					canRead: nil,
					loadFailed: current.navigation.errorCode != nil,
					usesWebKit: current.navigation.engine == .webKit
				),
				host: .pagePictureInPicture
			)
		}
	}

	/// Drops the menus of windows that closed, once nothing they started is still running.
	fileprivate mutating func pruneFloatingSiteMenus() {
		let closed = floatingSiteMenus.filter { menu in
			let windowIsGone = floatingSiteMenuPage(menu.id) == nil
			let isBusy: Bool = switch menu.siteMenu.clearing {
			case .clearing: true
			default: menu.siteMenu.isChangingExtension
			}
			return windowIsGone && !menu.siteMenu.isOpen && !isBusy
		}
		for menu in closed { floatingSiteMenus.remove(id: menu.id) }
	}
}

/// Gives a floating window's URL bar its site menu (DEV-1257), as `MainSiteMenuEnvironment` does
/// a main window's.
internal struct FloatingSiteMenuEnvironment: ViewModifier {
	internal let store: StoreOf<AppFeature>
	internal let id: FloatingSiteMenu.ID

	internal func body(content: Content) -> some View {
		content.environment(\.siteMenu, source)
	}

	private var source: SiteMenuSource {
		let state = store.floatingSiteMenus[id: id]?.siteMenu
		var menu = state?.menu

		// The connection follows the page while the menu is open, such as a load that fails.
		if let state, state.isOpen, let live = store.state.floatingSiteMenuPage(id)?.context, live.url == state.context?.url {
			menu?.connection = live.connection
		}
		return .init(menu: menu) { [store, id] action in
			store.send(.ui(.floatingSiteMenu(id, action)))
		}
	}
}
