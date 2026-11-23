#if DEBUG
import AppKit
import BrowserCore
import ChromiumBrowserEngine
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import _ComposableArchitecture

/// The private Save Page As ticket's hand check (DEV-816), through AppKit's real save panel.
///
/// 1. A private window's page menu offers Save As and Print. Print was off in private windows
///    when the ticket was written; the private print ticket (DEV-971) turned it on, so the check
///    is that both are on.
/// 2. Save Page As in the private window, as HTML only, into a new folder
///    (`ARX_HAND_CHECK_PRIVATE_FOLDER`). The file is written.
/// 3. Past the time Arx watches AppKit's remembered folder, `NSOSPLastRootDirectory` doesn't
///    name that folder.
/// 4. Save Page As in an ordinary window doesn't open in that folder; it's cancelled.
/// 5. A PDF document in the private window saves as its own bytes, with no alert. When the ticket
///    was written it showed "can't save a PDF document from a private window"; DEV-971 replaced
///    that alert with the save. The remembered folder is checked again.
///
/// It prints `ARX_HAND_CHECK_PRIVATE_SAVE_FILE path=…` for each saved file; once Arx has quit, the
/// runner reads `defaults read dev.capturecontext.arx.dev NSOSPLastRootDirectory` and
/// `xattr -l` on each file for `kMDItemWhereFroms`.
@MainActor
internal enum PrivateSaveSmoke {
	internal static let folderKey: String = "ARX_HAND_CHECK_PRIVATE_FOLDER"
	private static let appKitKey: String = "NSOSPLastRootDirectory"

