import BrowserCore
import Foundation
import Testing

/// DEV-932: the sites a profile never unloads.
internal struct KeptLoadedSiteTests {
	@Test(arguments: [
		("music.example.com", "music.example.com"),
		("https://www.Example.com/a/b?c", "example.com"),
		("Example.com", "example.com"),
		("  example.com  ", "example.com"),
		("http://localhost:8080", "localhost"),
		("www.example.com.", "example.com"),
		("http://[::1]:8080/", "[::1]"),
		("[::1]", "[::1]"),
		("https://[2001:DB8::1]/a", "[2001:db8::1]"),
	])
	internal func aTypedSiteIsItsHost(
		text: String,
		site: String
	) async throws {
		#expect(KeptLoadedSite.site(from: text) == site)
	}

	@Test(arguments: ["", "   ", "about:blank", "file:///tmp/a.html", "two words.com", "https://"])
	internal func textWithoutAWebHostIsNoSite(text: String) async throws {
		#expect(KeptLoadedSite.site(from: text) == nil)
	}

	/// What the menu and Settings add is normalized again by the organization change.
	@Test(arguments: ["music.example.com", "https://www.example.com", "http://[::1]:8080", "localhost"])
	internal func aSiteReadsBackAsItself(text: String) async throws {
		let site = try #require(KeptLoadedSite.site(from: text))
		#expect(KeptLoadedSite.site(from: site) == site)
	}

	@Test
	internal func anIPv6SiteMatchesItsPages() async throws {
		#expect(KeptLoadedSite.matches(URL(string: "http://[::1]:3000/app")!, site: "[::1]"))
		#expect(!KeptLoadedSite.matches(URL(string: "http://[::2]/")!, site: "[::1]"))
	}

	@Test
	internal func aSiteCoversItsSubdomainsButNotLookalikes() async throws {
		let site = "example.com"
		#expect(KeptLoadedSite.matches(URL(string: "https://example.com/x")!, site: site))
		#expect(KeptLoadedSite.matches(URL(string: "https://www.example.com")!, site: site))
		#expect(KeptLoadedSite.matches(URL(string: "https://music.example.com")!, site: site))
		#expect(!KeptLoadedSite.matches(URL(string: "https://notexample.com")!, site: site))
		#expect(!KeptLoadedSite.matches(URL(string: "https://example.com.evil.net")!, site: site))
		#expect(!KeptLoadedSite.matches(URL(string: "about:blank")!, site: site))
	}

	@Test
	internal func aProfileKeepsOnlyItsOwnSitesLoaded() async throws {
		var profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		let page = URL(string: "https://music.example.com/now-playing")!
		#expect(!profile.keepsLoaded(page))
		profile.keptLoadedSites = ["example.com"]
		#expect(profile.keepsLoaded(page))
		#expect(!profile.keepsLoaded(URL(string: "https://example.org")!))
		#expect(!profile.keepsLoaded(nil))
	}

	@Test
	internal func addingAndRemovingKeepsTheListSortedAndUnique() async throws {
		var sites = KeptLoadedSite.sites(nil, setting: "b.com", kept: true)
		sites = KeptLoadedSite.sites(sites, setting: "a.com", kept: true)
		sites = KeptLoadedSite.sites(sites, setting: "a.com", kept: true)
		#expect(sites == ["a.com", "b.com"])
		sites = KeptLoadedSite.sites(sites, setting: "b.com", kept: false)
		sites = KeptLoadedSite.sites(sites, setting: "a.com", kept: false)
		#expect(sites == nil)
	}

	@Test
	internal func theOrganizationChangeNormalizesAndRejectsSites() async throws {
		let profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		let space = Space(id: .init(rawValue: UUID()), profileID: profile.id, name: "Space")
		let organization = BrowserOrganization(profiles: [profile], spaces: [space])

		let kept = try organization.applying(
			.setKeptLoadedSite(profile.id, site: "https://www.Example.com/a", kept: true),
			uuid: UUID.init
		)
		#expect(kept.profiles[id: profile.id]?.keptLoadedSites == ["example.com"])
		let removed = try kept.applying(.setKeptLoadedSite(profile.id, site: "example.com", kept: false), uuid: UUID.init)
		#expect(removed.profiles[id: profile.id]?.keptLoadedSites == nil)
		#expect(throws: OrganizationChangeError.invalidSite) {
			try organization.applying(.setKeptLoadedSite(profile.id, site: "not a site", kept: true), uuid: UUID.init)
		}
	}

	/// DEV-1001: Settings' edit form moves a site to another name or profile in one change.
	@Test
	internal func replacingMovesTheSiteInOneChange() async throws {
		let work = Profile(id: .init(rawValue: UUID()), name: "Work", keptLoadedSites: ["example.com", "mail.example"])
		let home = Profile(id: .init(rawValue: UUID()), name: "Home")
		let space = Space(id: .init(rawValue: UUID()), profileID: work.id, name: "Space")
		let organization = BrowserOrganization(profiles: [work, home], spaces: [space])

		let renamed = try organization.applying(
			.replaceKeptLoadedSite(work.id, site: "example.com", newProfile: work.id, newSite: "https://Docs.Example.com/x"),
			uuid: UUID.init
		)
		#expect(renamed.profiles[id: work.id]?.keptLoadedSites == ["docs.example.com", "mail.example"])

		let moved = try organization.applying(
			.replaceKeptLoadedSite(work.id, site: "mail.example", newProfile: home.id, newSite: "mail.example"),
			uuid: UUID.init
		)
		#expect(moved.profiles[id: work.id]?.keptLoadedSites == ["example.com"])
		#expect(moved.profiles[id: home.id]?.keptLoadedSites == ["mail.example"])

		#expect(throws: OrganizationChangeError.invalidSite) {
			try organization.applying(
				.replaceKeptLoadedSite(work.id, site: "example.com", newProfile: work.id, newSite: "not a site"),
				uuid: UUID.init
			)
		}
	}

	@Test
	internal func olderProfilesDecodeWithoutSites() async throws {
		let id = UUID()
		let json = Data(#"{"id":"\#(id.uuidString)","name":"Old","favorites":[]}"#.utf8)
		let profile = try JSONDecoder().decode(Profile.self, from: json)
		#expect(profile.keptLoadedSites == nil)
	}
}
