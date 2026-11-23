import BrowserCore
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

/// How Settings and automation see native's site-settings listings (DEV-716).
@Suite
@MainActor
internal struct ChromiumSiteSettingsMappingTests {
	@Test
	internal func listingsKeepKnownPermissionsAndZoom() async throws {
		let settings = ChromiumBrowserEngine.siteSettings(.init(
			permissions: .init(
				defaults: ["camera": "ask", "popups": "block", "midi": "ask"],
				managedDefaults: ["popups"],
				sites: [
					.init(origin: "https://b.example", permission: "camera", setting: "block"),
					.init(origin: "https://a.example", permission: "microphone", setting: "allow", managed: true),
					// A newer engine's names are left out rather than guessed.
					.init(origin: "https://a.example", permission: "midi", setting: "allow"),
					.init(origin: "https://a.example", permission: "camera", setting: "sessionOnly"),
				]
			),
			zoom: .init(default: 1.1, sites: [.init(host: "a.example", factor: 1.5)]),
			truncated: true
		))
		#expect(settings == .init(
			defaults: [
				.init(permission: .camera, setting: .ask),
				.init(permission: .popups, setting: .block, isManaged: true),
			],
			exceptions: [
				.init(origin: "https://a.example", permission: .microphone, setting: .allow, isManaged: true),
				.init(origin: "https://b.example", permission: .camera, setting: .block),
			],
			defaultZoom: 1.1,
			zoom: [.init(host: "a.example", factor: 1.5)],
			isTruncated: true
		))
	}

	@Test
	internal func contentBlockingKeepsOnlyWhatUBlockApplies() {
		let settings = ChromiumBrowserEngine.siteSettings(.init(
			permissions: .init(
				defaults: ["ads": "block"],
				sites: [
					.init(origin: "https://news.example", permission: "ads", setting: "allow"),
					.init(origin: "[*.]shop.example", permission: "ads", setting: "allow"),
					// A BLOCK inside a wildcard rule can't be carved out of uBlock's hostname directive.
					.init(origin: "[*.]bank.example", permission: "ads", setting: "allow", managed: true),
					.init(origin: "https://secure.bank.example", permission: "ads", setting: "block", managed: true),
					// Shapes the engine doesn't hand uBlock stay out.
					.init(origin: "https://[*.]port.example:8443", permission: "ads", setting: "allow"),
					.init(origin: "https://camera.example", permission: "camera", setting: "allow"),
				]
			),
			zoom: .init(default: 1)
		))
		#expect(settings.contentBlockingIsAvailable)
		#expect(settings.contentBlockingOff == ["[*.]shop.example", "https://news.example"])
		#expect(settings.contentBlockingManaged == ["https://secure.bank.example"])
		// A managed wildcard uBlock can't apply isn't managed-off either.
		#expect(settings.contentBlockingManagedOff.isEmpty)
		#expect(settings.blocksContent(on: "https://bank.example"))
		#expect(settings.exceptions.map(\.permission) == [.camera])
		#expect(!settings.contentBlockingDefaultIsManaged)
	}

	@Test
	internal func anExactAllowInsideAWildcardAllowKeepsBoth() {
		let settings = ChromiumBrowserEngine.siteSettings(.init(
			permissions: .init(
				defaults: ["ads": "block"],
				sites: [
					.init(origin: "https://example.com", permission: "ads", setting: "allow"),
					.init(origin: "[*.]example.com", permission: "ads", setting: "allow"),
				]
			),
			zoom: .init(default: 1)
		))
		#expect(settings.contentBlockingOff == ["[*.]example.com", "https://example.com"])
		#expect(!settings.blocksContent(on: "https://shop.example.com"))
		#expect(!settings.blocksContent(on: "https://example.com"))
	}

	@Test
	internal func aManagedAdsDefaultLeavesOnlyManagedSiteRules() {
		let settings = ChromiumBrowserEngine.siteSettings(.init(
			permissions: .init(
				defaults: ["ads": "block"],
				managedDefaults: ["ads"],
				sites: [
					.init(origin: "https://news.example", permission: "ads", setting: "allow"),
					.init(origin: "https://intranet.example", permission: "ads", setting: "allow", managed: true),
				]
			),
			zoom: .init(default: 1)
		))
		#expect(settings.contentBlockingDefaultIsManaged)
		#expect(settings.contentBlockingOff == ["https://intranet.example"])
		#expect(settings.blocksContent(on: "https://news.example"))
		#expect(!settings.blocksContent(on: "https://intranet.example"))
		#expect(settings.contentBlockingIsManaged(on: "https://news.example"))
	}

	@Test(arguments: [
		(ChromiumSiteSettingsFailure.unavailable, SiteSettingsFailure.unavailable),
		(.invalid(reason: "origin"), .invalid),
		(.managed, .managed),
		(.failed, .failed),
	])
	internal func failuresMap(
		native: ChromiumSiteSettingsFailure,
		failure: SiteSettingsFailure
	) async throws {
		#expect(ChromiumBrowserEngine.siteSettingsFailure(native) == failure)
		#expect(ChromiumBrowserEngine.siteSettingsFailure(CancellationError()) == .failed)
	}
}
