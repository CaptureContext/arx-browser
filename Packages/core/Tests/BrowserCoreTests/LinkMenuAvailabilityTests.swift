import CustomDump
import Foundation
import Testing

@testable import BrowserCore

/// DEV-853: like Chromium, every link gets the menu and each item decides on its own.
internal struct LinkMenuAvailabilityTests {
	/// Each flag matches the item's backend: Chromium's download start refuses credentials,
	/// and clean and proxy links need the default port.
	@Test(arguments: [
		("https://x.com/post", LinkMenuAvailability(opens: true, downloads: true, cleans: true, proxies: true, isEmailAddress: false)),
		("http://x.com/post", .init(opens: true, downloads: true, cleans: true, proxies: true, isEmailAddress: false)),
		("https://x.com:443/post", .init(opens: true, downloads: true, cleans: true, proxies: true, isEmailAddress: false)),
		("HTTPS://X.COM/", .init(opens: true, downloads: true, cleans: true, proxies: true, isEmailAddress: false)),
		("http://localhost:3000/app", .init(opens: true, downloads: true, cleans: false, proxies: false, isEmailAddress: false)),
		("https://x.com:8443/post", .init(opens: true, downloads: true, cleans: false, proxies: false, isEmailAddress: false)),
		("https://user:secret@x.com/post", .init(opens: true, downloads: false, cleans: false, proxies: true, isEmailAddress: false)),
		("mailto:hello@capturecontext.dev", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: true)),
		("MAILTO:hello@capturecontext.dev", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: true)),
		("tel:+15555550100", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: false)),
		("ftp://x.com/file", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: false)),
		("javascript:void(0)", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: false)),
		("about:blank#blocked", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: false)),
		("file:///Users/me/file.txt", .init(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: false)),
	])
	internal func itemsFollowTheLinksSchemePortAndCredentials(
		url: String,
		expected: LinkMenuAvailability
	) throws {
		expectNoDifference(LinkMenuAvailability(try #require(URL(string: url)), rules: ProxyLinkRule.defaults), expected)
	}

	@Test
	internal func copyModesFollowTheirItems() {
		let web = LinkMenuAvailability(opens: true, downloads: true, cleans: true, proxies: true, isEmailAddress: false)
		expectNoDifference(web.copyModes, LinkCopyMode.allCases)
		let port = LinkMenuAvailability(opens: true, downloads: true, cleans: false, proxies: false, isEmailAddress: false)
		expectNoDifference(port.copyModes, [.original, .markdownOriginal])
		let credentials = LinkMenuAvailability(opens: true, downloads: false, cleans: false, proxies: true, isEmailAddress: false)
		expectNoDifference(credentials.copyModes, [.original, .markdownOriginal, .proxy, .markdownProxy])
		let mail = LinkMenuAvailability(opens: false, downloads: false, cleans: false, proxies: false, isEmailAddress: true)
		expectNoDifference(mail.copyModes, [.original])
	}

	// MARK: - Proxy link rules (DEV-1262)

	/// A site a proxy link rule matches, and one none does: the default X rule matches x.com.
	nonisolated private static let matching: String = "https://x.com/user/status/1"
	nonisolated private static let unmatched: String = "https://example.com/post"

	/// The link menu offers Copy Proxy Link, its Markdown form and Share Proxy Link only for a
	/// link a proxy link rule matches; for any other it leaves them out.
	@Test(arguments: [(Self.matching, true), (Self.unmatched, false)])
	internal func theLinkMenuOffersProxyItemsOnlyWhereARuleMatches(
		url: String,
		proxies: Bool
	) async throws {
		let availability = context(url: url).availability(rules: ProxyLinkRule.defaults)
		let sections = LinkCopyMenu.sections(modes: availability.copyModes, sharesProxy: availability.proxies)

		expectNoDifference(availability.proxies, proxies)
		expectNoDifference(
			sections,
			proxies
			? [
				[.copy(.original), .copy(.clean), .copy(.markdownOriginal), .copy(.proxy), .copy(.markdownProxy)],
				[.shareProxy],
			]
			: [[.copy(.original), .copy(.clean), .copy(.markdownOriginal)]]
		)
	}

	/// The page's menu, on the address bar, copies the page's link: the proxy items only on a
	/// site a proxy link rule matches.
	@Test(arguments: [(Self.matching, true), (Self.unmatched, false)])
	internal func thePageMenuOffersProxyItemsOnlyWhereARuleMatches(
		url: String,
		proxies: Bool
	) async throws {
		let page = try #require(URL(string: url))
		let sections = LinkCopyMenu.tabSections(proxies: LinkTransformer.proxies(page, rules: ProxyLinkRule.defaults))

		expectNoDifference(
			sections,
			proxies
			? [
				[.copy(.original), .copy(.clean), .copy(.markdownOriginal), .copy(.proxy), .copy(.markdownProxy)],
				[.shareProxy],
			]
			: [[.copy(.original), .copy(.clean), .copy(.markdownOriginal)]]
		)
	}

	/// A tab's menu, a pinned one's with Saved Link: the proxy items only when a proxy link rule
	/// matches the tab's site, or one of the selected tabs' sites.
	@Test(arguments: [
		([Self.matching], true),
		([Self.unmatched], false),
		([Self.unmatched, Self.matching], true),
		([Self.unmatched, "https://example.org/"], false),
	])
	internal func aTabMenuOffersProxyItemsOnlyWhereARuleMatches(
		urls: [String],
		proxies: Bool
	) async throws {
		let tabs = try urls.map { try #require(URL(string: $0)) }
		let matches = tabs.contains { LinkTransformer.proxies($0, rules: ProxyLinkRule.defaults) }
		let sections = LinkCopyMenu.tabSections(proxies: matches, offersSavedLink: true)

		expectNoDifference(
			sections,
			proxies
			? [
				[
					.copy(.original), .copy(.clean), .copy(.markdownOriginal), .copy(.proxy), .copy(.markdownProxy),
					.copySaved,
				],
				[.shareProxy],
			]
			: [[.copy(.original), .copy(.clean), .copy(.markdownOriginal), .copySaved]]
		)
	}

	/// The command bar lists the proxy link commands enabled on a site a proxy link rule matches,
	/// and disabled on any other, where the menu bar disables them too.
	@Test(arguments: [(Self.matching, true), (Self.unmatched, false)])
	internal func theCommandBarListsProxyCommandsDisabledWhereNoRuleMatches(
		url: String,
		proxies: Bool
	) async throws {
		let page = try #require(URL(string: url))
		let context = BrowserCommandContext(
			host: .main,
			hasTab: true,
			canSavePage: true,
			canProxyLink: LinkTransformer.proxies(page, rules: ProxyLinkRule.defaults)
		)

		for command in [BrowserCommand.copyProxyLink, .copyMarkdownProxy, .shareProxyLink] {
			expectNoDifference(command.isEnabled(in: context), proxies, "\(command)")
			expectNoDifference(command.isListedDisabled(in: context), !proxies, "\(command)")
		}

		// The other copies don't depend on a rule, and nothing else is listed disabled.
		#expect(BrowserCommand.copyURL.isEnabled(in: context))
		#expect(BrowserCommand.copyCleanLink.isEnabled(in: context))
		expectNoDifference(
			BrowserCommand.allCases.filter { $0.isListedDisabled(in: context) },
			proxies ? [] : [.copyProxyLink, .copyMarkdownProxy, .shareProxyLink]
		)
	}

	/// Without a page, or while the window is busy, the command bar leaves them out as before.
	@Test
	internal func theCommandBarLeavesProxyCommandsOutWithoutAPage() async throws {
		for context in [
			BrowserCommandContext(host: .main),
			BrowserCommandContext(host: .main, hasTab: true, isBusy: true),
			BrowserCommandContext(host: .settings),
		] {
			#expect(!BrowserCommand.copyProxyLink.isEnabled(in: context))
			#expect(!BrowserCommand.copyProxyLink.isListedDisabled(in: context))
		}
	}

	/// A rule that's off, or a link on another port or with credentials, decides as it does
	/// when the link is copied.
	@Test
	internal func aRuleThatIsOffMatchesNothing() async throws {
		var rules = ProxyLinkRule.defaults
		let link = try #require(URL(string: Self.matching))
		#expect(LinkTransformer.proxies(link, rules: rules))
		#expect(LinkTransformer.proxies(try #require(URL(string: "https://user:secret@x.com/post")), rules: rules))
		#expect(!LinkTransformer.proxies(try #require(URL(string: "https://x.com:8443/post")), rules: rules))
		#expect(!LinkTransformer.proxies(link, rules: []))
		for index in rules.indices { rules[index].isEnabled = false }
		#expect(!LinkTransformer.proxies(link, rules: rules))
	}

	@Test(arguments: [
		"http://localhost:3000/app",
		"https://x.com:8443/post",
		"https://user:secret@x.com/post",
		"mailto:hello@capturecontext.dev",
		"tel:+15555550100",
		"javascript:void(0)",
	])
	internal func everyLinkWithASchemeIsAValidMenuTarget(url: String) throws {
		try context(url: url).validate()
	}

	@Test
	internal func theBoundIsChromiumsAndUnchangedChecksStillHold() throws {
		let longest = "https://x.com/" + String(repeating: "a", count: BrowserLinkContext.maximumURLBytes - 14)
		try context(url: longest).validate()
		#expect(throws: LinkTransformationError.invalidURL) {
			try context(url: longest + "a").validate()
		}
		#expect(throws: LinkTransformationError.invalidURL) {
			try context(url: "relative/path").validate()
		}
		#expect(throws: LinkTransformationError.invalidURL) {
			try context(url: "https://x.com/", title: "a\0b").validate()
		}
	}

	@Test
	internal func copyLinkKeepsCredentialsAndProxyLinksDropThem() throws {
		let item = LinkCopyItem(title: "Post", url: try #require(URL(string: "https://user:secret@x.com/post?a=1#top")))
		expectNoDifference(LinkTransformer.copy([item], mode: .original).text, "https://user:secret@x.com/post?a=1#top")
		let stripped = LinkTransformer.removingCredentials(item)
		expectNoDifference(stripped, .init(title: "Post", url: URL(string: "https://x.com/post?a=1#top")!))
		let plain = LinkCopyItem(title: "", url: URL(string: "http://localhost:3000/")!)
		expectNoDifference(LinkTransformer.removingCredentials(plain), plain)
	}

	@Test(arguments: [
		("mailto:hello@capturecontext.dev", "hello@capturecontext.dev"),
		("mailto:hello@capturecontext.dev?subject=Hi&body=There", "hello@capturecontext.dev"),
		("mailto:a@x.com,b@x.com", "a@x.com,b@x.com"),
		("mailto:first%20last@x.com", "first last@x.com"),
	])
	internal func copyEmailAddressCopiesTheAddressAsChromiumDoes(
		url: String,
		expected: String
	) throws {
		let item = LinkCopyItem(title: "Mail", url: try #require(URL(string: url)))
		expectNoDifference(LinkTransformer.copy([item], mode: .original).text, expected)
		expectNoDifference(LinkTransformer.emailAddress(item.url), expected)
	}

	@Test
	internal func otherLinksAreCopiedAsTheyAre() throws {
		expectNoDifference(LinkTransformer.emailAddress(URL(string: "https://x.com/mailto:a@b.c")!), nil)
		let item = LinkCopyItem(title: "", url: URL(string: "tel:+15555550100")!)
		expectNoDifference(LinkTransformer.copy([item], mode: .original).text, "tel:+15555550100")
	}

	private func context(
		url: String,
		title: String = "Link"
	) -> BrowserLinkContext {
		.init(
			token: 1,
			tabID: .init(rawValue: UUID()),
			profileID: .init(rawValue: UUID()),
			sessionRevision: 1,
			documentRevision: 1,
			isPrivate: false,
			item: .init(title: title, url: URL(string: url)!),
			x: 0,
			y: 0
		)
	}
}
