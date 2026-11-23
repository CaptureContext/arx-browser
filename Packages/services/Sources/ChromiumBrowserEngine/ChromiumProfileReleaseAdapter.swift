import BrowserCore
import ChromiumEngine
import Foundation

extension ChromiumBrowserEngine {
	/// DEV-880. Whether Chromium still has a live profile for it, released ones included until
	/// Chromium destroys them. Nil when the engine can't say.
	public func isLoadedInChromium(_ profile: Profile.ID) -> Bool? {
		runtime.isLoadedInChromium(profile.chromiumProfile(legacy: legacyProfileID))
	}

	/// DEV-880. The ordinary profiles the engine has loaded now.
	public var loadedProfiles: Set<Profile.ID> {
		Set(runtime.preparedOrdinaryProfiles.keys.map { Profile.ID.chromium($0, legacy: legacyProfileID) })
	}

	/// DEV-880. Releases the loaded ordinary profiles that nothing has used for `gracePeriod`.
	///
	/// The app names the profiles it shows or works in; this adds the engine's own uses: pages,
	/// including ones still opening, unfinished downloads, engine work in flight and profiles
	/// being retired. ``ProfileRelease`` decides; native refuses anything it still sees in use.
	/// Returns the profiles released.
	internal func releaseIdleProfiles(
		usedByApp: Set<Profile.ID>,
		gracePeriod: Duration,
		now: ContinuousClock.Instant = .now
	) -> Set<Profile.ID> {
		guard runtime.supportsProfileRelease else { return [] }

		var use = ProfileUse(app: usedByApp, pages: Set(pageProfiles.values), work: retirementOperations)
		var lastUse: [Profile.ID: ContinuousClock.Instant] = [:]
		for (key, value) in runtime.preparedOrdinaryProfiles {
			let profile = Profile.ID.chromium(key, legacy: legacyProfileID)
			if value.isHeld { use.work.insert(profile) }
			if value.hasDownloads { use.downloads.insert(profile) }
			lastUse[profile] = max(value.lastUse, profilesLastSeenInUse[profile] ?? value.lastUse)
		}

		let idle = ProfileRelease(gracePeriod: gracePeriod).idle(lastUse: lastUse, use: use, now: now)

		// A profile's grace period starts when it stops being used, not when it was loaded.
		profilesLastSeenInUse = lastUse.filter { idle.contains($0.key) == false }
		for profile in use.all where lastUse[profile] != nil { profilesLastSeenInUse[profile] = now }

		var released: Set<Profile.ID> = []
		for profile in idle where runtime.releaseProfile(profile.chromiumProfile(legacy: legacyProfileID)) {
			released.insert(profile)
		}
		return released
	}
}
