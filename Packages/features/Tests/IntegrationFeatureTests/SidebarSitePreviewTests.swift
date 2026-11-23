@testable import AppFeature
import AppUI
import BrowserCore
import CustomDump
import Foundation
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-802: unread Gmail and recent Linear, Notion and Figma pages on favorites' hover cards.
extension IntegrationFeatureTests {
	@Test
	internal func sitesAreRecognizedFromTheirAddresses() {
		func site(_ string: String) -> SidebarPreviewSite? { SidebarPreviewSite(url: URL(string: string)!) }
		expectNoDifference(site("https://mail.google.com/mail/u/0/#inbox"), .gmail(account: 0))
		expectNoDifference(site("https://mail.google.com/mail/u/2/#label/work"), .gmail(account: 2))
		expectNoDifference(site("https://mail.google.com/mail/"), .gmail(account: 0))
		expectNoDifference(site("https://mail.google.com/chat/"), nil)
		expectNoDifference(site("http://mail.google.com/mail/u/0/"), nil)
		expectNoDifference(site("https://linear.app/capturecontext/inbox"), .recentPages(.linear))
		expectNoDifference(site("https://www.notion.so/workspace"), .recentPages(.notion))
		expectNoDifference(site("https://team.notion.site/Page-0123456789abcdef0123456789abcdef"), .recentPages(.notion))
		expectNoDifference(site("https://www.figma.com/files/recents"), .recentPages(.figma))

		// DEV-804: calendars are a site of their own (Live Calendar).
		expectNoDifference(site("https://calendar.google.com/calendar/u/0/r"), .googleCalendar(account: 0))
		expectNoDifference(site("https://outlook.office.com/mail/"), nil)
		expectNoDifference(site("https://linear.app.evil.example/x/issue/A-1"), nil)
	}

	@Test
	internal func recentPagesKeepOnePerPageNewestFirstAndSkipTheSitesOtherScreens() {
		let profile = Profile.ID(rawValue: UUID(0))
		let start = Date(timeIntervalSince1970: 10_000)
		func entry(
			_ id: Int,
			_ url: String,
			_ title: String,
			_ minutes: Double
		) -> BrowsingHistoryEntry {
			.init(
				id: UUID(id),
				url: URL(string: url)!,
				title: title,
				lastVisited: start.addingTimeInterval(minutes * 60)
			)
		}
		let history = BrowsingHistorySnapshot(profileID: profile, entries: [
			entry(1, "https://linear.app/cc/issue/DEV-802/implement-hover", "DEV-802 Implement hover previews", 1),
			entry(2, "https://linear.app/cc/issue/DEV-802/implement-hover-previews", "DEV-802 Implement hover previews | Linear", 5),
			entry(3, "https://linear.app/cc/project/arx-mvp-1234", "Arx MVP - Linear", 3),
			entry(4, "https://linear.app/cc/settings/account", "Settings", 9),
			entry(5, "https://linear.app/cc/inbox", "Inbox", 8),
			entry(6, "https://www.figma.com/design/AbC123/Arx?node-id=1", "Arx – Figma", 7),
			entry(7, "https://linear.app/cc/view/my-issues-99", "My issues", 2),
		])

		let linear = SidebarPreviewSite.RecentPagesSite.linear.recentPages(
			in: history,
			excluding: URL(string: "https://linear.app/cc/view/my-issues-99")!
		)
		expectNoDifference(linear.map(\.title), ["DEV-802 Implement hover previews", "Arx MVP"])
		expectNoDifference(linear.map(\.date), [start.addingTimeInterval(300), start.addingTimeInterval(180)])

		let figma = SidebarPreviewSite.RecentPagesSite.figma.recentPages(in: history, excluding: URL(string: "https://www.figma.com/")!)
		expectNoDifference(figma.map(\.title), ["Arx"])
		#expect(SidebarPreviewSite.RecentPagesSite.notion.recentPages(in: nil, excluding: URL(string: "https://notion.so")!).isEmpty)
	}

