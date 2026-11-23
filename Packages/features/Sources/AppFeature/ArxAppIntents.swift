import AppIntents
import BrowserCore
import Foundation
import _ComposableArchitecture

/// The Shortcuts app's actions for Arx (DEV-929): open a page in a space or profile, open
/// Little Arx, switch space, and read the front page. They run in the running Arx and go
/// through the same commands as `arx://` addresses. A headless run never connects, so they
/// fail there instead of driving a browser nobody sees.
@MainActor
internal enum AppIntentsBridge {
	private static weak var store: StoreOf<AppFeature>?

	internal static func connect(_ store: StoreOf<AppFeature>) {
		self.store = store
	}

	fileprivate static func perform(_ command: ArxURLCommand) throws {
		guard let store else { throw ArxIntentError.notRunning }
		store.send(.ui(.arxURLCommand(command)))
	}

	fileprivate static var workspace: BrowserOrganization? { store?.workspace }

	/// The front ordinary window's page, as Handoff offers it.
	fileprivate static var currentPage: (url: URL, title: String)? {
		guard let store else { return nil }

		let state = store.state
		let id = state.focusedWindowID ?? state.main.id
		let navigation: BrowserNavigation?
		if id == state.main.id {
			navigation = state.windowIsOpen ? state.main.viewer.item.navigation : nil
		} else if let window = state.windows[id: id] {
			navigation = window.isPrivate ? nil : window.viewer.item.navigation
		} else {
			navigation = state.littleWindows[id: id]?.viewer.navigation
		}
		guard let navigation, let url = navigation.url else { return nil }
		return (url, navigation.title)
	}
}

internal enum ArxIntentError: Error, CustomLocalizedStringResourceConvertible {
	case notRunning
	case notWebPage
	case noPage

	internal var localizedStringResource: LocalizedStringResource {
		switch self {
		case .notRunning: "Arx isn't open in a window."
		case .notWebPage: "Arx opens only web pages (http or https)."
		case .noPage: "Arx's front window shows no page."
		}
	}
}

// MARK: - Entities

internal struct SpaceEntity: AppEntity {
	internal static let typeDisplayRepresentation: TypeDisplayRepresentation = "Space"
	internal static let defaultQuery: SpaceQuery = .init()

	internal let id: UUID
	internal let name: String
	internal let profileName: String

	internal init(
		id: UUID,
		name: String,
		profileName: String
	) {
		self.id = id
		self.name = name
		self.profileName = profileName
	}

	internal var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)", subtitle: "\(profileName)")
	}
}

internal struct SpaceQuery: EntityQuery {
	internal init() {}

	@MainActor
	internal func entities(for identifiers: [UUID]) async throws -> [SpaceEntity] {
		try await suggestedEntities().filter { identifiers.contains($0.id) }
	}

	@MainActor
	internal func suggestedEntities() async throws -> [SpaceEntity] {
		guard let workspace = AppIntentsBridge.workspace else { return [] }
		return workspace.spaces.map { space in
			SpaceEntity(
				id: space.id.rawValue,
				name: space.name,
				profileName: workspace.profiles[id: space.profileID]?.name ?? ""
			)
		}
	}
}

internal struct ProfileEntity: AppEntity {
	internal static let typeDisplayRepresentation: TypeDisplayRepresentation = "Profile"
	internal static let defaultQuery: ProfileQuery = .init()

	internal let id: UUID
	internal let name: String

	internal init(
		id: UUID,
		name: String
	) {
		self.id = id
		self.name = name
	}

	internal var displayRepresentation: DisplayRepresentation {
		DisplayRepresentation(title: "\(name)")
	}
}

internal struct ProfileQuery: EntityQuery {
	internal init() {}

	@MainActor
	internal func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
		try await suggestedEntities().filter { identifiers.contains($0.id) }
	}

	@MainActor
	internal func suggestedEntities() async throws -> [ProfileEntity] {
		AppIntentsBridge.workspace?.profiles.map { ProfileEntity(id: $0.id.rawValue, name: $0.name) } ?? []
	}
}

