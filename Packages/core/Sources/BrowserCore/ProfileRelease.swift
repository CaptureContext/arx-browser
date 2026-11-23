import Foundation

/// What keeps an ordinary profile loaded in the engine (DEV-880).
///
/// Arx loads a profile the first time something needs it: a window shows it, a page opens in
/// it, or Settings, a download or an assistant works in it. Each set names the profiles one
/// kind of use holds right now.
public struct ProfileUse: Equatable, Sendable {
	/// Shown in a window, a Little Arx or a peek, open in a Settings sheet, running an
	/// assistant turn, or waiting on a password save prompt.
	public var app: Set<Profile.ID>

	/// With a page, including one still opening.
	public var pages: Set<Profile.ID>

	/// With a download that hasn't finished.
	public var downloads: Set<Profile.ID>

	/// With engine work in flight: a settings read, an import, a download starting, or a
	/// profile being retired.
	public var work: Set<Profile.ID>

	public init(
		app: Set<Profile.ID> = [],
		pages: Set<Profile.ID> = [],
		downloads: Set<Profile.ID> = [],
		work: Set<Profile.ID> = []
	) {
		self.app = app
		self.pages = pages
		self.downloads = downloads
		self.work = work
	}

	/// Every profile something uses now.
	public var all: Set<Profile.ID> {
		app.union(pages).union(downloads).union(work)
	}

	/// Whether anything uses the profile now.
	public func holds(_ profile: Profile.ID) -> Bool {
		app.contains(profile)
			|| pages.contains(profile)
			|| downloads.contains(profile)
			|| work.contains(profile)
	}
}

/// When Arx lets an unused profile go (DEV-880).
///
/// A loaded profile that nothing uses (``ProfileUse``) and that nothing has used for the
/// whole grace period is released: the engine unloads it, and the next use loads it again.
public struct ProfileRelease: Equatable, Sendable {
	/// As Ardia does: a minute after the last use.
	public static let defaultGracePeriod: Duration = .seconds(60)

	public var gracePeriod: Duration

	public init(gracePeriod: Duration = Self.defaultGracePeriod) {
		self.gracePeriod = gracePeriod
	}

	/// How often to look for idle profiles: often enough that one goes within a quarter of
	/// the grace period after it's due, and never more than once a second.
	public var sweepInterval: Duration {
		max(.seconds(1), gracePeriod / 4)
	}

	/// The loaded profiles to release now.
	///
	/// - Parameters:
	///   - lastUse: Each loaded profile and when something last used it.
	///   - use: What uses profiles now.
	///   - now: The time of this check, on the same clock as `lastUse`.
	public func idle(
		lastUse: [Profile.ID: ContinuousClock.Instant],
		use: ProfileUse,
		now: ContinuousClock.Instant
	) -> Set<Profile.ID> {
		Set(
			lastUse
				.filter { profile, used in
					!use.holds(profile) && used.duration(to: now) >= gracePeriod
				}
				.keys
		)
	}
}
