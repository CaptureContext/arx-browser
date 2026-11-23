import BrowserCore
import Foundation

/// Where imported items go.
///
/// `profileID` and `spaceID` name an existing space, which receives anything
/// without its own route. A source space follows `routes`, then its profile's entry in
/// `profileRoutes`, then `defaultRoute`.
public struct MigrationDestination: Equatable, Hashable, Sendable {
	public var profileID: Profile.ID
	public var spaceID: Space.ID
	public var defaultRoute: MigrationRoute?
	public var routes: [MigrationSourceSpace.ID: MigrationRoute]

	/// Where each source profile goes, by `MigrationSourceProfile.ID` (DEV-842).
	public var profileRoutes: [String: MigrationProfileRoute]

	public init(
		profileID: Profile.ID,
		spaceID: Space.ID,
		defaultRoute: MigrationRoute? = nil,
		routes: [MigrationSourceSpace.ID: MigrationRoute] = [:],
		profileRoutes: [String: MigrationProfileRoute] = [:]
	) {
		self.profileID = profileID
		self.spaceID = spaceID
		self.defaultRoute = defaultRoute
		self.routes = routes
		self.profileRoutes = profileRoutes
	}
}

/// Where one source profile goes, with all its spaces, favorites and history (DEV-842).
public enum MigrationProfileRoute: Equatable, Hashable, Sendable {
	/// A new Arx profile. `name` replaces the source profile's name when it isn't empty.
	/// A profile an earlier run created is reused and keeps its name.
	case newProfile(name: String)

	/// An existing Arx profile. Each source space becomes a new space in it.
	case existingProfile(Profile.ID)
}

/// Where one source space goes.
public enum MigrationRoute: Equatable, Hashable, Sendable {
	/// A new space in a new Arx profile matching the source profile.
	case newProfile

	/// A new space in an existing profile.
	case newSpace(Profile.ID)

	/// An existing space. Pinned items go in a folder named after the source space.
	case existingSpace(Profile.ID, Space.ID)
}

/// What a commit would do, computed from a snapshot without writing anything.
public struct MigrationPreview: Equatable, Sendable {
	public var sourceID: MigrationSource.ID
	public var snapshotID: String
	public var destination: MigrationDestination
	public var categories: [Category]

	/// Source spaces found in the snapshot, in source order, for the user to route.
	public var spaces: [MigrationSourceSpace]

	/// Source profiles found in the snapshot, in source order, for the user to map.
	public var profiles: [MigrationSourceProfile]

	public init(
		sourceID: MigrationSource.ID,
		snapshotID: String,
		destination: MigrationDestination,
		categories: [Category],
		spaces: [MigrationSourceSpace] = [],
		profiles: [MigrationSourceProfile]? = nil
	) {
		self.sourceID = sourceID
		self.snapshotID = snapshotID
		self.destination = destination
		self.categories = categories
		self.spaces = spaces
		var seen: Set<String> = []
		self.profiles = profiles ?? spaces.map(\.profile).filter { seen.insert($0.id).inserted }
	}

	public var importableCount: Int {
		categories.reduce(0) { $0 + $1.items.count + ($1.preferences == nil ? 0 : 1) }
	}

	/// One category's planned outcome.
	public struct Category: Equatable, Sendable {
		public var category: MigrationCategory

		/// Valid items not yet imported. A repeated URL stays: only a repeated
		/// import is skipped, by key.
		public var items: [MigrationItem]

		/// Items this destination already received from an earlier run.
		public var alreadyImported: [MigrationItemKey]

		/// Records that can't be imported.
		public var issues: [MigrationIssue]

		/// Settings not yet applied, in the preferences category.
		public var preferences: MigrationPortablePreferences?
		public var preferencesKey: MigrationItemKey?

		public init(
			category: MigrationCategory,
			items: [MigrationItem] = [],
			alreadyImported: [MigrationItemKey] = [],
			issues: [MigrationIssue] = [],
			preferences: MigrationPortablePreferences? = nil,
			preferencesKey: MigrationItemKey? = nil
		) {
			self.category = category
			self.items = items
			self.alreadyImported = alreadyImported
			self.issues = issues
			self.preferences = preferences
			self.preferencesKey = preferencesKey
		}

		/// Tabs only: folders and spaces come with them.
		public var tabCount: Int { items.filter { $0.kind == .tab }.count }

		/// Extensions to reinstall by hand. They commit nothing, but running the
		/// category puts them in the report.
		public var reinstalls: [MigrationIssue.Extension] {
			issues.compactMap { issue in
				guard case let .reinstallManually(value) = issue.reason else { return nil }
				return value
			}
		}

		internal var listsReinstalls: Bool { !reinstalls.isEmpty }
	}

	/// Source profiles with Chrome Web Store extensions to install (DEV-845). Their Arx
	/// profile must exist after the run, so the extensions have somewhere to go.
	public var extensionProfiles: [MigrationSourceProfile] {
		var seen: Set<String> = []
		return categories
			.filter { $0.category == .extensions }
			.flatMap(\.reinstalls)
			.compactMap { $0.installsFromStore ? $0.profile : nil }
			.filter { seen.insert($0.id).inserted }
	}
}

