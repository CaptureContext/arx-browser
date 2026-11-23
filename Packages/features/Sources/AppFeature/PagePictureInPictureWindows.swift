import AppKit
import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
import SwiftUI
import _ComposableArchitecture

/// Opens Page PiP's window once the tab's window let go of its page, and closes it when the page
/// goes back, letting go of the page before its tab takes it (DEV-950). BrowserWindow drives it
/// for the app's store; the media smoke drives it for its own.
@MainActor
internal final class PagePictureInPictureWindows {
	/// The window and the tab whose page it holds.
	internal private(set) var current: (tabID: BrowserCore.Tab.ID, panel: PagePictureInPicturePanel)?

	/// The floating page whose return was reported, so it's reported once.
	private var reportedReturn: BrowserCore.Tab.ID?

	internal init() {}

	/// Brings the window in line with the store's Page PiP. `sourceWindow` finds the window a page
	/// left, whose screen the floating window opens on.
	internal func update(
		store: StoreOf<AppFeature>,
		surface: BrowserSurfaceClient,
		sourceWindow: (UUID) -> NSWindow?
	) {
		let state = store.pagePictureInPicture
		if let current, state?.tabID != current.tabID || state?.isFloating != true {
			self.current = nil
			PagePictureInPictureSizes.remember(current.panel.frame.size, for: current.panel.siteKey)

			// Let go of the page now: the window's own view may not be torn down until later.
			surface.release(current.tabID)
			current.panel.contentView = nil
			current.panel.close()
		}

		if let state, case .returning = state.phase, current == nil {
			if reportedReturn != state.tabID {
				reportedReturn = state.tabID

				// Sent after this update, so the tab's window takes the page only once it's free.
				let tabID = state.tabID
				Task { @MainActor [weak store] in
					store?.send(.event(.pagePictureInPictureClosed(tabID)))
				}
			}
		} else {
			reportedReturn = nil
		}

		guard let state, state.isFloating, current == nil else { return }

		let site = Self.site(of: state.tabID, in: store.state)
		let panel = PagePictureInPicturePanel(
			contentSize: PagePictureInPictureSizes.size(for: site) ?? PagePictureInPicturePanel.defaultSize,
			on: sourceWindow(state.windowID)?.screen,
			siteKey: site
		)
		panel.identifier = .init(PagePictureInPicturePanel.identifier)
		panel.title = String.localized(.appUI.pagePicture.command)
		panel.show(
			PagePictureInPictureContent(
				store: store,
				tabID: state.tabID,
				windowID: state.windowID,
				surface: surface
			)

			// The main window's site menu, with what a floating window leaves out (DEV-1257), and
			// what its Share reports, at the window's corner as Little Arx's.
			.modifier(FloatingSiteMenuEnvironment(store: store, id: .pagePictureInPicture))
			.modifier(LinkFeedbackToast(
				store: store,
				windowID: LinkSharingClient.pagePictureInPictureWindowID,
				topInset: BrowserMetrics.LittleArx.toolbarHeight + ArxToastMetrics.edgeInset - 4,
				trailingInset: BrowserMetrics.LittleArx.pageInset + ArxToastMetrics.edgeInset - 4
			))
		)
		current = (state.tabID, panel)

		// In front without taking the keyboard from the window the person is in.
		panel.orderFrontRegardless()
	}

	/// The site Page PiP remembers a size for: the floating page's host.
	private static func site(
		of tabID: BrowserCore.Tab.ID,
		in state: AppFeature.State
	) -> String? {
		let url = state.workspace.tabs[id: tabID]?.restoration.url
		?? state.littleWindows.first { $0.tab.id == tabID }?.tab.restoration.url
		?? state.peeks.first { $0.tab.id == tabID }?.tab.restoration.url
		return url?.host()
	}
}
