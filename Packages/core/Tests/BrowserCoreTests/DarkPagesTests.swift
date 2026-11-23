import BrowserCore
import Foundation
import Testing

/// DEV-1020: when pages are darkened, and the sites a profile keeps as they are.
internal struct DarkPagesTests {
	@Test
	internal func theModeFollowsTheWindowsOnlyWithTheTheme() async throws {
		#expect(!DarkPagesMode.off.isActive(appearanceIsDark: true))
		#expect(DarkPagesMode.withTheme.isActive(appearanceIsDark: true))
		#expect(!DarkPagesMode.withTheme.isActive(appearanceIsDark: false))
		#expect(DarkPagesMode.always.isActive(appearanceIsDark: false))
	}

	@Test
	internal func aConfigurationCarriesEachProfilesSitesOnlyWhileActive() async throws {
		let work: Profile = .init(id: .init(rawValue: UUID()), name: "Work", darkPagesOffSites: ["figma.com"])
		let home: Profile = .init(id: .init(rawValue: UUID()), name: "Home")

		let active: DarkPagesConfiguration = .init(mode: .always, appearanceIsDark: false, profiles: [work, home])
		#expect(active.isActive)
		#expect(active.offSites(for: work.id) == ["figma.com"])
		#expect(active.offSites(for: home.id).isEmpty)

		let inactive: DarkPagesConfiguration = .init(mode: .withTheme, appearanceIsDark: false, profiles: [work, home])
		#expect(inactive == .off)
	}

	@Test
	internal func aSiteTurnedOffStaysLightWithItsSubdomains() async throws {
		let profile: Profile.ID = .init(rawValue: UUID())
		let configuration: DarkPagesConfiguration = .init(isActive: true, offSites: [profile: ["figma.com"]])

		#expect(configuration.darkens(URL(string: "https://news.example/a")!, in: profile))
		#expect(!configuration.darkens(URL(string: "https://www.figma.com/file/1")!, in: profile))
		#expect(!configuration.darkens(URL(string: "https://help.figma.com")!, in: profile))
		#expect(configuration.darkens(URL(string: "https://notfigma.com")!, in: profile))
		// Only web pages: Arx's own pages and files keep their look.
		#expect(!configuration.darkens(URL(string: "file:///tmp/a.html")!, in: profile))
		#expect(!DarkPagesConfiguration.off.darkens(URL(string: "https://news.example")!, in: profile))
	}

	@Test
	internal func theProfileKeepsItsSitesSortedAndOnce() async throws {
		let id: Profile.ID = .init(rawValue: UUID())
		let organization: BrowserOrganization = .init(
			profiles: [.init(id: id, name: "Default")],
			spaces: [.init(id: .init(rawValue: UUID()), profileID: id, name: "Home")]
		)

		var changed: BrowserOrganization = try organization.applying(.setDarkPageSite(id, site: "https://www.Figma.com/file", off: true), uuid: UUID.init)
		changed = try changed.applying(.setDarkPageSite(id, site: "docs.example", off: true), uuid: UUID.init)
		changed = try changed.applying(.setDarkPageSite(id, site: "figma.com", off: true), uuid: UUID.init)
		#expect(changed.profiles[id: id]?.darkPagesOffSites == ["docs.example", "figma.com"])

		changed = try changed.applying(.setDarkPageSite(id, site: "docs.example", off: false), uuid: UUID.init)
		changed = try changed.applying(.setDarkPageSite(id, site: "figma.com", off: false), uuid: UUID.init)
		#expect(changed.profiles[id: id]?.darkPagesOffSites == nil)

		// Turning a subdomain back on also turns its parent's entry off.
		changed = try changed.applying(.setDarkPageSite(id, site: "figma.com", off: true), uuid: UUID.init)
		changed = try changed.applying(.setDarkPageSite(id, site: "https://help.figma.com", off: false), uuid: UUID.init)
		#expect(changed.profiles[id: id]?.darkPagesOffSites == nil)

		#expect(throws: OrganizationChangeError.invalidSite) {
			try organization.applying(.setDarkPageSite(id, site: "about:blank", off: true), uuid: UUID.init)
		}
	}

	@Test
	internal func aSavedBindingOnTheNewShortcutStillValidates() async throws {
		let shortcut: KeyboardShortcut = try #require(BrowserCommand.darkPage.shortcut)
		var bindings: [ShortcutBinding] = []
		bindings.addShortcut(shortcut, for: .reload)

		var preferences: BrowserPreferences = .init()
		preferences.keyboardShortcuts = bindings
		try preferences.validateKeyboardShortcuts()
		#expect(preferences.keyboardShortcuts.command(for: shortcut) == .reload)
		#expect(preferences.keyboardShortcuts.shortcut(for: .darkPage) == nil)
	}

	@Test
	internal func preferencesDefaultToOffAndReadAnUnknownModeAsOff() async throws {
		#expect(BrowserPreferences().darkPages == .off)

		var preferences: BrowserPreferences = .init()
		preferences.darkPages = .always
		let saved: Data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: saved).darkPages == .always)

		var object: [String: Any] = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
		object["darkPages"] = "sepia"
		let newer: Data = try JSONSerialization.data(withJSONObject: object)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: newer).darkPages == .off)
	}

	/// DEV-1141: agents read and set the mode by its raw value, and nothing else.
	@Test
	internal func automationReadsAndSetsTheModeAsAChoice() async throws {
		#expect(AutomationPreferenceKey.darkPages.schema == .choice(["off", "withTheme", "always"]))
		var preferences: BrowserPreferences = .init()
		#expect(AutomationPreferenceKey.darkPages.value(in: preferences) == .string("off"))

		preferences = try preferences.applying([.init(key: .darkPages, value: .string("withTheme"))])
		#expect(preferences.darkPages == .withTheme)
		#expect(AutomationPreferenceKey.darkPages.value(in: preferences) == .string("withTheme"))

		for invalid: AutomationPreferenceValue in [.string("sepia"), .string("Always"), .bool(true)] {
			#expect(throws: AutomationFailure.invalidValue) {
				try preferences.applying([.init(key: .darkPages, value: invalid)])
			}
		}
		#expect(!AutomationPreferenceKey.darkPages.isAppearance)
	}

	@Test
	internal func theFeatureFlagReadsTheEnvironmentThenDefaults() async throws {
		let suite: String = "DarkPagesTests-\(UUID().uuidString)"
		let defaults: UserDefaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		// On by default (DEV-1143).
		#expect(DarkPagesFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		#expect(!DarkPagesFeatureFlag.isEnabled(environment: ["ARX_DARK_PAGES": "0"], defaults: defaults))
		defaults.set("off", forKey: "ARX_DARK_PAGES")
		#expect(!DarkPagesFeatureFlag.isEnabled(environment: [:], defaults: defaults))
		#expect(DarkPagesFeatureFlag.isEnabled(environment: ["ARX_DARK_PAGES": "1"], defaults: defaults))
	}
}
