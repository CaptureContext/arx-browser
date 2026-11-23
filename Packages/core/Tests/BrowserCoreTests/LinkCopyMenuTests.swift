import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct LinkCopyMenuTests {
	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() throws {
		let suite = "CopySubmenuFeatureFlagTests-\(UUID().uuidString)"
		let defaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }

		#expect(CopySubmenuFeatureFlag.isOn(environment: [:], defaults: defaults))
		#expect(!CopySubmenuFeatureFlag.isOn(environment: ["ARX_COPY_SUBMENU": "0"], defaults: defaults))
		#expect(!CopySubmenuFeatureFlag.isOn(environment: ["ARX_COPY_SUBMENU": "Off"], defaults: defaults))
		#expect(CopySubmenuFeatureFlag.isOn(environment: ["ARX_COPY_SUBMENU": "maybe"], defaults: defaults))

		defaults.set("no", forKey: "ARX_COPY_SUBMENU")
		#expect(!CopySubmenuFeatureFlag.isOn(environment: [:], defaults: defaults))
		// The environment wins over user defaults.
		#expect(CopySubmenuFeatureFlag.isOn(environment: ["ARX_COPY_SUBMENU": "yes"], defaults: defaults))
	}

	/// A pinned tab's menu: every copy and its saved address, then Share Proxy Link.
	@Test
	internal func theCopiesComeFirstThenShareProxyLink() {
		let sections = LinkCopyMenu.sections(modes: LinkCopyMode.allCases, offersSavedLink: true, sharesProxy: true)

		expectNoDifference(sections, [
			[.copy(.original), .copy(.clean), .copy(.markdownOriginal), .copy(.proxy), .copy(.markdownProxy), .copySaved],
			[.shareProxy],
		])
		#expect(LinkCopyMenu.nests(sections))
	}

	/// A link no proxy rule applies to has no proxy items, in the submenu or out of it.
	@Test
	internal func aLinkWithoutProxyHidesTheProxyItems() throws {
		let url = try #require(URL(string: "https://example.com:8443/post"))
		let availability = LinkMenuAvailability(url, rules: ProxyLinkRule.defaults)
		let sections = LinkCopyMenu.sections(modes: availability.copyModes, sharesProxy: availability.proxies)

		expectNoDifference(sections, [[.copy(.original), .copy(.markdownOriginal)]])
		#expect(LinkCopyMenu.nests(sections))
	}

	/// A mailto: link has only Copy Email Address, which stays at the top level.
	@Test
	internal func aLoneCopyDoesNotNest() throws {
		let url = try #require(URL(string: "mailto:hello@example.com"))
		let availability = LinkMenuAvailability(url, rules: ProxyLinkRule.defaults)
		let sections = LinkCopyMenu.sections(modes: availability.copyModes, sharesProxy: availability.proxies)

		expectNoDifference(sections, [[.copy(.original)]])
		#expect(!LinkCopyMenu.nests(sections))
	}

	/// The menu bar's Copy ▸ items are the commands that carry the shortcuts.
	@Test
	internal func everyTabMenuItemIsACommand() {
		let sections = LinkCopyMenu.sections(modes: LinkCopyMode.allCases, sharesProxy: true)

		expectNoDifference(sections.map { $0.map(\.command) }, [
			[.copyURL, .copyCleanLink, .copyMarkdownOriginal, .copyProxyLink, .copyMarkdownProxy],
			[.shareProxyLink],
		])
		#expect(LinkCopyMenu.Item.copySaved.command == nil)
	}
}
