import BrowserCore
import Foundation
import _Dependencies

/// Pictures and site details for hover cards of pages that aren't loaded (DEV-730).
///
/// Saved pictures belong to one ordinary profile each and stay on this Mac. Site details are
/// requested from the page's own site, without cookies or, with `PageFetchCredentials`
/// (DEV-1142), with the cookies the tab's profile sends that host, and kept in memory only.
public struct BrowserPagePreviewClient: Sendable {
	/// The saved picture of a page in its profile, as JPEG, with when it was taken.
	public var picture: @Sendable (BrowserPagePreviewKey) async -> BrowserPagePicture?

	/// Saves a picture of a page in its profile, replacing an older one. `takenAt` is when the
	/// capture started: a picture started before the profile's pictures were deleted is refused.
	public var store: @Sendable (BrowserPagePicture, BrowserPagePreviewKey) async -> Void

	/// Keeps only these pages' pictures in the listed profiles.
	public var retain: @Sendable (Set<BrowserPagePreviewKey>, Set<Profile.ID>) async -> Void

	/// Deletes a profile's pictures taken at or after a moment, or all of them for nil. Clearing
	/// a profile's history calls it.
	public var removeSince: @Sendable (Profile.ID, Date?) async -> Void

	/// Deletes removed profiles' pictures.
	public var removeProfiles: @Sendable (Set<Profile.ID>) async -> Void

	/// What the page's site publishes about it (Open Graph). Cookies go only with credentials,
	/// and only to the page's own host.
	public var details: @Sendable (URL, PageFetchCredentials?) async -> PageDetails?

	/// The bytes of a picture a site published, bounded. Cookies go only with credentials, and
	/// only when the picture is on the page's own host.
	public var image: @Sendable (URL, PageFetchCredentials?) async -> Data?

	public init(
		picture: @escaping @Sendable (BrowserPagePreviewKey) async -> BrowserPagePicture? = { _ in nil },
		store: @escaping @Sendable (BrowserPagePicture, BrowserPagePreviewKey) async -> Void = { _, _ in },
		retain: @escaping @Sendable (Set<BrowserPagePreviewKey>, Set<Profile.ID>) async -> Void = { _, _ in },
		removeSince: @escaping @Sendable (Profile.ID, Date?) async -> Void = { _, _ in },
		removeProfiles: @escaping @Sendable (Set<Profile.ID>) async -> Void = { _ in },
		details: @escaping @Sendable (URL, PageFetchCredentials?) async -> PageDetails? = { _, _ in nil },
		image: @escaping @Sendable (URL, PageFetchCredentials?) async -> Data? = { _, _ in nil }
	) {
		self.picture = picture
		self.store = store
		self.retain = retain
		self.removeSince = removeSince
		self.removeProfiles = removeProfiles
		self.details = details
		self.image = image
	}
}

extension BrowserPagePreviewClient {
	/// Pictures saved under `directory`, one folder per profile, and details from `fetcher`.
	public static func live(
		directory: URL,
		fetcher: PageDetailsFetcher = .init()
	) -> Self {
		let store = BrowserPagePreviewStore(directory: directory)
		return .init(
			picture: { await store.picture(for: $0) },
			store: { await store.store($0, for: $1) },
			retain: { await store.retain($0, in: $1) },
			removeSince: { await store.remove($0, since: $1) },
			removeProfiles: { await store.remove($0) },
			details: { await fetcher.details(for: $0, credentials: $1) },
			image: { await fetcher.image(at: $0, credentials: $1) }
		)
	}
}

/// A page in one profile. Pictures are never read across profiles.
public struct BrowserPagePreviewKey: Hashable, Sendable {
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

/// A saved picture of a page.
public struct BrowserPagePicture: Equatable, Sendable {
	public var jpeg: Data
	public var takenAt: Date

	public init(
		jpeg: Data,
		takenAt: Date
	) {
		self.jpeg = jpeg
		self.takenAt = takenAt
	}
}

extension BrowserPagePreviewClient: DependencyKey {
	public static var liveValue: Self { .init() }
	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var browserPagePreviews: BrowserPagePreviewClient {
		get { self[BrowserPagePreviewClient.self] }
		set { self[BrowserPagePreviewClient.self] = newValue }
	}
}
