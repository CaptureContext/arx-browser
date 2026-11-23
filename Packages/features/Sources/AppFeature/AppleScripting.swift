import AppKit
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import _ComposableArchitecture

/// Arx's AppleScript dictionary (DEV-909, `Containers/macOS/Arx.sdef`): windows, spaces,
/// profiles and tabs, read from the store when a script asks, and commands that go through the
/// same actions as the menus and `arx://` links. A headless run never connects, so scripts see
/// no elements and every command fails there. Private windows and their tabs are never listed.
/// `execute` runs JavaScript only while developer mode and its AppleScript switch are on.
@MainActor
internal enum AppleScriptBridge {
	fileprivate static weak var store: StoreOf<AppFeature>?
	private static var currentURL: @MainActor (BrowserCore.Tab.ID) -> URL? = { _ in nil }
	private static var engine: BrowserEngineClient?

	/// `currentURL` is a loaded tab's live address, which can be newer than the one it saves.
	/// `engine` runs `execute`'s JavaScript.
	internal static func connect(
		_ store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		currentURL: @escaping @MainActor (BrowserCore.Tab.ID) -> URL?
	) {
		self.store = store
		self.engine = engine
		self.currentURL = currentURL
	}

	/// Why `execute` may not run in the tab now, or nil when it may (DEV-909): developer mode
	/// and its AppleScript switch are on and the tab is an ordinary one. Private windows' tabs
	/// are never in the workspace, and a headless run never connects.
	internal static func javaScriptRefusal(
		for id: BrowserCore.Tab.ID,
		in state: AppFeature.State
	) -> String? {
		let general = state.settings.general
		guard general.developerModeEnabled, general.appleScriptJavaScriptEnabled else {
			return "JavaScript from AppleScript is off. Turn on developer mode and Allow JavaScript from AppleScript in Arx's Settings › Developer."
		}
		guard state.workspace.tabs[id: id] != nil else { return "That tab isn't open in Arx." }
		return nil
	}

	/// The script's result as JSON text, nil for undefined, or why it didn't run.
	fileprivate static func execute(
		_ script: String,
		in id: BrowserCore.Tab.ID
	) async -> Result<String?, ScriptFailure> {
		guard let store, let engine else { return .failure(.init("Arx isn't open in a window.")) }
		if let refusal = javaScriptRefusal(for: id, in: store.state) { return .failure(.init(refusal)) }

		do throws(BrowserDeveloperFailure) {
			guard engine.developerTierIsAvailable() else { throw .unavailable }

			// Checked again as the script goes in: the switch or the tab may have changed.
			let outcome = try await engine.evaluateScript(id, script, Self.resultLimit, 10_000) { [weak store] in
				guard let store else { return false }
				return javaScriptRefusal(for: id, in: store.state) == nil
			}
			switch outcome {
			case let .value(json): return .success(json)
			case .undefined: return .success(nil)
			case let .unserializable(description): return .success(description)
			case let .exception(name, message): return .failure(.init("\(name): \(message)"))
			case let .syntaxError(name, message, _): return .failure(.init("\(name): \(message)"))
			}
		} catch {
			return .failure(.init(Self.message(for: error)))
		}
	}

	/// The engine's largest result (`ChromiumDevelopers.evaluate`).
	internal static let resultLimit: Int = 262_144

	private static func message(for failure: BrowserDeveloperFailure) -> String {
		switch failure {
		case .unavailable: "Arx can't run JavaScript in this tab."
		case .unsupported: "The tab doesn't show a web page."
		case .stale: "The tab navigated or closed."
		case .busy: "Another script is running in the tab."
		case .timedOut: "The script didn't finish within 10 seconds."
		case .limitExceeded: "The script's result is larger than 256 KB."
		default: "The script couldn't run."
		}
	}

	internal struct ScriptFailure: Error {
		internal let message: String

		internal init(_ message: String) {
			self.message = message
		}
	}