// MARK: - Actions

internal struct OpenPageIntent: AppIntent {
	internal static let title: LocalizedStringResource = "Open Page in Arx"
	internal static let description: IntentDescription = .init(
		"Opens a web page in a space or profile you choose, else where Air Traffic Control sends it."
	)
	internal static let openAppWhenRun: Bool = true

	@Parameter(title: "Page")
	internal var url: URL

	@Parameter(title: "Space")
	internal var space: SpaceEntity?

	@Parameter(title: "Profile")
	internal var profile: ProfileEntity?

	internal init() {}

	@MainActor
	internal func perform() async throws -> some IntentResult {
		guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
		else { throw ArxIntentError.notWebPage }

		try AppIntentsBridge.perform(.open(
			url,
			space: space?.id.uuidString,
			profile: profile?.id.uuidString
		))
		return .result()
	}
}

internal struct OpenLittleArxIntent: AppIntent {
	internal static let title: LocalizedStringResource = "Open Little Arx"
	internal static let description: IntentDescription = .init("Opens a Little Arx window, with a page if you give one.")
	internal static let openAppWhenRun: Bool = true

	@Parameter(title: "Page")
	internal var url: URL?

	@Parameter(title: "Space")
	internal var space: SpaceEntity?

	internal init() {}

	@MainActor
	internal func perform() async throws -> some IntentResult {
		if let url, !["http", "https"].contains(url.scheme?.lowercased() ?? "") {
			throw ArxIntentError.notWebPage
		}
		try AppIntentsBridge.perform(.littleArx(url, space: space?.id.uuidString))
		return .result()
	}
}

internal struct SwitchSpaceIntent: AppIntent {
	internal static let title: LocalizedStringResource = "Switch Arx Space"
	internal static let description: IntentDescription = .init("Shows a space in Arx's main window.")
	internal static let openAppWhenRun: Bool = true

	@Parameter(title: "Space")
	internal var space: SpaceEntity

	internal init() {}

	@MainActor
	internal func perform() async throws -> some IntentResult {
		try AppIntentsBridge.perform(.switchSpace(space.id.uuidString))
		return .result()
	}
}

internal struct GetCurrentPageIntent: AppIntent {
	internal static let title: LocalizedStringResource = "Get Current Arx Page"
	internal static let description: IntentDescription = .init(
		"The address and title of the page in Arx's front window. Private windows give nothing."
	)

	internal init() {}

	@MainActor
	internal func perform() async throws -> some IntentResult & ReturnsValue<URL> & ProvidesDialog {
		guard AppIntentsBridge.workspace != nil else { throw ArxIntentError.notRunning }
		guard let page = AppIntentsBridge.currentPage else { throw ArxIntentError.noPage }
		return .result(value: page.url, dialog: "\(page.title)")
	}
}

/// The actions the Shortcuts app and Spotlight list for Arx with its icon.
internal struct ArxShortcuts: AppShortcutsProvider {
	internal static var appShortcuts: [AppShortcut] {
		AppShortcut(
			intent: OpenPageIntent(),
			phrases: ["Open a page in \(.applicationName)"],
			shortTitle: "Open Page",
			systemImageName: "safari"
		)
		AppShortcut(
			intent: OpenLittleArxIntent(),
			phrases: ["Open Little \(.applicationName)"],
			shortTitle: "Little Arx",
			systemImageName: "macwindow"
		)
		AppShortcut(
			intent: SwitchSpaceIntent(),
			phrases: ["Switch \(.applicationName) space"],
			shortTitle: "Switch Space",
			systemImageName: "square.stack"
		)
		AppShortcut(
			intent: GetCurrentPageIntent(),
			phrases: ["Get the current \(.applicationName) page"],
			shortTitle: "Current Page",
			systemImageName: "link"
		)
	}
}

/// Lets the app target include these actions in its App Intents metadata.
public struct AppFeatureIntents: AppIntentsPackage {}
