#if DEBUG
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// `make profile-release-smoke` (DEV-880): four profiles, one shown. Launch loads only the shown
/// one; the others load on first use, without a page and with one, and are released once
/// they've gone unused for the grace period. A setting changed before the release is still
/// there when the profile loads again. Chromium itself destroys the released profiles
/// (`OnProfileWillBeDestroyed`, through `isLoadedInChromium`), and a session cookie a page set
/// before its profile went is still there when the page opens again. A fourth profile is never
/// used and never loads.
internal enum ProfileReleaseSmoke {
	internal enum Failure: String, Error {
		case missingConfiguration
		case launchLoadedOthers
		case firstUseNotLoaded
		case releasedTooSoon
		case notReleased
		case notDestroyed
		case settingLost
		case sessionLost
		case existingProfile
		case timedOut
	}

	/// The fixture page's titles (`profile_release_smoke.py`): it sets a session cookie the
	/// first time and reports finding it after.
	internal static let cookieSetTitle: String = "Arx profile release: set"
	internal static let cookieKeptTitle: String = "Arx profile release: kept"

	internal static let variable: String = "ARX_PROFILE_RELEASE_SMOKE"
	internal static let urlVariable: String = "ARX_PROFILE_RELEASE_SMOKE_URL"

	internal static let shown: Profile.ID = id(1)
	internal static let settings: Profile.ID = id(2)
	internal static let page: Profile.ID = id(3)
	internal static let untouched: Profile.ID = id(4)
	internal static let shownTab: BrowserCore.Tab.ID = .init(rawValue: id(5).rawValue)
	internal static let pageTab: BrowserCore.Tab.ID = .init(rawValue: id(6).rawValue)

	internal static func isRequested(environment: [String: String]) -> Bool {
		environment[variable] == "1"
	}

