import CustomDump
import Foundation
import Testing
@testable import BrowserCore

internal struct SiteSettingsTests {
	@Test(arguments: [
		("meet.google.com", "https://meet.google.com"),
		("https://Meet.Google.com/room?x=1#y", "https://meet.google.com"),
		("http://localhost:8080/path", "http://localhost:8080"),
		("https://example.com:443", "https://example.com"),
		("http://example.com:80", "http://example.com"),
		// Chromium lists internationalized hosts in their ASCII form.
		("https://xn--bcher-kva.example", "https://xn--bcher-kva.example"),
		("bücher.example", "https://xn--bcher-kva.example"),
	])
	internal func originsKeepOnlySchemeHostAndPort(
		_ text: String,
		_ origin: String
	) {
		expectNoDifference(SiteSettings.origin(text), origin)
	}

	@Test(arguments: ["", "javascript:alert(1)", "file:///etc/hosts", "https://user:secret@example.com", "ftp://example.com"])
	internal func originsRefuseEverythingElse(_ text: String) {
		#expect(SiteSettings.origin(text) == nil)
	}

	@Test
	internal func zoomHostsAreBareHosts() {
		expectNoDifference(SiteSettings.zoomHost("Example.com"), "example.com")
		expectNoDifference(SiteSettings.zoomHost("https://docs.example.com/a"), "docs.example.com")
		expectNoDifference(SiteSettings.zoomHost("bücher.example"), "xn--bcher-kva.example")
		expectNoDifference(SiteSettings.zoomHost("xn--bcher-kva.example"), "xn--bcher-kva.example")
		#expect(SiteSettings.zoomHost("") == nil)
		#expect(SiteSettings.zoomHost("https://[::1]/") == nil)
	}

	@Test
	internal func editsFollowWhatEachPermissionTakes() throws {
		try SiteSettingsEdit.setPermission(origin: "https://a.example", .camera, .allow).validate()
		try SiteSettingsEdit.setPermission(origin: "https://a.example", .camera, .ask).validate()
		try SiteSettingsEdit.setPermission(origin: "https://a.example", .popups, .allow).validate()

		// Removing takes a listed pattern as it is.
		try SiteSettingsEdit.setPermission(origin: "https://[*.]a.example", .camera, nil).validate()
		try SiteSettingsEdit.setPermission(origin: nil, .notifications, .block).validate()
		try SiteSettingsEdit.setPermission(origin: nil, .popups, .allow).validate()
		try SiteSettingsEdit.setZoom(host: "a.example", factor: 1.5).validate()
		try SiteSettingsEdit.setZoom(host: "a.example", factor: nil).validate()
		try SiteSettingsEdit.setZoom(host: nil, factor: 0.25).validate()

		let refused: [SiteSettingsEdit] = [
			.setPermission(origin: "https://a.example", .popups, .ask),
			.setPermission(origin: "a.example", .camera, .allow),
			.setPermission(origin: "https://a.example/path", .camera, .allow),
			.setPermission(origin: nil, .camera, .allow),
			.setPermission(origin: nil, .camera, nil),
			.setPermission(origin: nil, .popups, .ask),
			.setZoom(host: "a.example", factor: 6),
			.setZoom(host: "a.example", factor: .nan),
			.setZoom(host: "A.example", factor: 1.5),
			.setZoom(host: nil, factor: nil),
		]
		for edit in refused {
			#expect(throws: SiteSettingsFailure.invalid, "\(edit)") { try edit.validate() }
		}
	}

	@Test
	internal func holdsTellsWhenNothingWouldChange() {
		let settings = SiteSettings(
			defaults: [.init(permission: .camera, setting: .ask)],
			exceptions: [.init(origin: "https://a.example", permission: .camera, setting: .block)],
			defaultZoom: 1.1,
			zoom: [.init(host: "a.example", factor: 1.5)]
		)
		#expect(settings.holds(.setPermission(origin: "https://a.example", .camera, .block)))
		#expect(!settings.holds(.setPermission(origin: "https://a.example", .camera, .allow)))
		#expect(settings.holds(.setPermission(origin: "https://b.example", .camera, nil)))
		#expect(settings.holds(.setPermission(origin: nil, .camera, .ask)))
		#expect(settings.holds(.setZoom(host: "a.example", factor: 1.5)))
		#expect(!settings.holds(.setZoom(host: "a.example", factor: nil)))
		#expect(settings.holds(.setZoom(host: "b.example", factor: nil)))
		// Native drops a host's zoom equal to the default, so asking for it changes nothing.
		#expect(settings.holds(.setZoom(host: "b.example", factor: 1.1)))
		#expect(!settings.holds(.setZoom(host: nil, factor: 1)))
	}

