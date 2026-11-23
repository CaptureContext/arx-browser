import Foundation

// MARK: - Channel

extension AppUpdaterClient {
	/// Which releases Arx updates to (DEV-888).
	///
	/// Stable reads `SUFeedURL`, which lists the newest stable release. Beta reads
	/// `ArxBetaFeedURL`, which lists the newest release of either channel, so people on Beta get
	/// stable releases too. Switching back to Stable never downgrades: Arx keeps the build it has
	/// until a stable release with a higher build number comes out.
	public enum Channel: String, CaseIterable, Codable, Equatable, Sendable {
		case stable
		case beta

		/// The user defaults key the chosen channel is kept under.
		public static let preferenceKey: String = "ArxUpdateChannel"

		/// The channel to use: the person's choice if they made one, otherwise the channel this
		/// build was made for. Without a beta feed, Stable is the only channel.
		public static func resolve(
			stored: String?,
			buildDefault: Self,
			offersBeta: Bool
		) -> Self {
			guard offersBeta
			else { return .stable }

			return stored.flatMap(Self.init(rawValue:)) ?? buildDefault
		}
	}
}

// MARK: - Feeds

extension AppUpdaterClient.Configuration {
	public static let betaFeedURLKey: String = "ArxBetaFeedURL"
	public static let channelKey: String = "ArxUpdateChannel"

	/// The beta feed, when it's a real HTTPS URL that isn't the stable feed.
	public var betaFeed: URL? {
		guard
			let beta = Self.feed(from: betaFeedURL),
			beta != Self.feed(from: feedURL)
		else { return nil }

		return beta
	}

	/// Whether Settings offers the Beta channel.
	public var offersBeta: Bool {
		betaFeed != nil
	}

	/// The feed Sparkle reads for a channel. Beta falls back to the stable feed when the build has
	/// no beta feed.
	public func feed(for channel: AppUpdaterClient.Channel) -> URL? {
		switch channel {
		case .stable:
			return Self.feed(from: feedURL)

		case .beta:
			return betaFeed ?? Self.feed(from: feedURL)
		}
	}
}