	/// Writes the four-profile workspace into the run's fresh profile directory. A directory with
	/// anything in it is refused, so a mistaken launch can't replace a real workspace.
	internal static func seedWorkspace(environment: [String: String]) throws {
		guard
			isRequested(environment: environment),
			let profile = environment["ARX_ENGINE_PROFILE"],
			profile.hasPrefix("/"),
			let url = environment[urlVariable].flatMap(URL.init(string:)),
			url.host == "127.0.0.1"
		else { throw Failure.missingConfiguration }

		let directory = URL(fileURLWithPath: profile).standardizedFileURL
		var isDirectory: ObjCBool = false
		guard
			FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
			isDirectory.boolValue,
			try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty
		else { throw Failure.existingProfile }

		let profiles = [shown, settings, page, untouched]
		let spaces: [Space] = profiles.enumerated().map { index, profile in
			let tab: BrowserCore.Tab.ID? = switch profile {
			case shown: shownTab
			case page: pageTab
			default: nil
			}
			return .init(
				id: .init(rawValue: id(10 + index).rawValue),
				profileID: profile,
				name: "Space \(index + 1)",
				unpinnedTabs: tab.map { [$0] } ?? [],
				selectedTabID: tab
			)
		}
		let organization = BrowserOrganization(
			profiles: profiles.enumerated().map { .init(id: $1, name: "Profile \($0 + 1)") },
			legacyProfileID: shown,
			spaces: spaces,
			tabs: [
				.init(id: shownTab, profileID: shown, restoration: .init(title: "Shown", url: url)),
				.init(id: pageTab, profileID: page, restoration: .init(title: "Page", url: url)),
			]
		)
		try BrowserWorkspaceClient(file: directory.appendingPathComponent("arx-workspace.json"))
			.save(organization)
	}

	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		environment: [String: String]
	) async throws {
		let release = ProfileRelease.configured(environment: environment)
		guard
			release.gracePeriod <= .seconds(30),
			let tab = store.workspace.tabs[id: pageTab]
		else { throw Failure.missingConfiguration }
		let client = engine.client

		// Launch: the shown profile only, and it stays loaded across sweeps.
		try await wait(for: .seconds(30)) { engine.loadedProfiles.contains(shown) }
		try await Task.sleep(for: release.gracePeriod + release.sweepInterval * 2)
		guard
			engine.loadedProfiles == [shown],
			engine.isLoadedInChromium(shown) == true,
			[settings, page, untouched].allSatisfy({ engine.isLoadedInChromium($0) == false })
		else { throw Failure.launchLoadedOthers }
		print("ARX_PROFILE_RELEASE_PHASE_LAUNCH")

		// First use without a page: a profile setting, as Settings › Downloads changes it.
		let original = try await client.downloadSettings(settings)
		_ = try await client.changeDownloadSettings(settings, nil, !original.asksWhereToSave)

		// First use with a page, which sets a session cookie and then closes.
		try await client.open(tab)
		try await wait(for: .seconds(30)) { loaded(client, title: cookieSetTitle) }
		client.close(pageTab)
		let lastUse = ContinuousClock.now
		guard engine.loadedProfiles == [shown, settings, page]
		else { throw Failure.firstUseNotLoaded }
		print("ARX_PROFILE_RELEASE_PHASE_FIRST_USE")

		// Both go once they've been unused for the grace period; the shown one stays.
		try await wait(for: release.gracePeriod * 3 + .seconds(10)) {
			!engine.loadedProfiles.contains(settings) || !engine.loadedProfiles.contains(page)
		}
		guard lastUse.duration(to: .now) >= release.gracePeriod - release.sweepInterval
		else { throw Failure.releasedTooSoon }
		try await wait(for: release.gracePeriod + .seconds(10)) { engine.loadedProfiles == [shown] }
		print("ARX_PROFILE_RELEASE_PHASE_RELEASED")

		// Chromium destroys both profiles, not just Arx's record of them; the shown one lives.
		do {
			try await wait(for: .seconds(30)) {
				engine.isLoadedInChromium(settings) == false && engine.isLoadedInChromium(page) == false
			}
		} catch {
			throw Failure.notDestroyed
		}
		guard engine.isLoadedInChromium(shown) == true else { throw Failure.notDestroyed }
		print("ARX_PROFILE_RELEASE_PHASE_DESTROYED")

		// Used again, the profile loads again with what it saved before it went.
		let reloaded = try await client.downloadSettings(settings)
		guard
			reloaded.asksWhereToSave != original.asksWhereToSave,
			engine.loadedProfiles == [shown, settings],
			engine.isLoadedInChromium(settings) == true
		else { throw Failure.settingLost }
		_ = try await client.changeDownloadSettings(settings, nil, original.asksWhereToSave)
		print("ARX_PROFILE_RELEASE_PHASE_RELOADED")

		// The page's session didn't end with the release: its session cookie is still there.
		try await client.open(tab)
		do {
			try await wait(for: .seconds(30)) {
				client.snapshot(pageTab)?.navigation.isLoading == false
					&& client.snapshot(pageTab)?.navigation.title.hasPrefix("Arx profile release") == true
			}
		} catch {
			throw Failure.sessionLost
		}
		guard loaded(client, title: cookieKeptTitle) else { throw Failure.sessionLost }
		client.close(pageTab)
		print("ARX_PROFILE_RELEASE_PHASE_SESSION_KEPT")

		guard !engine.loadedProfiles.contains(untouched) else { throw Failure.launchLoadedOthers }
		print("ARX_PROFILE_RELEASE_SMOKE_SUCCESS")
		fflush(stdout)
	}

	private static func id(_ value: Int) -> Profile.ID {
		.init(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!)
	}

	@MainActor
	private static func loaded(
		_ client: BrowserEngineClient,
		title: String
	) -> Bool {
		guard let navigation = client.snapshot(pageTab)?.navigation else { return false }
		return !navigation.isLoading && navigation.title == title
	}

	@MainActor
	private static func wait(
		for limit: Duration,
		until ready: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now + limit
		while !ready() {
			guard ContinuousClock.now < deadline else { throw Failure.timedOut }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