	/// What scripts see, in a form tests can read without AppKit's scripting machinery.
	internal static func snapshot(
		of state: AppFeature.State,
		currentURL: (BrowserCore.Tab.ID) -> URL? = { _ in nil }
	) -> ScriptSnapshot {
		let organization = state.workspace
		let locations = organization.tabLocations
		var hosts: [(id: UUID, window: MainFeatureWindow)] = []
		if state.windowIsOpen { hosts.append((state.main.id, .init(state.main))) }
		for window in state.windows where !window.isPrivate { hosts.append((window.id, .init(window))) }

		// The focused window first, as AppleScript counts windows from the front.
		if let focused = state.focusedWindowID, let index = hosts.firstIndex(where: { $0.id == focused }) {
			hosts.insert(hosts.remove(at: index), at: 0)
		}
		let activeTabs = Set(hosts.compactMap(\.window.activeTabID))

		let tabs = organization.tabs.compactMap { tab -> ScriptSnapshot.Tab? in
			let spaceID: Space.ID?
			let isPinned: Bool
			switch locations[tab.id] {
			case let .unpinned(id): spaceID = id; isPinned = false
			case let .pinned(id, _): spaceID = id; isPinned = true
			case .favorite: spaceID = nil; isPinned = true
			case nil: return nil
			}
			return .init(
				id: tab.id.rawValue.uuidString,
				title: tab.displayTitle,
				address: (currentURL(tab.id) ?? tab.restoration.url).absoluteString,
				spaceName: spaceID.flatMap { organization.spaces[id: $0]?.name } ?? "",
				profileName: organization.profiles[id: tab.profileID]?.name ?? "",
				isPinned: isPinned,
				isActive: activeTabs.contains(tab.id)
			)
		}
		return .init(
			windows: hosts.map { host in
				.init(
					id: host.id.uuidString,
					spaceName: organization.spaces[id: host.window.spaceID]?.name ?? "",
					activeTabID: host.window.activeTabID?.rawValue.uuidString
				)
			},
			spaces: organization.spaces.map { space in
				.init(
					id: space.id.rawValue.uuidString,
					name: space.name,
					profileName: organization.profiles[id: space.profileID]?.name ?? ""
				)
			},
			profiles: organization.profiles.map { .init(id: $0.id.rawValue.uuidString, name: $0.name) },
			tabs: tabs
		)
	}

	fileprivate static var current: ScriptSnapshot? {
		store.map { snapshot(of: $0.state, currentURL: currentURL) }
	}

	fileprivate static func send(_ action: AppFeature.Action) -> Bool {
		guard let store else { return false }
		store.send(action)
		return true
	}
}

/// The window facts a script reads.
internal struct MainFeatureWindow {
	internal let spaceID: Space.ID
	internal let activeTabID: BrowserCore.Tab.ID?

	internal init(_ window: MainFeature.State) {
		self.spaceID = window.sidebar.spaceID
		self.activeTabID = window.viewer.item.tab?.id
	}
}

internal struct ScriptSnapshot: Equatable {
	internal struct Window: Equatable {
		internal let id: String
		internal let spaceName: String
		internal let activeTabID: String?
	}

	internal struct Space: Equatable {
		internal let id: String
		internal let name: String
		internal let profileName: String
	}

	internal struct Profile: Equatable {
		internal let id: String
		internal let name: String
	}

	internal struct Tab: Equatable {
		internal let id: String
		internal let title: String
		internal let address: String
		internal let spaceName: String
		internal let profileName: String
		internal let isPinned: Bool
		internal let isActive: Bool
	}

	internal let windows: [Window]
	internal let spaces: [Space]
	internal let profiles: [Profile]
	internal let tabs: [Tab]
}

// MARK: - Scripting objects

private func specifier(
	key: String,
	id: String
) -> NSScriptObjectSpecifier? {
	guard let description = NSScriptClassDescription(for: NSApplication.self) else { return nil }
	return NSUniqueIDSpecifier(containerClassDescription: description, containerSpecifier: nil, key: key, uniqueID: id)
}

@objc(ArxScriptWindow)
internal final class ArxScriptWindow: NSObject, @unchecked Sendable {
	// Immutable once made; scripts read them on the main thread.
	@objc
	internal let uniqueID: String

	@objc
	internal let spaceName: String

	@objc
	internal let orderIndex: Int

	private let activeTabID: String?

	fileprivate init(
		_ window: ScriptSnapshot.Window,
		index: Int
	) {
		self.uniqueID = window.id
		self.spaceName = window.spaceName
		self.orderIndex = index
		self.activeTabID = window.activeTabID
	}