	@Test
	internal func notionPagesAreKeyedByTheirIDAndListAtMostFive() {
		let profile = Profile.ID(rawValue: UUID(0))
		let start = Date(timeIntervalSince1970: 10_000)
		let pages = (0..<7).map { index in
			BrowsingHistoryEntry(
				id: UUID(index + 1),
				url: URL(string: "https://www.notion.so/ws/Page-\(index)-\(String(repeating: "\(index)", count: 32))")!,
				title: "Page \(index)",
				lastVisited: start.addingTimeInterval(Double(index))
			)
		}
		let renamed = BrowsingHistoryEntry(
			id: UUID(20),
			url: URL(string: "https://www.notion.so/\(String(repeating: "6", count: 32))")!,
			title: "Page 6",
			lastVisited: start.addingTimeInterval(-50)
		)
		let history = BrowsingHistorySnapshot(profileID: profile, entries: pages + [renamed])
		let recent = SidebarPreviewSite.RecentPagesSite.notion.recentPages(in: history, excluding: URL(string: "https://www.notion.so/ws")!)
		expectNoDifference(recent.map(\.title), ["Page 6", "Page 5", "Page 4", "Page 3", "Page 2"])
	}

	@Test
	internal func onlyFavoritesInTheirOwnProfileGetSiteRows() {
		var organization = fixture()
		let work = Profile.ID(rawValue: UUID(90))
		organization.profiles.append(.init(id: work, name: "Work"))
		organization.tabs[0].restoration = .init(title: "Linear", url: URL(string: "https://linear.app/cc/inbox")!)
		organization.tabs[1].restoration = .init(title: "Gmail", url: URL(string: "https://mail.google.com/mail/u/1/#inbox")!)
		organization.profiles[0].favorites = [organization.tabs[0].id, organization.tabs[1].id]
		let linear = organization.tabs[0]
		let gmail = organization.tabs[1]

		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let visited = Date(timeIntervalSince1970: 5_000)
		state.history.snapshots[linear.profileID] = .init(profileID: linear.profileID, entries: [
			.init(id: UUID(60), url: URL(string: "https://linear.app/cc/issue/DEV-1/one")!, title: "DEV-1 One", lastVisited: visited),
		])

		// Another profile's visits never show.
		state.history.snapshots[work] = .init(profileID: work, entries: [
			.init(id: UUID(61), url: URL(string: "https://linear.app/other/issue/OTH-9/secret")!, title: "OTH-9 Secret", lastVisited: visited.addingTimeInterval(60)),
		])

		let sources = HoverPreviewSources()
		expectNoDifference(
			state.sidebarSiteSource(in: state.main.id, tabID: linear.id.rawValue, sources: sources),
			.ready(.init(kind: .recentPages, items: [.init(id: "cc/issue/dev-1", title: "DEV-1 One", date: visited)]))
		)
		expectNoDifference(state.sidebarSiteSource(in: state.main.id, tabID: gmail.id.rawValue, sources: sources), .mail(account: 1))

		// Each option turns its source off.
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: linear.id.rawValue, sources: .init(recentPages: false)) == nil)
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: gmail.id.rawValue, sources: .init(mail: false)) == nil)

		// A tab that isn't a favorite gets nothing.
		state.workspace.profiles[0].favorites = [gmail.id]
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: linear.id.rawValue, sources: sources) == nil)
	}

	@Test
	internal func privateWindowsGetNoSiteRows() {
		var organization = fixture()
		organization.tabs[0].restoration = .init(title: "Linear", url: URL(string: "https://linear.app/cc/inbox")!)
		organization.profiles[0].favorites = [organization.tabs[0].id]
		let state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true
		))
		#expect(state.sidebarSiteSource(in: state.main.id, tabID: organization.tabs[0].id.rawValue, sources: .init()) == nil)
	}

	@Test
	internal func gmailsFeedBecomesUnreadRows() throws {
		let feed = """
		<?xml version="1.0" encoding="UTF-8"?>
		<feed version="0.3" xmlns="http://purl.org/atom/ns#">
		<title>Gmail - Inbox for maxim@example.com</title>
		<tagline>New messages in your Gmail Inbox</tagline>
		<fullcount>12</fullcount>
		<link rel="alternate" href="https://mail.google.com/mail" type="text/html" />
		<modified>2026-11-10T17:00:00Z</modified>
		<entry>
		<title>Design review moved to Thursday</title>
		<summary>Hi Maxim, can we move it?</summary>
		<link rel="alternate" href="https://mail.google.com/mail?account_id=x&amp;message_id=1" type="text/html" />
		<modified>2026-11-10T16:55:00Z</modified>
		<issued>2026-11-10T16:55:00Z</issued>
		<id>tag:gmail.google.com,2004:1</id>
		<author><name>Ada Lovelace</name><email>ada@example.com</email></author>
		</entry>
		<entry>
		<title>Your invoice</title>
		<issued>2026-11-10T15:00:00Z</issued>
		<id>tag:gmail.google.com,2004:2</id>
		<author><name></name><email>billing@example.com</email></author>
		</entry>
		</feed>
		"""
		let value = String(decoding: try JSONEncoder().encode(feed), as: UTF8.self)
		let preview = try #require(SidebarMailPreviews.preview(fromScriptValue: value))
		expectNoDifference(preview, .init(
			kind: .mail,
			items: [
				.init(
					id: "tag:gmail.google.com,2004:1",
					title: "Design review moved to Thursday",
					detail: "Ada Lovelace",
					date: try Date("2026-11-10T16:55:00Z", strategy: .iso8601)
				),
				.init(
					id: "tag:gmail.google.com,2004:2",
					title: "Your invoice",
					detail: "billing@example.com",
					date: try Date("2026-11-10T15:00:00Z", strategy: .iso8601)
				),
			],
			total: 12
		))

		#expect(SidebarMailPreviews.preview(fromScriptValue: "null") == nil)
		#expect(SidebarMailPreviews.preview(fromScriptValue: #""<html><body>Sign in</body></html>""#) == nil)
		#expect(SidebarMailPreviews.preview(fromScriptValue: #""not xml""#) == nil)
	}

	@Test
	internal func theFeedScriptOnlyFetchesTheAccountsFeedFromThePagesOrigin() {
		let script = SidebarMailPreviews.feedScript(account: 3)
		#expect(script.contains(#"fetch("/mail/u/3/feed/atom""#))
		#expect(script.contains("same-origin"))
		#expect(script.contains("location.origin"))
		#expect(!script.contains("document."))
	}

	@Test
	@MainActor
	internal func gmailIsReadOnlyFromItsOpenPageAndCachedForAMinute() async throws {
		let tab = BrowserCore.Tab.ID(rawValue: UUID(301))
		let feed = #"<feed xmlns="http://purl.org/atom/ns#"><fullcount>0</fullcount></feed>"#
		var url: URL? = nil
		var reads: [String] = []
		let clients = SidebarPreviewClients(
			snapshot: { _ in url.map { .init(navigation: .init(url: $0), revision: 1) } },
			readScript: { _, script in
				reads.append(script)
				return String(decoding: try! JSONEncoder().encode(feed), as: UTF8.self)
			}
		)

		// Not open: nothing runs and the card says to open it.
		let closed = await SidebarMailPreviews.shared.preview(for: tab, account: 0, clients: clients)
		expectNoDifference(closed, .init(kind: .mail, needsOpenPage: true))

		// Open on another site: still nothing runs.
		url = URL(string: "https://accounts.google.com/signin")
		#expect(await SidebarMailPreviews.shared.preview(for: tab, account: 0, clients: clients)?.needsOpenPage == true)
		#expect(reads.isEmpty)

		url = URL(string: "https://mail.google.com/mail/u/0/#inbox")
		let open = await SidebarMailPreviews.shared.preview(for: tab, account: 0, clients: clients)
		expectNoDifference(open, .init(kind: .mail, total: 0))
		_ = await SidebarMailPreviews.shared.preview(for: tab, account: 0, clients: clients)
		#expect(reads.count == 1)
	}
}
