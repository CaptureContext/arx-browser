import AppKit
import ChromiumEngine

/// ABI21 tab lookup and ABI22 windows: the fixture worker reaches the exact Arx
/// source page from `action.onClicked` through `tabs.get`, `tabs.query` and
/// `tabs.sendMessage`, then checks window-scoped queries and `chrome.windows`.
/// The source shares its window with an active same-profile page; other-profile
/// and private pages sit in windows of their own, and none may count. A popup
/// opened for the inactive source must still find it with the usual
/// `{active: true, currentWindow: true}` query.
@MainActor
internal enum ExtensionTabsSmoke {
	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		windowmate: ChromiumPage,
		others: [ChromiumPage],
		url: URL,
		extensionID: String,
		profileTabs: Int
	) async throws {
		guard
			runtime.supportsExtensionWindows,
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		else { throw Failure.source }

		components.queryItems = [.init(name: "tabs_action", value: "1")]
		guard let armedURL = components.url
		else { throw Failure.source }

		try page.navigate(to: armedURL)
		try await wait(page, title: "ARX_EXTENSION_TABS_ARMED:\(extensionID)")

		try place(runtime: runtime, page: page, windowmate: windowmate, others: others)
		defer { runtime.setExtensionTabPlacements([]) }

		try runtime.configureContentHosting(on: page, enabled: true)
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }

		let bystanders = [windowmate] + others
		let before = bystanders.map(\.navigation)
		try await ExtensionShortcutSmoke.focus(page, runtime: runtime)
		_ = try ExtensionShortcutSmoke.press(.action, on: page)

		// The source is index 1 behind the active windowmate; the worker's current
		// window is the last focused one, whose active page is the windowmate.
		let windows = [
			"index=1",
			"active=false",
			"window=2/1",
			"indexed=true",
			"current=0",
			"focused=true",
			"windows=1/2",
			"fetched=true",
			"own=true",
			"incognito=false",
		].joined(separator: ":")
		try await wait(
			page,
			title: "ARX_EXTENSION_TABS:action:\(extensionID):get=true:tabs=\(profileTabs):reach=\(profileTabs):\(windows)"
		)

		// The action set this page's popup; it reports what its current window holds.
		try await ExtensionShortcutSmoke.focus(page, runtime: runtime)
		_ = try ExtensionShortcutSmoke.press(.action, on: page)
		try await wait(
			page,
			title: "ARX_EXTENSION_TABS:popup:\(extensionID):active=1:window=true:index=1:highlighted=true"
		)

		// The messages reached only the exact source page.
		try await Task.sleep(for: .milliseconds(300))
		guard bystanders.map(\.navigation) == before
		else { throw Failure.isolation }
	}

	/// The source and its windowmate share the source's window; every other page
	/// has its own. Private pages are listed too: the engine must hide them.
	private static func place(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		windowmate: ChromiumPage,
		others: [ChromiumPage]
	) throws {
		guard let window = page.view.window
		else { throw Failure.source }

		var placements: [(page: ChromiumPage, placement: ChromiumExtensionTabPlacement)] = [
			(windowmate, .init(
				windowNumber: window.windowNumber,
				index: 0,
				isActive: true,
				isHighlighted: true
			)),
			(page, .init(
				windowNumber: window.windowNumber,
				index: 1,
				isActive: false,
				isHighlighted: false
			)),
		]
		for other in others {
			guard let window = other.view.window
			else { throw Failure.source }

			let placement = ChromiumExtensionTabPlacement(
				windowNumber: window.windowNumber,
				index: 0,
				isActive: true,
				isHighlighted: true
			)
			placements.append((other, placement))
		}
		runtime.setExtensionTabPlacements(placements)
	}

	private static func wait(
		_ page: ChromiumPage,
		title: String
	) async throws {
		for _ in 0..<300 {
			try Task.checkCancellation()

			if page.navigation.title == title, !page.navigation.isLoading { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		FileHandle.standardError.write(Data("ARX_EXTENSION_TABS_TITLE \(page.navigation.title)\n".utf8))
		throw Failure.timeout
	}

	private enum Failure: Error {
		case source
		case isolation
		case timeout
	}
}
