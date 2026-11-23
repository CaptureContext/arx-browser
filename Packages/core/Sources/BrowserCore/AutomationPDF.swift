import Foundation

/// A PDF read of one permitted ordinary page. Export prints the page; text reads
/// the PDF document a tab shows. Neither shows, focuses or selects the tab.
public struct AutomationPDFRequest: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var expectedRevision: String
	public var kind: Kind
	public var landscape: Bool
	public var printsBackground: Bool

	/// 0.1 to 2; nil prints at 1.
	public var scale: Double?

	/// For `.text`: the UTF-8 offset of the chunk to return.
	public var offset: Int

	/// For `.text`: the largest chunk to return, cut at a line boundary.
	public var maximumBytes: Int

	public static let maximumExportBytes: Int = 4_194_304
	public static let maximumChunkBytes: Int = 65_536

	public init(
		targetID: UUID,
		expectedRevision: String,
		kind: Kind,
		landscape: Bool = false,
		printsBackground: Bool = false,
		scale: Double? = nil,
		offset: Int = 0,
		maximumBytes: Int = 16_384
	) {
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.kind = kind
		self.landscape = landscape
		self.printsBackground = printsBackground
		self.scale = scale
		self.offset = offset
		self.maximumBytes = maximumBytes
	}

	public func validate() throws {
		let hasValidScale = scale.map { $0.isFinite && (0.1...2).contains($0) } ?? true
		let isPlainText = kind == .export || (!landscape && !printsBackground && scale == nil)
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			hasValidScale,
			isPlainText,
			offset >= 0,
			(1_024...Self.maximumChunkBytes).contains(maximumBytes)
		else { throw AutomationFailure.invalidRequest }
	}

	public enum Kind: String, Codable, CaseIterable, Sendable {
		/// The page printed to PDF.
		case export

		/// The text of the PDF document the tab shows.
		case text
	}
}

public struct AutomationPDFResult: Codable, Equatable, Sendable {
	public var request: AutomationPDFRequest
	public var profileID: Profile.ID
	public var documentRevision: UInt64
	public var documentID: String

	/// For `.export`: the PDF.
	public var data: Data?

	/// For `.text`: one chunk of the document's text.
	public var text: String?
	public var totalBytes: Int
	public var nextOffset: Int?
	public var pageCount: Int

	/// SHA-256 of the PDF bytes, so chunks of two different documents never mix.
	public var digest: String

	public init(
		request: AutomationPDFRequest,
		profileID: Profile.ID,
		documentRevision: UInt64,
		documentID: String,
		data: Data? = nil,
		text: String? = nil,
		totalBytes: Int,
		nextOffset: Int? = nil,
		pageCount: Int,
		digest: String
	) {
		self.request = request
		self.profileID = profileID
		self.documentRevision = documentRevision
		self.documentID = documentID
		self.data = data
		self.text = text
		self.totalBytes = totalBytes
		self.nextOffset = nextOffset
		self.pageCount = pageCount
		self.digest = digest
	}

	public func validate() throws {
		try request.validate()
		guard
			documentRevision > 0,
			!documentID.isEmpty,
			documentID.utf8.count <= 128,
			digest.utf8.count == 64,
			digest.allSatisfy(\.isHexDigit),
			pageCount >= 0,
			totalBytes >= 0
		else { throw AutomationFailure.invalidRequest }

		switch request.kind {
		case .export:
			guard let data, text == nil, nextOffset == nil, data.count == totalBytes
			else { throw AutomationFailure.invalidRequest }
			guard data.count <= AutomationPDFRequest.maximumExportBytes
			else { throw AutomationFailure.limitExceeded }

		case .text:
			guard
				data == nil,
				let text,
				text.utf8.count <= request.maximumBytes,
				request.offset + text.utf8.count <= totalBytes,
				nextOffset.map({ $0 == request.offset + text.utf8.count && $0 < totalBytes }) ?? true
			else { throw AutomationFailure.invalidRequest }
		}
	}
}

/// Native find in page: highlights matches and moves the active one. Stopping
/// leaves the selection on the active match, which the page can observe.
public struct AutomationFindInPageRequest: Codable, Equatable, Sendable {
	public var targetID: UUID
	public var expectedRevision: String

	/// A new search; nil moves through the current one.
	public var text: String?
	public var forward: Bool
	public var stop: Bool

	public init(
		targetID: UUID,
		expectedRevision: String,
		text: String? = nil,
		forward: Bool = true,
		stop: Bool = false
	) {
		self.targetID = targetID
		self.expectedRevision = expectedRevision
		self.text = text
		self.forward = forward
		self.stop = stop
	}

	public func validate() throws {
		let hasValidText = text.map { !$0.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") } ?? true
		guard
			expectedRevision.utf8.count == 64,
			expectedRevision.allSatisfy(\.isHexDigit),
			hasValidText,
			!stop || text == nil
		else { throw AutomationFailure.invalidRequest }
	}
}

public struct AutomationFindInPageResult: Codable, Equatable, Sendable {
	public var targetID: UUID

	/// Nil when the page reported no result in time.
	public var matches: Int?

	/// One-based, nil with no matches.
	public var active: Int?
	public var stopped: Bool

	public init(
		targetID: UUID,
		matches: Int?,
		active: Int?,
		stopped: Bool
	) {
		self.targetID = targetID
		self.matches = matches
		self.active = active
		self.stopped = stopped
	}

	public func validate() throws {
		let hasValidActive = active.map { active in
			matches.map { (1...$0).contains(active) } ?? false
		} ?? true
		guard
			matches.map({ $0 >= 0 }) ?? true,
			hasValidActive,
			!stopped || (matches == nil && active == nil)
		else { throw AutomationFailure.invalidRequest }
	}
}