	@objc
	internal var activeTab: ArxScriptTab? {
		MainActor.assumeIsolated {
			guard let id = activeTabID, let tab = AppleScriptBridge.current?.tabs.first(where: { $0.id == id })
			else { return nil }
			return ArxScriptTab(tab)
		}
	}

	internal override var objectSpecifier: NSScriptObjectSpecifier? {
		specifier(key: "arxScriptWindows", id: uniqueID)
	}
}

@objc(ArxScriptSpace)
internal final class ArxScriptSpace: NSObject, @unchecked Sendable {
	// Immutable once made; scripts read them on the main thread.
	@objc
	internal let uniqueID: String

	@objc
	internal let name: String

	@objc
	internal let profileName: String

	fileprivate init(_ space: ScriptSnapshot.Space) {
		self.uniqueID = space.id
		self.name = space.name
		self.profileName = space.profileName
	}

	internal override var objectSpecifier: NSScriptObjectSpecifier? {
		specifier(key: "arxScriptSpaces", id: uniqueID)
	}
}

@objc(ArxScriptProfile)
internal final class ArxScriptProfile: NSObject, @unchecked Sendable {
	// Immutable once made; scripts read them on the main thread.
	@objc
	internal let uniqueID: String

	@objc
	internal let name: String

	fileprivate init(_ profile: ScriptSnapshot.Profile) {
		self.uniqueID = profile.id
		self.name = profile.name
	}

	internal override var objectSpecifier: NSScriptObjectSpecifier? {
		specifier(key: "arxScriptProfiles", id: uniqueID)
	}
}

@objc(ArxScriptTab)
internal final class ArxScriptTab: NSObject, @unchecked Sendable {
	// Immutable once made; scripts read them on the main thread.
	@objc
	internal let uniqueID: String

	@objc
	internal let title: String

	@objc
	internal let address: String

	@objc
	internal let spaceName: String

	@objc
	internal let profileName: String

	@objc
	internal let isPinned: Bool

	@objc
	internal let isActive: Bool

	fileprivate init(_ tab: ScriptSnapshot.Tab) {
		self.uniqueID = tab.id
		self.title = tab.title
		self.address = tab.address
		self.spaceName = tab.spaceName
		self.profileName = tab.profileName
		self.isPinned = tab.isPinned
		self.isActive = tab.isActive
	}

	internal override var objectSpecifier: NSScriptObjectSpecifier? {
		specifier(key: "arxScriptTabs", id: uniqueID)
	}

	@objc
	internal func handleShowCommand(_ command: NSScriptCommand) -> Any? {
		perform(.show, command)
	}

	@objc
	internal func handleReloadCommand(_ command: NSScriptCommand) -> Any? {
		perform(.reload, command)
	}

	@objc
	internal func handleCloseCommand(_ command: NSScriptCommand) -> Any? {
		perform(.close, command)
	}

	/// `execute javascript` (DEV-909): suspends the script until the page answers.
	@objc
	internal func handleExecuteCommand(_ command: NSScriptCommand) -> Any? {
		guard
			let id = UUID(uuidString: uniqueID),
			let script = command.evaluatedArguments?["javascript"] as? String,
			!script.isEmpty
		else {
			command.scriptErrorNumber = errAEParamMissed
			command.scriptErrorString = "execute needs JavaScript to run."
			return nil
		}

		nonisolated(unsafe) let command = command
		MainActor.assumeIsolated {
			command.suspendExecution()
			Task { @MainActor in
				switch await AppleScriptBridge.execute(script, in: .init(rawValue: id)) {
				case let .success(result):
					command.resumeExecution(withResult: result)
				case let .failure(failure):
					command.scriptErrorNumber = errAEEventFailed
					command.scriptErrorString = failure.message
					command.resumeExecution(withResult: nil)
				}
			}
		}
		return nil
	}

	private func perform(
		_ action: ScriptTabAction,
		_ command: NSScriptCommand
	) -> Any? {
		let id = UUID(uuidString: uniqueID)
		let sent = MainActor.assumeIsolated {
			id.map { AppleScriptBridge.send(.ui(.scriptTab(.init(rawValue: $0), action))) } ?? false
		}
		if !sent {
			command.scriptErrorNumber = errAEEventFailed
			command.scriptErrorString = "Arx isn't open in a window."
		}
		return nil
	}
}