	/// Longer than `PrivateSaveFolder`'s watch on AppKit's folder after a private panel closes.
	private static let settleTime: Duration = .seconds(12)

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		baseURL: URL,
		environment: [String: String]
	) async throws {
		guard let path = environment[folderKey], !path.isEmpty
		else { throw HandCheckSmoke.Failure("\(folderKey) is missing") }

		guard let digest = environment["ARX_HAND_CHECK_PDF_SHA256"], !digest.isEmpty
		else { throw HandCheckSmoke.Failure("ARX_HAND_CHECK_PDF_SHA256 is missing") }

		let folder = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
		guard (try? folder.checkResourceIsReachable()) == true, (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true
		else { throw HandCheckSmoke.Failure("\(folder.path) must be a new, empty folder") }

		let root = baseURL.deletingLastPathComponent()
		let page = root.appending(path: "article.html")
		let document = root.appending(path: "document.pdf")

		// A private window on the article.
		let preparation = store.send(.ui(.newPrivateWindow))
		defer { preparation.cancel() }
		try await HandCheckSmoke.wait("private window") { store.windows.contains(where: \.isPrivate) }
		guard let windowID = store.windows.first(where: \.isPrivate)?.id else { throw HandCheckSmoke.Failure("no private window") }
		try await HandCheckSmoke.wait("private command bar") { store.windows[id: windowID]?.commandBar.isPresented == true }
		store.send(.windows(.element(id: windowID, action: .commandBar(.ui(.queryChanged(page.absoluteString))))))
		store.send(.windows(.element(id: windowID, action: .commandBar(.ui(.selected("destination"))))))

		// The engine's page, not only the viewer: a new tab's viewer starts from its saved address,
		// not loading, before the engine has made its page, and Save Page As needs the page's
		// document.
		try await HandCheckSmoke.wait("private page", seconds: 20, context: {
			let item = store.windows[id: windowID]?.viewer.item
			let snapshot = item?.tab.flatMap { engine.client.snapshot($0.id) }
			return "viewer=\(item?.navigation.url?.absoluteString ?? "nil") loading=\(item?.navigation.isLoading ?? false)"
				+ " engine=\(snapshot?.navigation.url?.absoluteString ?? "none") document=\(snapshot?.documentRevision.map(String.init) ?? "nil")"
		}) {
			guard
				let item = store.windows[id: windowID]?.viewer.item,
				let tab = item.tab,
				let snapshot = engine.client.snapshot(tab.id)
			else { return false }
			return item.navigation.url == page && !item.navigation.isLoading
				&& snapshot.navigation.url == page && !snapshot.navigation.isLoading && snapshot.documentRevision != nil
		}
		guard let tab = store.windows[id: windowID]?.viewer.item.tab?.id else { throw HandCheckSmoke.Failure("no private tab") }

		// 1. The page menu.
		let commands = store.state.pageMenuCommands(showing: tab)
		guard commands.contains(.savePageAs), commands.contains(.printPage)
		else { throw HandCheckSmoke.Failure("the private page menu has \(commands.map(\.rawValue).sorted())") }
		print("ARX_HAND_CHECK_PRIVATE_SAVE_MENU saveAs=on print=on")

		// 2. Save Page As, HTML only, into the new folder.
		let html = try await save(
			store: store,
			engine: engine,
			target: .window(windowID),
			into: folder,
			name: "private-page.html",
			format: .htmlOnly,
			opensInFolder: false
		)
		print("ARX_HAND_CHECK_PRIVATE_SAVE_FILE path=\(html.path)")

		// 3. AppKit's remembered folder.
		try await Task.sleep(for: settleTime)
		try expectNotRemembered(folder, step: "after the private save")

		// 4. An ordinary window's panel opens elsewhere.
		store.send(.ui(.openURLInSpace(page, store.main.sidebar.spaceID, .mainBrowser)))
		try await HandCheckSmoke.wait("ordinary page") {
			store.main.viewer.item.navigation.url == page && !store.main.viewer.item.navigation.isLoading
		}
		store.send(.ui(.command(.savePageAs, .window(store.main.id))))
		let ordinary = try await panel()
		let opened = ordinary.directoryURL.map(real)
		ordinary.cancel(nil)
		try await HandCheckSmoke.wait("ordinary panel closed") { !ordinary.isVisible }
		guard opened != folder else { throw HandCheckSmoke.Failure("the ordinary save panel opened in the private folder") }
		print("ARX_HAND_CHECK_PRIVATE_SAVE_ORDINARY opened=\(opened?.path ?? "nil")")

		// 5. A PDF document in the private window.
		try await engine.client.command(tab, .navigate(document))
		try await HandCheckSmoke.wait("private PDF", seconds: 20) {
			guard let navigation = store.windows[id: windowID]?.viewer.item.navigation else { return false }
			return navigation.url == document && !navigation.isLoading
		}
		let pdf = try await save(
			store: store,
			engine: engine,
			target: .window(windowID),
			into: folder,
			name: "private-document.pdf",
			format: .pdf,
			opensInFolder: true
		)
		guard Self.digest(try Data(contentsOf: pdf)) == digest
		else { throw HandCheckSmoke.Failure("the saved PDF isn't the document's own bytes") }
		print("ARX_HAND_CHECK_PRIVATE_SAVE_FILE path=\(pdf.path)")
		try await Task.sleep(for: settleTime)
		try expectNotRemembered(folder, step: "after the private PDF")

		store.send(.ui(.requestClosePrivateWindow(windowID)))
		try await HandCheckSmoke.wait("private window closed") { store.windows[id: windowID] == nil }
		print(HandCheckSmoke.Phase.privateSave.successMarker)
	}

	/// The SHA-256 of `data`, in lowercase hex, as the runner names the fixture PDF's.
	internal static func digest(_ data: Data) -> String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}

	/// A folder by its real path: the runner's may be under a symlink, and AppKit reports real ones.
	private static func real(_ url: URL) -> URL {
		url.standardizedFileURL.resolvingSymlinksInPath()
	}

	/// Whether AppKit's remembered folder, a bookmark, resolves to `folder` or into it.
	internal static func remembers(
		_ folder: URL,
		bookmark: Data?
	) -> Bool {
		guard let bookmark else { return false }
		var stale = false
		let resolved = try? URL(
			resolvingBookmarkData: bookmark,
			options: [.withoutUI, .withoutMounting],
			relativeTo: nil,
			bookmarkDataIsStale: &stale
		)
		guard let resolved else {
			// A bookmark that no longer resolves still names its path in its bytes.
			return bookmark.range(of: Data(folder.lastPathComponent.utf8)) != nil
		}
		let target = folder.standardizedFileURL.resolvingSymlinksInPath().path
		let path = resolved.standardizedFileURL.resolvingSymlinksInPath().path
		return path == target || path.hasPrefix(target + "/")
	}

	private static func expectNotRemembered(
		_ folder: URL,
		step: String
	) throws {
		UserDefaults.standard.synchronize()
		let bookmark = UserDefaults.standard.data(forKey: appKitKey)
		guard !remembers(folder, bookmark: bookmark)
		else { throw HandCheckSmoke.Failure("\(step): \(appKitKey) names the private folder") }
		print("ARX_HAND_CHECK_PRIVATE_SAVE_DEFAULTS \(step.replacingOccurrences(of: " ", with: "-")) remembered=\(bookmark == nil ? "nothing" : "elsewhere")")
	}

	/// Saves the page `target` shows through the real save panel, and waits for the file.
	/// `opensInFolder`: whether the panel must open in `folder`, the last private folder, kept in
	/// memory, or must not, as a first private panel never knew it.
	private static func save(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		target: AppFeature.CommandTarget,
		into folder: URL,
		name: String,
		format: PageSaveFormat,
		opensInFolder: Bool
	) async throws -> URL {
		print("ARX_HAND_CHECK_PRIVATE_SAVE_SOURCE \(name) \(describeSource(store: store, engine: engine, target: target))")
		store.send(.ui(.command(.savePageAs, target)))
		let panel = try await panel()
		let opened = panel.directoryURL.map(real)
		guard (opened == folder) == opensInFolder
		else { throw HandCheckSmoke.Failure("\(name): the panel opened in \(opened?.path ?? "nil"), expected \(opensInFolder ? "" : "not ")\(folder.path)") }

		// The Format menu, when there's more than one format.
		if let picker = panel.accessoryView.flatMap({ HandCheckSmoke.views(under: $0).compactMap { $0 as? NSPopUpButton }.first }) {
			guard let index = picker.itemTitles.firstIndex(of: format.title)
			else { throw HandCheckSmoke.Failure("the Format menu has \(picker.itemTitles), not \(format.title)") }
			picker.selectItem(at: index)
			picker.sendAction(picker.action, to: picker.target)
		} else {
			guard panel.allowedContentTypes == [format.contentType]
			else { throw HandCheckSmoke.Failure("the panel saves \(panel.allowedContentTypes), not \(format.title)") }
		}

		// The panel is driven as a person drives it, with keys posted to the system's event
		// stream. macOS 27 draws it in another process: a folder or a name set on `NSSavePanel`
		// once it's open never gets there (it saved the page's title into Documents), its
		// `ok(_:)` throws "not implemented", and keys made in the app or posted to Arx's own
		// process don't reach it (22 Nov). Posting needs the Mac's permission for Arx Dev to
		// control the computer (Privacy & Security > Accessibility), as the Hide Element toast
		// phase's mouse does.
		NSApplication.shared.activate()
		panel.makeKeyAndOrderFront(nil)
		try await HandCheckSmoke.wait("save panel key", context: {
			"active=\(NSApplication.shared.isActive) key=\(panel.isKeyWindow)"
		}) { NSApplication.shared.isActive && panel.isKeyWindow }
		let posts = CGPreflightPostEventAccess()
		guard posts else { throw HandCheckSmoke.Failure("\(name): Arx Dev may not post keys (Privacy & Security > Accessibility)") }

		// Shift-Command-G, the folder's path, Return: Go to Folder.
		try await Task.sleep(for: .milliseconds(500))
		try await press(5, flags: [.maskCommand, .maskShift])
		try await Task.sleep(for: .seconds(1))
		try await typeText(folder.path)
		try await Task.sleep(for: .seconds(1))
		try await press(36)
		try await Task.sleep(for: .seconds(1))

		// The name field has the keyboard again: Command-A, the name, Return.
		try await press(0, flags: .maskCommand)
		try await typeText(name)

		// Return only once the panel reports the folder and the name, so a key that went astray
		// never saves the page somewhere else.
		do {
			try await HandCheckSmoke.wait("panel in the new folder", context: {
				"folder=\(panel.directoryURL?.path ?? "nil") name=\(panel.nameFieldStringValue)"
			}) { panel.directoryURL.map(real) == folder && panel.nameFieldStringValue == name }
		} catch {
			panel.cancel(nil)
			throw error
		}
		print("ARX_HAND_CHECK_PRIVATE_SAVE_CONFIRM \(name) folder=\(panel.directoryURL?.path ?? "nil")")
		try await press(36)

		let file = folder.appending(path: name)
		try await HandCheckSmoke.wait("\(name) written", seconds: 20, context: {
			"postAccess=\(posts) active=\(NSApplication.shared.isActive) key=\(panel.isKeyWindow) "
				+ "panel=\(panel.isVisible) folder=\((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []) "
				+ alertText()
		}) {
			((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 && !panel.isVisible
		}
		if let alert = NSApp.windows.first(where: { $0.isVisible && $0.className.contains("Alert") }) {
			throw HandCheckSmoke.Failure("an alert showed: \(alertText()) (\(alert.title))")
		}
		return file
	}

	/// A key press as the keyboard sends it, to whatever has the keyboard.
	private static func press(
		_ code: CGKeyCode,
		flags: CGEventFlags = [],
		text: String? = nil
	) async throws {
		let source = CGEventSource(stateID: .hidSystemState)
		for down in [true, false] {
			guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
			else { throw HandCheckSmoke.Failure("no key event") }

			event.flags = flags
			if let text {
				let units = Array(text.utf16)
				event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
			}
			event.post(tap: .cghidEventTap)
			try await Task.sleep(for: .milliseconds(15))
		}
	}

	/// Types `text`, a character per key press.
	private static func typeText(_ text: String) async throws {
		for character in text {
			try await press(0, text: String(character))
		}
	}

	/// The save panel that opened, once it's on screen.
	private static func panel() async throws -> NSSavePanel {
		var found: NSSavePanel?
		try await HandCheckSmoke.wait("save panel", seconds: 20, context: {
			let windows = NSApp.windows.map { "\(type(of: $0))\($0.isVisible ? "+" : "-")\($0.attachedSheet.map { "[\(type(of: $0))]" } ?? "")" }
			return alertText() + " windows=\(windows.joined(separator: ","))"
		}) {
			found = NSApp.windows.lazy.compactMap { $0 as? NSSavePanel }.first { $0.isVisible && !($0 is NSOpenPanel) }
			return found != nil
		}
		guard let found else { throw HandCheckSmoke.Failure("no save panel") }
		return found
	}

	/// What Save Page As starts from: the page the command reaches, whether it's a web page, and
	/// the engine's document for it, without which the save returns before its panel.
	private static func describeSource(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		target: AppFeature.CommandTarget
	) -> String {
		guard let source = store.state.captureSource(for: target) else { return "source=nil" }
		let viewer = store.state.captureViewer(for: source)
		let snapshot = engine.client.snapshot(source.tabID)
		return "viewer=\(viewer != nil) web=\(viewer?.navigation.showsWebPage ?? false)"
			+ " engine=\(String(describing: viewer?.navigation.engine)) snapshot=\(snapshot != nil)"
			+ " document=\(snapshot?.documentRevision.map(String.init) ?? "nil")"
			+ " view=\(engine.pageViewSize(source.tabID).map { "\($0)" } ?? "nil") tab=\(source.tabID.rawValue) profile=\(source.profileID.rawValue)"
			+ " main=\(store.main.viewer.item.tab.map { engine.client.snapshot($0.id) != nil } ?? false)"
	}

	private static func alertText() -> String {
		NSApp.windows.filter(\.isVisible)
			.flatMap { window in window.contentView.map(HandCheckSmoke.views(under:)) ?? [] }
			.compactMap { ($0 as? NSTextField)?.stringValue }
			.filter { !$0.isEmpty }
			.prefix(4)
			.joined(separator: " | ")
	}
}
#endif
