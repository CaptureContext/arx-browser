import AppKit
import ChromiumEngine

/// ABI48 context menus (DEV-814, DEV-818), run by the link context smoke after its own
/// phases. Real right clicks go to Chromium's view; when the engine's menu begins tracking,
/// the smoke reads its titles, chooses one item the way a click would, and closes it.
@MainActor
internal final class ContextMenuSmoke {
	private let runtime: ChromiumRuntime
	private let url: URL
	private let makePage: @MainActor (String) async throws -> ChromiumPage
	private var menus: [[String]] = []
	private var choose: String?
	private var choices: [ChromiumContextMenuChoice] = []
	private var pageChoices: [ChromiumPageMenuItem] = []
	private var appItems: Set<ChromiumContextMenuItem> = Set(ChromiumContextMenuItem.allCases)
	private var tracking: (any NSObjectProtocol)?

	internal init(
		runtime: ChromiumRuntime,
		url: URL,
		makePage: @escaping @MainActor (String) async throws -> ChromiumPage
	) {
		self.runtime = runtime
		self.url = url
		self.makePage = makePage
	}

	/// Distinct titles: each item's own name, so a menu's titles say which items it has.
	private static func title(_ item: ChromiumContextMenuItem) -> String {
		switch item {
		case .lookUp: "lookUp {}"
		case .searchSelection: "searchSelection {}"
		default: "\(item)"
		}
	}

	internal func verify() async throws {
		guard runtime.supportsContextMenus else { throw Failure.unsupported }
		runtime.configureContextMenus(titles: Dictionary(
			uniqueKeysWithValues: ChromiumContextMenuItem.allCases.map { ($0, Self.title($0)) }
		))
		runtime.configurePageMenu(titles: Dictionary(
			uniqueKeysWithValues: ChromiumPageMenuItem.allCases.map { ($0, "page.\($0)") }
		))
		runtime.configureDeveloperTools(windowTitle: "Inspector", inspectTitle: "inspect", inspectsContext: true)
		runtime.onContextMenuChoice = { [weak self] _, choice in self?.choices.append(choice) }
		runtime.onContextMenuItems = { [weak self] _ in self?.appItems ?? [] }
		runtime.onPageMenuChoice = { [weak self] _, item in self?.pageChoices.append(item) }
		runtime.onPageMenuItems = { _ in Set(ChromiumPageMenuItem.allCases) }
		tracking = NotificationCenter.default.addObserver(
			forName: NSMenu.didBeginTrackingNotification,
			object: nil,
			queue: nil
		) { [weak self] notification in

			// AppKit posts it on the main thread, from inside the menu's tracking loop.
			nonisolated(unsafe) let object = notification.object
			MainActor.assumeIsolated {
				guard let menu = object as? NSMenu, menu.supermenu == nil else { return }
				self?.track(menu)
			}
		}
		defer { tracking.map(NotificationCenter.default.removeObserver) }

		// A text field: the edit items, spelling, and Inspect Element last in developer mode.
		let field = try await makePage("link-context/menu-field")
		let search = try await rightClick(field, x: 60, y: 35, choosing: "searchSelection")
		try require(search, contains: ["undo", "redo", "cut", "copy", "paste", "pasteAndMatchStyle", "selectAll", "spelling"])
		guard
			search.contains("inspect"),
			let choice = choices.last,
			choice.item == .searchSelection,
			let text = choice.text,
			"arx context words".contains(text),
			!text.isEmpty
		else { throw Failure.wrongMenu("text field \(search) \(choices)") }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_TEXT_FIELD")

		// A password field: editing only, never its text in a title or an app item.
		let secret = try await rightClick(field, x: 60, y: 85, choosing: nil)
		try require(secret, contains: ["cut", "copy", "paste", "selectAll"])
		let leaksSelection: Bool = secret.contains { title in
			title.hasPrefix("lookUp")
			|| title.hasPrefix("searchSelection")
			|| title == "shareSelection"
			|| title == "spelling"
			|| title.contains("arx-secret-value")
		}
		guard !leaksSelection else { throw Failure.wrongMenu("password \(secret)") }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_PASSWORD")

		// A selection: Look Up with the words, Copy, Search and Share; Share reaches the app.
		let words = try await makePage("link-context/menu-words")
		let selection = try await rightClick(words, x: 40, y: 128, choosing: "shareSelection")
		try require(selection, contains: ["copy", "shareSelection"])
		guard
			selection.contains(where: { $0.hasPrefix("lookUp ") && $0.contains("Selected") }),
			let shared = choices.last,
			shared.item == .shareSelection,
			let sharedText = shared.text,
			"Selected words here".contains(sharedText)
		else { throw Failure.wrongMenu("selection \(selection) \(choices)") }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_SELECTION")

		// An image: the app opens its own address. (Save Image As asks where to save.)
		let media = try await makePage("link-context/menu-media")
		let image = try await rightClick(media, x: 60, y: 210, choosing: "openImageInNewTab")
		try require(image, contains: ["openImageInNewTab", "downloadImage", "copyImage", "copyImageAddress"])
		guard
			let opened = choices.last,
			opened.item == .openImageInNewTab,
			opened.url?.path == "/link-context/pixel.png"
		else { throw Failure.wrongMenu("image \(image) \(choices)") }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_IMAGE")

		// A video: Loop, Show Controls and Picture in Picture; Open Video in New Tab reaches the app.
		let video = try await rightClick(media, x: 200, y: 215, choosing: "openVideoInNewTab")
		try require(video, contains: ["loop", "showControls", "pictureInPicture", "openVideoInNewTab", "copyVideoAddress"])
		guard
			let open = choices.last,
			open.item == .openVideoInNewTab,
			open.url?.path == "/link-context/clip.mp4"
		else { throw Failure.wrongMenu("video \(video) \(choices)") }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_VIDEO")

		// A host that allows no app items gets only the engine's own.
		appItems = []
		let count = choices.count
		let limited = try await rightClick(media, x: 60, y: 210, choosing: nil)
		try require(limited, contains: ["downloadImage", "copyImage", "copyImageAddress"])
		guard
			!limited.contains("openImageInNewTab"),
			choices.count == count
		else { throw Failure.wrongMenu("host items \(limited)") }
		appItems = Set(ChromiumContextMenuItem.allCases)
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_HOST_ITEMS")

		// The page itself: the page menu has Share… (ABI48), which goes to the app.
		let page = try await rightClick(media, x: 500, y: 400, choosing: "page.share")
		try require(page, contains: ["page.back", "page.reload", "page.print", "page.share"])
		guard pageChoices.last == .share else { throw Failure.wrongMenu("page \(page) \(pageChoices)") }
		diagnostic("ARX_LINK_CONTEXT_SMOKE_MENU_PAGE_SHARE")
	}