/// What a script asks of one tab.
public enum ScriptTabAction: Equatable, Sendable {
	case show
	case reload
	case close
}

@objc(ArxOpenPageScriptCommand)
internal final class ArxOpenPageScriptCommand: NSScriptCommand {
	internal override func performDefaultImplementation() -> Any? {
		let arguments = evaluatedArguments ?? [:]
		guard
			let text = directParameter as? String,
			let url = URL(string: text, encodingInvalidCharacters: false),
			["http", "https"].contains(url.scheme?.lowercased() ?? "")
		else {
			scriptErrorNumber = errAEParamMissed
			scriptErrorString = "Arx opens only web pages (http or https)."
			return nil
		}

		let space = arguments["space"] as? String
		let command: ArxURLCommand = (arguments["little"] as? Bool) == true
		? .littleArx(url, space: space)
		: .open(url, space: space, profile: arguments["profile"] as? String)
		if !MainActor.assumeIsolated({ AppleScriptBridge.send(.ui(.arxURLCommand(command))) }) {
			scriptErrorNumber = errAEEventFailed
			scriptErrorString = "Arx isn't open in a window."
		}
		return nil
	}
}

@objc(ArxSwitchSpaceScriptCommand)
internal final class ArxSwitchSpaceScriptCommand: NSScriptCommand {
	internal override func performDefaultImplementation() -> Any? {
		guard let name = directParameter as? String else {
			scriptErrorNumber = errAEParamMissed
			return nil
		}
		if !MainActor.assumeIsolated({ AppleScriptBridge.send(.ui(.arxURLCommand(.switchSpace(name)))) }) {
			scriptErrorNumber = errAEEventFailed
			scriptErrorString = "Arx isn't open in a window."
		}
		return nil
	}
}

/// The application's elements, for Cocoa Scripting's key-value lookups (`Arx.sdef`).
extension NSApplication {
	@objc
	internal var arxScriptWindows: [ArxScriptWindow] {
		(AppleScriptBridge.current?.windows ?? []).enumerated().map { ArxScriptWindow($1, index: $0 + 1) }
	}

	@objc
	internal var arxScriptSpaces: [ArxScriptSpace] {
		(AppleScriptBridge.current?.spaces ?? []).map(ArxScriptSpace.init)
	}

	@objc
	internal var arxScriptProfiles: [ArxScriptProfile] {
		(AppleScriptBridge.current?.profiles ?? []).map(ArxScriptProfile.init)
	}

	@objc
	internal var arxScriptTabs: [ArxScriptTab] {
		(AppleScriptBridge.current?.tabs ?? []).map(ArxScriptTab.init)
	}
}

/// A script's `show tab`, `reload tab` and `close tab` (DEV-909).
@Reducer
internal struct ScriptedTabs {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.scriptTab) { state, value in
			let (id, action) = value
			guard
				!state.shouldQuit,
				!state.checkingQuit,
				let tab = state.workspace.tabs[id: id]
			else { return .none }

			switch action {
			case .show:
				// The same path a site's own focus() takes during a notification click.
				return .send(.event(.pageActivationRequested(id)))

			case .reload:
				return .run { @MainActor [engine] _ in
					try? await engine.command(id, .reload)
				}

			case .close:
				// Into the Tab Archive from a window on the tab's profile; pinned tabs and
				// Favorites stay.
				guard case let .unpinned(spaceID) = state.workspace.tabLocations[id]
				else { return .none }

				let action = MainFeature.Action.ui(.archiveSelectedTabs([id]))
				if state.windowIsOpen, state.main.sidebar.space.profileID == tab.profileID {
					return .send(.main(action))
				}
				if let window = state.windows.first(where: {
					!$0.isPrivate && $0.sidebar.space.profileID == tab.profileID
				}) {
					return .send(.windows(.element(id: window.id, action: action)))
				}

				// No window shows the profile: the main window, open or not, turns to the tab's
				// space and archives it from there.
				return .concatenate(
					.send(.main(.sidebar(.ui(.spaceSelected(spaceID))))),
					.send(.main(action))
				)
			}
		}
	}
}
