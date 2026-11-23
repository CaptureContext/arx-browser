import BrowserCore
import Foundation
import _Dependencies

/// Presentation-only images from the owning ordinary profile's favicon database, backed by
/// the app's per-profile ``BrowserSiteIconStore`` for pages that aren't loaded.
public struct BrowserSiteIconClient: Sendable {
	public var configureProfiles: @MainActor @Sendable (Set<Profile.ID>) -> Void

	/// A shown icon: one neither Arx nor Chromium has yet is fetched from its site.
	public var icons: @MainActor @Sendable (BrowserSiteIconKey) -> AsyncStream<Data?>

	/// The same icons, but a missing one is never fetched from its site: for views that are
	/// mounted but not on screen, such as a neighbouring space's rows. It is fetched once a
	/// view showing it asks through `icons`.
	public var cachedIcons: @MainActor @Sendable (BrowserSiteIconKey) -> AsyncStream<Data?>

	/// Deletes removed profiles' stored icons (DEV-809).
	public var removeProfiles: @MainActor @Sendable (Set<Profile.ID>) -> Void

	/// Whether a page that isn't loaded may have its icon fetched from its site when the
	/// profile has none yet (DEV-796). On by default.
	public var setFetchesUnloadedIcons: @MainActor @Sendable (Bool) -> Void

	/// Icons another browser showed for these pages, kept until the pages show their own
	/// (DEV-897). A page that already has a stored icon keeps it.
	public var seed: @MainActor @Sendable ([BrowserSiteIconKey: Data]) -> Void

	public init(
		configureProfiles: @escaping @MainActor @Sendable (Set<Profile.ID>) -> Void = { _ in },
		icons: @escaping @MainActor @Sendable (BrowserSiteIconKey) -> AsyncStream<Data?> = { _ in
			.finished
		},
		cachedIcons: @escaping @MainActor @Sendable (BrowserSiteIconKey) -> AsyncStream<Data?> = { _ in
			.finished
		},
		removeProfiles: @escaping @MainActor @Sendable (Set<Profile.ID>) -> Void = { _ in },
		setFetchesUnloadedIcons: @escaping @MainActor @Sendable (Bool) -> Void = { _ in },
		seed: @escaping @MainActor @Sendable ([BrowserSiteIconKey: Data]) -> Void = { _ in }
	) {
		self.configureProfiles = configureProfiles
		self.icons = icons
		self.cachedIcons = cachedIcons
		self.removeProfiles = removeProfiles
		self.setFetchesUnloadedIcons = setFetchesUnloadedIcons
		self.seed = seed
	}
}

extension BrowserSiteIconClient {
	/// This client with every icon read as `cachedIcons`, for a run whose views nobody sees,
	/// such as a headless one.
	public var neverFetching: Self {
		var client = self
		client.icons = cachedIcons
		return client
	}
}

public struct BrowserSiteIconKey: Hashable, Sendable {
	public let profileID: Profile.ID
	public let pageURL: URL

	public init(
		profileID: Profile.ID,
		pageURL: URL
	) {
		self.profileID = profileID
		self.pageURL = pageURL
	}
}

extension BrowserSiteIconClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserSiteIcons: BrowserSiteIconClient {
		get { self[BrowserSiteIconClient.self] }
		set { self[BrowserSiteIconClient.self] = newValue }
	}
}