	/// Reads the menu's titles, chooses `choose` (nil closes it), then ends tracking. A title
	/// with the selection in it ("searchSelection <words>") matches by its first word.
	private func track(_ menu: NSMenu) {
		menus.append(menu.items.filter { !$0.isSeparatorItem }.map(\.title))
		let wanted = choose

		// The block runs on the main run loop, where the menu lives.
		nonisolated(unsafe) let menu = menu
		RunLoop.main.perform(inModes: [.eventTracking, .default]) {
			let index: Int? = wanted.flatMap { wanted in
				menu.items.firstIndex { $0.title == wanted || $0.title.hasPrefix(wanted + " ") }
			}
			if let index { menu.performActionForItem(at: index) }
			menu.cancelTracking()
		}
	}

	private func rightClick(
		_ page: ChromiumPage,
		x: Double,
		y: Double,
		choosing title: String?
	) async throws -> [String] {
		try await wait { page.navigation.title == "Arx context menus ready" && !page.navigation.isLoading }
		try await Task.sleep(for: .milliseconds(250))
		guard let window = page.view.window else { throw Failure.wrongMenu("no window") }
		window.makeKeyAndOrderFront(nil)
		choose = title
		let before = menus.count
		let local = NSPoint(x: x, y: page.view.isFlipped ? y : page.view.bounds.height - y)
		let point = page.view.convert(local, to: nil)
		for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: point,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			)
			else { throw Failure.wrongMenu("no event") }
			window.sendEvent(event)
		}
		try await wait { self.menus.count > before }

		// The choice arrives after AppKit's loop ends.
		try await Task.sleep(for: .milliseconds(250))
		return menus[before]
	}

	private func require(
		_ titles: [String],
		contains wanted: [String]
	) throws {
		let missing = wanted.filter { !titles.contains($0) }
		guard missing.isEmpty else { throw Failure.wrongMenu("missing \(missing) in \(titles)") }
	}

	private func wait(_ condition: () -> Bool) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(25))
		}
	}

	private enum Failure: Error {
		case unsupported
		case timedOut
		case wrongMenu(String)
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
