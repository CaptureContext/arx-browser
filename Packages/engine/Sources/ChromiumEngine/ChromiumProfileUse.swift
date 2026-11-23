import Foundation

/// DEV-880. What the engine knows about one prepared ordinary profile's use.
public struct ChromiumProfileUse: Equatable, Sendable {
	/// When something last prepared the profile or finished engine work in it.
	public var lastUse: ContinuousClock.Instant

	/// Engine work in the profile is in flight: a settings read or change, an import,
	/// a download starting, or an extension request.
	public var isHeld: Bool

	/// A download in the profile hasn't finished, or Chromium hasn't listed the profile's
	/// downloads yet since it loaded.
	public var hasDownloads: Bool

	public init(
		lastUse: ContinuousClock.Instant,
		isHeld: Bool = false,
		hasDownloads: Bool = false
	) {
		self.lastUse = lastUse
		self.isHeld = isHeld
		self.hasDownloads = hasDownloads
	}
}