/// A confirmed import.
///
/// Semantics:
/// - Each category is one transaction: its items commit together or not at all.
///   Categories commit one at a time in `MigrationCategory` order, so a run can
///   finish with some categories committed and others failed (partial success).
/// - Running a plan again, or retrying it, is idempotent: items whose
///   `MigrationItemKey` the destination already recorded are skipped, so a retry
///   commits only what failed or never ran.
/// - Execution re-reads the source and refuses to commit when the snapshot no
///   longer matches `snapshotID`; the caller must inspect again.
/// - Cancellation takes effect between categories. A category whose commit has
///   started finishes or fails as a whole.
public struct MigrationPlan: Identifiable, Equatable, Sendable {
	public var id: ID
	public var sourceID: MigrationSource.ID
	public var snapshotID: String
	public var destination: MigrationDestination
	public var categories: [MigrationCategory]

	/// Source profiles whose Arx profile must exist after the run even if no category
	/// brings anything into it, because passwords and sign-ins (DEV-842) or store
	/// extensions (DEV-845) follow it.
	public var profiles: [MigrationSourceProfile]

	public init(
		id: ID,
		sourceID: MigrationSource.ID,
		snapshotID: String,
		destination: MigrationDestination,
		categories: [MigrationCategory],
		profiles: [MigrationSourceProfile] = []
	) {
		self.id = id
		self.sourceID = sourceID
		self.snapshotID = snapshotID
		self.destination = destination
		self.categories = categories.sorted()
		self.profiles = profiles
	}

	/// A plan that commits exactly what the preview describes.
	public init(
		id: ID,
		preview: MigrationPreview
	) {
		self.init(
			id: id,
			sourceID: preview.sourceID,
			snapshotID: preview.snapshotID,
			destination: preview.destination,
			categories: preview.categories
				.filter { !$0.items.isEmpty || $0.preferences != nil || $0.listsReinstalls }
				.map(\.category),
			profiles: preview.extensionProfiles
		)
	}

	public typealias ID = BrowserID<Self>
}

/// Progress during execution.
public struct MigrationProgress: Equatable, Sendable {
	public var planID: MigrationPlan.ID
	public var category: MigrationCategory?
	public var completedCategories: Int
	public var totalCategories: Int

	public init(
		planID: MigrationPlan.ID,
		category: MigrationCategory?,
		completedCategories: Int,
		totalCategories: Int
	) {
		self.planID = planID
		self.category = category
		self.completedCategories = completedCategories
		self.totalCategories = totalCategories
	}

	public var fractionCompleted: Double {
		totalCategories == 0 ? 1 : Double(completedCategories) / Double(totalCategories)
	}
}

/// An execution stream event. A run always ends with exactly one `finished`.
public enum MigrationEvent: Equatable, Sendable {
	case progress(MigrationProgress)
	case finished(MigrationReport)
}

/// The final result of one run of a plan.
public struct MigrationReport: Equatable, Sendable {
	public var planID: MigrationPlan.ID
	public var outcome: Outcome
	public var categories: [Category]

	public init(
		planID: MigrationPlan.ID,
		outcome: Outcome,
		categories: [Category]
	) {
		self.planID = planID
		self.outcome = outcome
		self.categories = categories
	}

	public var importedCount: Int { categories.reduce(0) { $0 + $1.imported.count } }

	/// Categories that can be retried with the same plan.
	public var retryableCategories: [MigrationCategory] {
		categories.filter { $0.status == .failed || $0.status == .notStarted }.map(\.category)
	}

	public enum Outcome: Equatable, Sendable {
		/// Every planned category committed.
		case completed

		/// At least one category committed and at least one failed.
		case partiallyCompleted

		/// No category committed because every attempted commit failed.
		case failed

		/// The user cancelled; categories committed before cancellation remain.
		case cancelled
	}

	public struct Category: Equatable, Sendable {
		public var category: MigrationCategory
		public var status: Status
		public var imported: [MigrationItemKey]
		public var alreadyImported: [MigrationItemKey]
		public var issues: [MigrationIssue]

		public init(
			category: MigrationCategory,
			status: Status,
			imported: [MigrationItemKey] = [],
			alreadyImported: [MigrationItemKey] = [],
			issues: [MigrationIssue] = []
		) {
			self.category = category
			self.status = status
			self.imported = imported
			self.alreadyImported = alreadyImported
			self.issues = issues
		}

		public enum Status: Equatable, Sendable {
			case committed
			case failed

			/// Not attempted because the run was cancelled first.
			case notStarted
		}
	}
}

/// Failures that end a run before any category is attempted.
public enum MigrationFailure: Error, Equatable, Sendable {
	/// No adapter is registered for this source.
	case unknownSource

	/// The source changed after inspection; inspect again before importing.
	case sourceChanged

	/// The destination or a route names a space or profile that doesn't exist.
	case invalidDestination

	/// The source couldn't be read.
	case unreadableSource(String)

	/// The file isn't an Arx archive or bookmarks file, or is damaged.
	case invalidFile

	/// The archive is from a newer Arx than this one reads.
	case unsupportedVersion(Int)

	/// The file is over the size limit and wasn't read.
	case fileTooLarge
}
