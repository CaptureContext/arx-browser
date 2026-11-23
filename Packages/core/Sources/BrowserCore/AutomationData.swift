import Foundation

/// A bounded, paginated read of browser data the grant covers.
public struct AutomationDataRequest: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Sendable {
		/// Visited pages of whole-profile grants. Needs the history class.
		case history

		/// Tab Archive entries of granted spaces or whole profiles.
		case archive

		/// Downloads of whole-profile grants. Needs the downloads class.
		case downloads
	}

	public var kind: Kind

	/// Case-insensitive text matched against titles and sanitized URLs.
	public var query: String?
	public var cursor: String?
	public var limit: Int

	public init(
		kind: Kind,
		query: String? = nil,
		cursor: String? = nil,
		limit: Int = 50
	) {
		self.kind = kind
		self.query = query
		self.cursor = cursor
		self.limit = limit
	}

	public func validate() throws {
		guard
			(1...100).contains(limit),
			(query?.utf8.count ?? 0) <= 256,
			(cursor?.utf8.count ?? 0) <= 128
		else { throw AutomationFailure.invalidRequest }
	}
}

/// One history entry, archived tab or download. URLs are sanitized as in inventory.
public struct AutomationDataItem: Codable, Equatable, Identifiable, Sendable {
	public var id: UUID
	public var kind: AutomationDataRequest.Kind
	public var title: String
	public var url: String?
	public var host: String?
	public var urlSanitized: Bool
	public var profileID: UUID

	/// The archived tab's original space, when the grant covers it.
	public var spaceID: UUID?
	public var date: Date

	/// Downloads only: `inProgress`, `complete`, `cancelled` or `interrupted`.
	public var status: String?
	public var receivedBytes: Int64?
	public var totalBytes: Int64?
	public var revision: String

	public init(
		id: UUID,
		kind: AutomationDataRequest.Kind,
		title: String,
		url: String? = nil,
		host: String? = nil,
		profileID: UUID,
		spaceID: UUID? = nil,
		date: Date,
		status: String? = nil,
		receivedBytes: Int64? = nil,
		totalBytes: Int64? = nil,
		revision: String
	) {
		self.id = id
		self.kind = kind
		self.title = title
		self.url = url
		self.host = host
		self.urlSanitized = true
		self.profileID = profileID
		self.spaceID = spaceID
		self.date = date
		self.status = status
		self.receivedBytes = receivedBytes
		self.totalBytes = totalBytes
		self.revision = revision
	}
}

public struct AutomationDataPage: Codable, Equatable, Sendable {
	public var request: AutomationDataRequest
	public var items: [AutomationDataItem]
	public var nextCursor: String?

	public init(
		request: AutomationDataRequest,
		items: [AutomationDataItem],
		nextCursor: String? = nil
	) {
		self.request = request
		self.items = items
		self.nextCursor = nextCursor
	}
}

/// Clean Copy, Proxy Link and bang resolution for a URL or query the client supplies.
/// Nothing is navigated or fetched; the result is only text.
public struct AutomationLinkRequest: Codable, Equatable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Sendable {
		case clean
		case proxy
		case bang
	}

	public var kind: Kind
	public var url: URL?

	/// `bang` only: for example `!w swift` or `w swift`.
	public var query: String?

	public init(
		kind: Kind,
		url: URL? = nil,
		query: String? = nil
	) {
		self.kind = kind
		self.url = url
		self.query = query
	}

	public func validate() throws {
		switch kind {
		case .clean, .proxy:
			guard
				query == nil,
				let url,
				url.absoluteString.utf8.count <= 4096,
				url.hasWebScheme
			else { throw AutomationFailure.invalidRequest }

		case .bang:
			guard
				url == nil,
				let query,
				(1...1024).contains(query.utf8.count)
			else { throw AutomationFailure.invalidRequest }
		}
	}
}

public struct AutomationLinkResult: Codable, Equatable, Sendable {
	public var request: AutomationLinkRequest
	public var url: String

	/// What happened, for example `cleaned`, `noTrackingParameters`, `noMatchingRule` or `resolved`.
	public var outcome: String

	public init(
		request: AutomationLinkRequest,
		url: String,
		outcome: String
	) {
		self.request = request
		self.url = url
		self.outcome = outcome
	}
}

extension BrowserDownload.ID {
	/// A stable UUID for automation targets, derived from the profile and native GUID.
	public var automationID: UUID {
		var bytes = [UInt8](repeating: 0, count: 16)
		let source = Array((profileID.rawValue.uuidString + "/" + guid).utf8)
		for (index, byte) in source.enumerated() {
			bytes[index % 16] = bytes[index % 16] &* 31 &+ byte
		}
		bytes[6] = (bytes[6] & 0x0F) | 0x50
		bytes[8] = (bytes[8] & 0x3F) | 0x80
		return UUID(uuid: (
			bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
			bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
		))
	}
}
