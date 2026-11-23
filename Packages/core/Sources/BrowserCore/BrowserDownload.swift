import Foundation

public struct BrowserDownload: Identifiable, Equatable, Codable, Sendable {
	public struct ID: Hashable, Codable, Sendable {
		public var profileID: Profile.ID
		public var guid: String

		public init(
			profileID: Profile.ID,
			guid: String
		) {
			self.profileID = profileID
			self.guid = guid
		}
	}

	public enum Status: String, Codable, Sendable {
		case inProgress
		case complete
		case cancelled
		case interrupted
	}

	public var id: ID
	public var profileName: String
	public var spaceName: String?
	public var url: URL?
	public var target: URL?
	public var filename: String
	public var status: Status
	public var receivedBytes: Int64
	public var totalBytes: Int64
	public var startedAt: Date
	public var interruptReason: Int
	public var isDangerous: Bool
	public var isMissing: Bool
	public var isPrivate: Bool

	/// Paused by the person (DEV-892). The transfer stays in progress.
	public var isPaused: Bool

	/// Resume continues it: a paused transfer, or one interrupted in a way Chromium can resume,
	/// including by quitting. Never saved; the engine reports it again after a relaunch.
	public var canResume: Bool

	/// Pause stops it for now. False with an engine built before pause and resume.
	public var canPause: Bool

	/// The tab whose page started it, while that tab is open (DEV-1116). Never saved.
	public var sourceTabID: Tab.ID?

	public init(
		id: ID,
		profileName: String,
		spaceName: String? = nil,
		url: URL? = nil,
		target: URL? = nil,
		filename: String,
		status: Status,
		receivedBytes: Int64 = 0,
		totalBytes: Int64 = 0,
		startedAt: Date,
		interruptReason: Int = 0,
		isDangerous: Bool = false,
		isMissing: Bool = false,
		isPrivate: Bool = false,
		isPaused: Bool = false,
		canResume: Bool = false,
		canPause: Bool = false,
		sourceTabID: Tab.ID? = nil
	) {
		self.id = id
		self.profileName = profileName
		self.spaceName = spaceName
		self.url = url
		self.target = target
		self.filename = filename
		self.status = status
		self.receivedBytes = receivedBytes
		self.totalBytes = totalBytes
		self.startedAt = startedAt
		self.interruptReason = interruptReason
		self.isDangerous = isDangerous
		self.isMissing = isMissing
		self.isPrivate = isPrivate
		self.isPaused = isPaused
		self.canResume = canResume
		self.canPause = canPause
		self.sourceTabID = sourceTabID
	}

	private enum CodingKeys: String, CodingKey {
		case id, profileName, spaceName, url, target, filename, status, receivedBytes, totalBytes
		case startedAt, interruptReason, isDangerous, isMissing, isPrivate
	}

	/// Pause and resume state and the source tab aren't saved: after a relaunch the engine reports
	/// the first again, and the tab that started a transfer is gone.
	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.init(
			id: try values.decode(ID.self, forKey: .id),
			profileName: try values.decode(String.self, forKey: .profileName),
			spaceName: try values.decodeIfPresent(String.self, forKey: .spaceName),
			url: try values.decodeIfPresent(URL.self, forKey: .url),
			target: try values.decodeIfPresent(URL.self, forKey: .target),
			filename: try values.decode(String.self, forKey: .filename),
			status: try values.decode(Status.self, forKey: .status),
			receivedBytes: try values.decode(Int64.self, forKey: .receivedBytes),
			totalBytes: try values.decode(Int64.self, forKey: .totalBytes),
			startedAt: try values.decode(Date.self, forKey: .startedAt),
			interruptReason: try values.decode(Int.self, forKey: .interruptReason),
			isDangerous: try values.decode(Bool.self, forKey: .isDangerous),
			isMissing: try values.decode(Bool.self, forKey: .isMissing),
			isPrivate: try values.decode(Bool.self, forKey: .isPrivate)
		)
	}

	public func encode(to encoder: any Encoder) throws {
		var values = encoder.container(keyedBy: CodingKeys.self)
		try values.encode(id, forKey: .id)
		try values.encode(profileName, forKey: .profileName)
		try values.encodeIfPresent(spaceName, forKey: .spaceName)
		try values.encodeIfPresent(url, forKey: .url)
		try values.encodeIfPresent(target, forKey: .target)
		try values.encode(filename, forKey: .filename)
		try values.encode(status, forKey: .status)
		try values.encode(receivedBytes, forKey: .receivedBytes)
		try values.encode(totalBytes, forKey: .totalBytes)
		try values.encode(startedAt, forKey: .startedAt)
		try values.encode(interruptReason, forKey: .interruptReason)
		try values.encode(isDangerous, forKey: .isDangerous)
		try values.encode(isMissing, forKey: .isMissing)
		try values.encode(isPrivate, forKey: .isPrivate)
	}

	/// Copy Link copies the address the transfer came from.
	public var canCopyLink: Bool {
		url.map { ["http", "https"].contains($0.scheme?.lowercased() ?? "") } ?? false
	}

	/// Remove from List: an ordinary transfer that isn't still running. The file stays. Private
	/// transfers leave the list when their private session ends.
	public var canRemoveFromList: Bool {
		status != .inProgress && !isPrivate
	}

	/// Move to Trash: a finished, safe file that's still there, from an ordinary profile (it also
	/// leaves the list, which private transfers can't).
	public var canMoveToTrash: Bool {
		canOpen && !isPrivate
	}

	public var canOpen: Bool {
		status == .complete && !isDangerous && !isMissing && target?.isFileURL == true
	}

	public var progress: Double? {
		guard totalBytes > 0 else { return nil }
		return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
	}
}

/// Ordinary history and private transfers are deliberately separate collections.
public struct DownloadQueue: Equatable, Sendable {
	public var downloads: [BrowserDownload]
	public var privateDownloads: [BrowserDownload]
	public var message: String?

	public init(
		downloads: [BrowserDownload] = [],
		privateDownloads: [BrowserDownload] = [],
		message: String? = nil
	) {
		self.downloads = downloads.filter { !$0.isPrivate }
		self.privateDownloads = privateDownloads.filter(\.isPrivate)
		self.message = message
	}

	public var activeCount: Int {
		(downloads + privateDownloads).filter { $0.status == .inProgress }.count
	}

	/// Transfers in progress, paused ones included, that a quit loses whatever their server allows:
	/// private ones, whose off-the-record profile and partial file go with the window (DEV-966).
	public var lostOnQuitCount: Int {
		privateDownloads.filter { $0.status == .inProgress }.count
	}
}