	@Test
	internal func listingsSortSitesAndHosts() {
		let settings = SiteSettings(
			exceptions: [
				.init(origin: "https://b.example", permission: .camera, setting: .block),
				.init(origin: "https://a.example", permission: .clipboard, setting: .allow),
				.init(origin: "https://a.example", permission: .camera, setting: .allow),
			],
			zoom: [.init(host: "b.example", factor: 2), .init(host: "a.example", factor: 1.5)]
		)
		expectNoDifference(settings.origins, ["https://a.example", "https://b.example"])
		expectNoDifference(settings.exceptions.map(\.permission), [.camera, .clipboard, .camera])
		expectNoDifference(settings.zoom.map(\.host), ["a.example", "b.example"])
	}

	// MARK: - Automation

	@Test
	internal func siteSectionsNeedAProfile() throws {
		try AutomationSettingsRequest(.read(.sitePermissions, profileID: UUID())).validate()
		try AutomationSettingsRequest(.read(.zoom, profileID: UUID())).validate()
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationSettingsRequest(.read(.zoom, profileID: nil)).validate()
		}
		#expect(throws: AutomationFailure.invalidRequest) {
			try AutomationSettingsRequest(.read(.preferences, profileID: UUID())).validate()
		}
	}

	@Test
	internal func siteEditsCarryTheirProfileAndSection() throws {
		let profile = UUID()
		let permission = AutomationSettingsEdit.setSitePermission(profileID: profile, origin: "https://a.example", .camera, .block)
		let zoom = AutomationSettingsEdit.setSiteZoom(profileID: profile, host: nil, factor: 1.25)
		expectNoDifference(permission.section, .sitePermissions)
		expectNoDifference(zoom.section, .zoom)
		expectNoDifference(permission.profileID, profile)
		expectNoDifference(permission.siteSettingsEdit, .setPermission(origin: "https://a.example", .camera, .block))
		expectNoDifference(zoom.siteSettingsEdit, .setZoom(host: nil, factor: 1.25))
		expectNoDifference(permission.name, "setSitePermission")
		expectNoDifference(zoom.name, "setSiteZoom")
		try permission.validate()
		try zoom.validate()
		#expect(throws: AutomationFailure.invalidValue) {
			try AutomationSettingsEdit.setSiteZoom(profileID: profile, host: "a.example", factor: 9).validate()
		}
		let decoded = try JSONDecoder().decode(AutomationSettingsEdit.self, from: JSONEncoder().encode(permission))
		expectNoDifference(decoded, permission)
	}

	@Test
	internal func allowingASitePermissionAlwaysAsks() {
		func operation(_ edit: AutomationSettingsEdit) -> AutomationOperation {
			.settings(.init(.change(.init(operationID: UUID(), expectedRevision: String(repeating: "0", count: 64), edit: edit))))
		}
		let profile = UUID()
		for permission in SitePermission.allCases where permission != .popups {
			#expect(operation(.setSitePermission(profileID: profile, origin: "https://a.example", permission, .allow)).alwaysAsks)
		}
		#expect(!operation(.setSitePermission(profileID: profile, origin: "https://a.example", .popups, .allow)).alwaysAsks)
		#expect(!operation(.setSitePermission(profileID: profile, origin: "https://a.example", .camera, .block)).alwaysAsks)
		#expect(!operation(.setSitePermission(profileID: profile, origin: "https://a.example", .camera, nil)).alwaysAsks)
		#expect(!operation(.setSitePermission(profileID: profile, origin: nil, .camera, .ask)).alwaysAsks)
		#expect(!operation(.setSiteZoom(profileID: profile, host: "a.example", factor: 2)).alwaysAsks)
		#expect(operation(.setSiteZoom(profileID: profile, host: "a.example", factor: 2)).riskTier == .mutate)
	}

	@Test
	internal func resultsShowChoicesAndRanges() {
		let profile = UUID()
		let settings = SiteSettings(
			defaults: [.init(permission: .popups, setting: .block, isManaged: true)],
			exceptions: [.init(origin: "https://a.example", permission: .camera, setting: .allow)],
			defaultZoom: 1.25,
			zoom: [.init(host: "a.example", factor: 2)]
		)
		let permissions = AutomationSitePermissionSettings(profileID: profile, settings: settings)
		expectNoDifference(permissions.defaults.first?.choices, [.allow, .block])
		expectNoDifference(permissions.defaults.first?.managed, true)
		expectNoDifference(permissions.sites.first?.origin, "https://a.example")
		let zoom = AutomationZoomSettings(profileID: profile, settings: settings)
		expectNoDifference(zoom.default, 1.25)
		expectNoDifference(zoom.minimum, 0.25)
		expectNoDifference(zoom.maximum, 5)
	}
}
