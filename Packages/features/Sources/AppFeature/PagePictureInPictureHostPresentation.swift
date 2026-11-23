import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import Foundation
import SwiftUI
import _ComposableArchitecture

/// Lends a window's page to Page PiP (DEV-950): every window lets go of the floating tab's page
/// and shows "Playing in Picture in Picture" with Return to Tab where it would be. A browser
/// window's tab menus offer Present Tab in Picture in Picture (DEV-1105), and Present Media in
/// Picture in Picture while the tab plays (DEV-1106).
///
/// Apply it outside Peek's modifier, so a Peek of the tab lets go of it too.
internal struct PagePictureInPictureHostPresentation: ViewModifier {
	internal let store: StoreOf<AppFeature>

	/// The browser window whose tab menus present tabs, with the store's engine, which knows
	/// which tabs show only a transfer (DEV-1116); `nil` offers none.
	internal let menus: (windowID: UUID, engine: BrowserEngineClient)?

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
		self.menus = nil
	}

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID,
		engine: BrowserEngineClient
	) {
		self.store = store
		self.menus = (windowID, engine)
	}

	internal func body(content: Content) -> some View {
		let tabID: BrowserCore.Tab.ID? = store.pagePictureInPicture?.tabID
		content
			.transformEnvironment(\.suppressedBrowserTabs) { tabs in
				if let tabID { tabs.insert(tabID) }
			}
			.environment(\.browserPictureInPictureActions, menus.map { windowID, engine in
				.init(
					canPresentTab: { [store] id in
						store.state.canPresentTabInPictureInPicture(.init(rawValue: id), in: windowID, engine: engine)
					},
					presentTab: { [store] id in
						store.send(.ui(.presentTabInPictureInPicture(.init(rawValue: id), windowID: windowID)))
					},
					// A private window's tabs have no media controls (DEV-1106).
					media: { [store] id in
						store.state.window(windowID)?.isPrivate == false
						? store.state.mediaPictureInPicture(ofTab: .init(rawValue: id))
						: nil
					},
					presentMedia: { [store] id in
						guard let source = store.state.presentableMedia(of: .init(rawValue: id)) else { return }
						store.send(.media(.ui(.perform(source.id, .enterPictureInPicture))))
					},
					// A private window's media never floats on its own (DEV-1246), so its tabs have
					// no automatic choice.
					automaticChoice: { [store] id in
						store.state.window(windowID)?.isPrivate == false
						? store.state.media.automatic.choice(for: .init(rawValue: id))
						: nil
					},
					setAutomaticChoice: { [store] id, choice in
						store.send(.media(.ui(.setTabChoice(.init(rawValue: id), choice))))
					}
				)
			})
			.environment(\.browserTabPlaceholder, .init { [store] id in
				guard store.pagePictureInPicture?.tabID == id else { return nil }

				return AnyView(PagePictureInPicturePlaceholder {
					store.send(.ui(.closePagePictureInPicture(focusesTab: true)))
				})
			})
	}
}
