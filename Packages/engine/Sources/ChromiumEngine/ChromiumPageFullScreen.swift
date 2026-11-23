import ChromiumBridge
import Foundation

extension ChromiumRuntime {
	/// ABI54 (DEV-949): whether pages can enter HTML full screen. Older engines refuse every
	/// request, as their delegate's defaults did nothing.
	public var supportsPageFullScreen: Bool {
		state == .running && api.exit_page_fullscreen != nil
	}

	/// ABI54 (DEV-949): takes the page out of HTML full screen, as Escape does.
	/// ``onPageFullScreen`` reports it. False when the page isn't in full screen.
	@discardableResult
	public func exitFullScreen(_ page: ChromiumPage) -> Bool {
		guard
			state == .running,
			pages[page.identifier] === page,
			let exit = api.exit_page_fullscreen
		else { return false }

		return exit(page.identifier)
	}
}
