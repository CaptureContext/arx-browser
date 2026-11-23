import AppKit
import BrowserCore
import Foundation

/// A password saved in an ordinary profile, as Settings lists it (DEV-721).
/// The password itself stays in the engine.
public struct BrowserSavedPassword: Equatable, Identifiable, Sendable {
	public var id: UInt32

	/// The host it was saved for.
	public var site: String
	public var origin: String
	public var username: String

	public init(
		id: UInt32,
		site: String,
		origin: String,
		username: String
	) {
		self.id = id
		self.site = site
		self.origin = origin
		self.username = username
	}
}

/// A site the user chose never to save a password for.
public struct BrowserNeverSavedSite: Equatable, Identifiable, Sendable {
	public var id: UInt32
	public var site: String
	public var origin: String

	public init(
		id: UInt32,
		site: String,
		origin: String
	) {
		self.id = id
		self.site = site
		self.origin = origin
	}
}

/// One profile's saved passwords and "never saved" sites. IDs belong to
/// `listing`; any change makes a new listing and the old IDs stale.
public struct BrowserSavedPasswordList: Equatable, Sendable {
	public var listing: String
	public var passwords: [BrowserSavedPassword]
	public var neverSaved: [BrowserNeverSavedSite]

	public init(
		listing: String = "",
		passwords: [BrowserSavedPassword] = [],
		neverSaved: [BrowserNeverSavedSite] = []
	) {
		self.listing = listing
		self.passwords = passwords
		self.neverSaved = neverSaved
	}
}

/// What a CSV import did. Rows name a site and a username, never a password.
public struct BrowserPasswordImportSummary: Equatable, Sendable {
	public struct Row: Equatable, Sendable {
		public enum Reason: String, Equatable, Sendable {
			case missingPassword
			case missingURL
			case invalidURL
			case tooLong
			case unknown
		}

		public var site: String
		public var username: String

		/// Why a skipped row was skipped; nil for a conflict.
		public var reason: Reason?

		public init(
			site: String,
			username: String,
			reason: Reason? = nil
		) {
			self.site = site
			self.username = username
			self.reason = reason
		}
	}

	public var imported: Int

	/// Rows whose site and username were already saved. The saved password was kept.
	public var conflicts: [Row]
	public var conflictCount: Int
	public var skipped: [Row]
	public var skippedCount: Int

	public init(
		imported: Int,
		conflicts: [Row] = [],
		conflictCount: Int = 0,
		skipped: [Row] = [],
		skippedCount: Int = 0
	) {
		self.imported = imported
		self.conflicts = conflicts
		self.conflictCount = conflictCount
		self.skipped = skipped
		self.skippedCount = skippedCount
	}
}

public enum BrowserSavedPasswordFailure: Error, Equatable, Sendable {
	/// No password manager in this engine, or a private, unknown or retiring profile.
	case unavailable
	case invalid

	/// The list changed since it was shown.
	case stale
	case notFound

	/// The site already has a password saved for that username.
	case exists

	/// The device owner didn't authenticate.
	case denied
	case busy

	/// The CSV file couldn't be read.
	case unreadableFile

	/// The CSV file has no recognizable header.
	case badFormat
	case fileTooLarge
	case tooManyPasswords
	case failed
}

/// An AppKit text field Settings lends the engine for a password (DEV-721). The
/// engine reads a typed password from it, or writes a revealed one into it, so
/// the value never passes through Swift state.
public struct BrowserPasswordFieldID: Hashable, Sendable {
	public var rawValue: UUID

	public init(rawValue: UUID) {
		self.rawValue = rawValue
	}
}

/// The fields currently lent, held weakly. A view registers its field while it
/// is in a window and unregisters it when it goes away.
@MainActor
public enum BrowserPasswordFields {
	private final class Entry {
		internal weak var field: NSTextField?

		internal init(_ field: NSTextField) {
			self.field = field
		}
	}

	private static var entries: [BrowserPasswordFieldID: Entry] = [:]

	public static func register(
		_ field: NSTextField,
		as id: BrowserPasswordFieldID
	) {
		entries = entries.filter { $0.value.field != nil }
		entries[id] = .init(field)
	}

	public static func unregister(_ id: BrowserPasswordFieldID) {
		entries[id] = nil
	}

	public static func field(_ id: BrowserPasswordFieldID) -> NSTextField? {
		entries[id]?.field
	}
}

public enum BrowserPasswordReveal: Equatable, Sendable {
	/// Onto the pasteboard, concealed, cleared after a minute unless it changed.
	case copy

	/// Into a lent field.
	case show(BrowserPasswordFieldID)
}

/// What to save: a new password for a site, or an edit of a listed one.
public struct BrowserPasswordEdit: Equatable, Sendable {
	public enum Target: Equatable, Sendable {
		case new(url: String)
		case existing(listing: String, id: UInt32)
	}

	public var profileID: Profile.ID
	public var target: Target
	public var username: String

	/// The field holding the password; nil keeps the saved one on an edit.
	public var passwordField: BrowserPasswordFieldID?

	public init(
		profileID: Profile.ID,
		target: Target,
		username: String,
		passwordField: BrowserPasswordFieldID?
	) {
		self.profileID = profileID
		self.target = target
		self.username = username
		self.passwordField = passwordField
	}
}

extension BrowserEngineClient {
	public typealias SavedPasswords = @MainActor @Sendable (
		Profile.ID
	) async throws(BrowserSavedPasswordFailure) -> BrowserSavedPasswordList

	public typealias SavePassword = @MainActor @Sendable (
		BrowserPasswordEdit
	) async throws(BrowserSavedPasswordFailure) -> BrowserSavedPasswordList

	public typealias RemoveSavedPassword = @MainActor @Sendable (
		Profile.ID,
		_ listing: String,
		_ id: UInt32
	) async throws(BrowserSavedPasswordFailure) -> BrowserSavedPasswordList

	public typealias RevealSavedPassword = @MainActor @Sendable (
		Profile.ID,
		_ listing: String,
		_ id: UInt32,
		_ reason: String,
		BrowserPasswordReveal
	) async throws(BrowserSavedPasswordFailure) -> Void

	public typealias ImportPasswords = @MainActor @Sendable (
		Profile.ID,
		URL
	) async throws(BrowserSavedPasswordFailure) -> BrowserPasswordImportSummary
}
