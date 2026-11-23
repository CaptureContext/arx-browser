import BrowserCore
import CustomDump
import Foundation
@testable import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-1001: Settings › Advanced's site lists add and edit through a form, not an inline field.
@MainActor
@Suite(.dependencies)
internal struct SettingsSiteFormTests {
	private static let work = Profile.ID(rawValue: UUID(1))
	private static let home = Profile.ID(rawValue: UUID(2))

	private static func store(sites: [String] = ["netflix.com"]) -> TestStoreOf<SettingsFeature> {
		let state = SettingsFeature.State()
		state.$webKitPages.withLock { $0 = .init(sites: sites) }
		return TestStore(initialState: state) {
			SettingsFeature()
		}
	}

	@Test
	internal func addingAWebKitSiteKeepsTheFormUntilTheSiteIsValid() async throws {
		let store = Self.store()
		await store.send(.ui(.siteDraft(.new(.webKit, profileID: Self.work)))) {
			$0.siteDraft = .init(list: .webKit)
		}
		#expect(store.state.siteDraft?.isValid == false)

		await store.send(.ui(.siteDraft(.changed(.init(list: .webKit, site: "not a site"))))) {
			$0.siteDraft?.site = "not a site"
		}
		await store.send(.ui(.siteDraft(.save))) {
			$0.siteDraft?.error = .invalidSite
		}

		await store.send(.ui(.siteDraft(.changed(.init(list: .webKit, site: "https://www.Max.com/browse"))))) {
			$0.siteDraft = .init(list: .webKit, site: "https://www.Max.com/browse")
		}
		await store.send(.ui(.siteDraft(.save))) {
			$0.siteDraft = nil
			$0.$webKitPages.withLock { $0.sites = ["netflix.com", "www.max.com"] }
		}
	}

	@Test
	internal func aWebKitSiteAlreadyListedShowsAMessage() async throws {
		let store = Self.store(sites: ["netflix.com", "max.com"])
		await store.send(.ui(.siteDraft(.edit(.webKit, site: "max.com", profileID: nil)))) {
			$0.siteDraft = .init(list: .webKit, site: "max.com", original: .init(site: "max.com"))
		}
		var draft = try #require(store.state.siteDraft)
		draft.site = "netflix.com"
		await store.send(.ui(.siteDraft(.changed(draft)))) {
			$0.siteDraft?.site = "netflix.com"
		}
		await store.send(.ui(.siteDraft(.save))) {
			$0.siteDraft?.error = .duplicate
		}
		await store.send(.ui(.siteDraft(.cancel))) {
			$0.siteDraft = nil
		}
		expectNoDifference(store.state.webKitPages.sites, ["netflix.com", "max.com"])
	}

	@Test
	internal func editingAWebKitSiteReplacesItInPlaceAndDeleteRemovesIt() async throws {
		let store = Self.store(sites: ["netflix.com", "max.com", "spotify.com"])
		await store.send(.ui(.siteDraft(.edit(.webKit, site: "max.com", profileID: nil)))) {
			$0.siteDraft = .init(list: .webKit, site: "max.com", original: .init(site: "max.com"))
		}
		var draft = try #require(store.state.siteDraft)
		draft.site = "hbomax.com"
		await store.send(.ui(.siteDraft(.changed(draft)))) {
			$0.siteDraft?.site = "hbomax.com"
		}
		await store.send(.ui(.siteDraft(.save))) {
			$0.siteDraft = nil
			$0.$webKitPages.withLock { $0.sites = ["netflix.com", "hbomax.com", "spotify.com"] }
		}

		await store.send(.ui(.siteDraft(.edit(.webKit, site: "spotify.com", profileID: nil)))) {
			$0.siteDraft = .init(list: .webKit, site: "spotify.com", original: .init(site: "spotify.com"))
		}
		await store.send(.ui(.siteDraft(.delete))) {
			$0.siteDraft = nil
			$0.$webKitPages.withLock { $0.sites = ["netflix.com", "hbomax.com"] }
		}
	}

	@Test
	internal func aKeptLoadedSiteIsAddedToItsProfile() async throws {
		let store = Self.store()
		await store.send(.ui(.siteDraft(.new(.keptLoaded, profileID: Self.work)))) {
			$0.siteDraft = .init(list: .keptLoaded, profileID: Self.work)
		}
		await store.send(.ui(.siteDraft(.changed(.init(list: .keptLoaded, site: "Music.example.com", profileID: Self.home))))) {
			$0.siteDraft = .init(list: .keptLoaded, site: "Music.example.com", profileID: Self.home)
		}
		await store.send(.ui(.siteDraft(.save))) {
			$0.siteDraft = nil
		}
		await store.receive(\.ui.changeOrganization) {
			$0.isManagingOrganization = true
		}
		await store.receive(\.delegate.changeOrganization, .setKeptLoadedSite(Self.home, site: "music.example.com", kept: true))
	}

	@Test
	internal func editingAKeptLoadedSiteReplacesItInOneChange() async throws {
		let store = Self.store()
		await store.send(.ui(.siteDraft(.edit(.keptLoaded, site: "mail.example", profileID: Self.work)))) {
			$0.siteDraft = .init(
				list: .keptLoaded,
				site: "mail.example",
				profileID: Self.work,
				original: .init(site: "mail.example", profileID: Self.work)
			)
		}
		var draft = try #require(store.state.siteDraft)
		draft.profileID = Self.home
		await store.send(.ui(.siteDraft(.changed(draft)))) {
			$0.siteDraft?.profileID = Self.home
		}
		await store.send(.ui(.siteDraft(.save))) {
			$0.siteDraft = nil
		}
		await store.receive(\.ui.changeOrganization) {
			$0.isManagingOrganization = true
		}
		await store.receive(
			\.delegate.changeOrganization,
			.replaceKeptLoadedSite(Self.work, site: "mail.example", newProfile: Self.home, newSite: "mail.example")
		)
	}
}
