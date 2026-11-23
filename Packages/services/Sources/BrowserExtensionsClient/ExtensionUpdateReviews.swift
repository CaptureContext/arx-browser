import BrowserCore
import Foundation
import Sharing

/// Store updates that ask for more permissions, found by the automatic check, waiting for the
/// person's review (DEV-1210), and the offers they declined.
///
/// The automatic check (every five hours) turns such an update down without asking. It's
/// remembered per profile and extension, so the Extensions sheet, Settings and the site menu can
/// mark it until the person reviews it. Declining an offer keeps the installed version and
/// remembers that version, so the same offer is never marked again; a newer one is. A mark goes
/// once the extension's installed version changes in any way, or the extension is gone.
///
/// Kept in user defaults (`extensionUpdateReviews`) for the Mac, never in the workspace: it's
/// about what the store offered this Mac's engine.
public struct ExtensionUpdateReviews: Equatable, Sendable {
	/// One extension's offer: the version installed when it was found, and what the store offers.
	public struct Review: Equatable, Sendable, Codable, Identifiable {
		public var profileID: Profile.ID
		public var extensionID: String

		/// The installed version the offer would replace. Another installed version means the
		/// extension changed some other way, and the review no longer applies.
		public var installedVersion: String

		/// The version the store offers.
		public var version: String

		/// The permissions the offered version asks for: its API permissions, then its hosts.
		public var permissions: [String]

		public init(
			profileID: Profile.ID,
			extensionID: String,
			installedVersion: String,
			version: String,
			permissions: [String]
		) {
			self.profileID = profileID
			self.extensionID = extensionID
			self.installedVersion = installedVersion
			self.version = version
			self.permissions = permissions
		}

		public init(
			_ candidate: BrowserExtensionInstallPrompt.Candidate,
			profileID: Profile.ID,
			installedVersion: String
		) {
			self.init(
				profileID: profileID,
				extensionID: candidate.extensionID,
				installedVersion: installedVersion,
				version: candidate.version,
				permissions: candidate.requiredPermissions.apis + candidate.requiredPermissions.hosts
			)
		}

		public var id: String { profileID.rawValue.uuidString + "/" + extensionID }

		fileprivate func isSameExtension(as other: Self) -> Bool {
			profileID == other.profileID && extensionID == other.extensionID
		}
	}

	/// The most each list keeps; the oldest goes first. Each holds an entry per profile and
	/// extension at most.
	public static let limit: Int = 64

	/// Offers waiting for the person's review, oldest first.
	public private(set) var pending: [Review]

	/// Offers the person declined in the review, oldest first.
	public private(set) var declined: [Review]

	public init(
		pending: [Review] = [],
		declined: [Review] = []
	) {
		self.pending = pending
		self.declined = declined
	}

	/// The offers waiting in one profile, oldest first.
	public func pending(in profileID: Profile.ID) -> [Review] {
		pending.filter { $0.profileID == profileID }
	}

	/// The offer waiting for one extension of a profile, if any.
	public func review(
		_ extensionID: String,
		in profileID: Profile.ID
	) -> Review? {
		pending.first { $0.profileID == profileID && $0.extensionID == extensionID }
	}

	/// Remembers an offer the automatic check turned down, unless the person already declined
	/// that very version. A newer offer replaces an older one's mark.
	public mutating func offered(_ review: Review) {
		guard !declined.contains(where: { $0.isSameExtension(as: review) && $0.version == review.version })
		else { return }

		pending.removeAll { $0.isSameExtension(as: review) }
		pending.append(review)
		if pending.count > Self.limit { pending.removeFirst(pending.count - Self.limit) }
	}

	/// The person declined the offer in the review: the mark goes, and that version is never
	/// marked again.
	public mutating func declined(_ review: Review) {
		pending.removeAll { $0.isSameExtension(as: review) }
		declined.removeAll { $0.isSameExtension(as: review) }
		declined.append(review)
		if declined.count > Self.limit { declined.removeFirst(declined.count - Self.limit) }
	}

	/// The store offers nothing newer for the extension any more.
	public mutating func withdrawn(
		_ extensionID: String,
		in profileID: Profile.ID
	) {
		pending.removeAll { $0.profileID == profileID && $0.extensionID == extensionID }
	}

	/// Drops the profile's entries whose extension is gone or now has another installed version:
	/// it updated, was reinstalled or was removed some other way. Other profiles' entries stay,
	/// whatever this inventory holds.
	public mutating func reconcile(with inventory: BrowserExtensionInventory) {
		let versions = Dictionary(
			inventory.extensions.map { ($0.id, $0.version) },
			uniquingKeysWith: { first, _ in first }
		)
		func stillApplies(_ review: Review) -> Bool {
			review.profileID != inventory.profileID || versions[review.extensionID] == review.installedVersion
		}
		pending.removeAll { !stillApplies($0) }
		declined.removeAll { !stillApplies($0) }
	}
}

extension ExtensionUpdateReviews: RawRepresentable {
	private struct Stored: Codable {
		var pending: [Review]
		var declined: [Review]
	}

	/// JSON, for user defaults. Anything unreadable starts over with nothing marked.
	public init?(rawValue: String) {
		guard let stored = try? JSONDecoder().decode(Stored.self, from: Data(rawValue.utf8)) else { return nil }

		self.init(pending: stored.pending, declined: stored.declined)
	}

	public var rawValue: String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let data = (try? encoder.encode(Stored(pending: pending, declined: declined))) ?? Data()
		return String(decoding: data, as: UTF8.self)
	}

	/// By the lists, never by `rawValue`: `RawRepresentable` would otherwise compare the JSON.
	public static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.pending == rhs.pending && lhs.declined == rhs.declined
	}
}

extension SharedKey where Self == AppStorageKey<ExtensionUpdateReviews>.Default {
	/// Store updates waiting for review, and declined offers (DEV-1210).
	public static var extensionUpdateReviews: Self {
		Self[.appStorage("ArxExtensionUpdateReviews"), default: .init()]
	}
}
