import BrowserCore
import CryptoKit
import Foundation
import PDFKit

public struct PagePDFRequest: Equatable, Sendable {
	public var tabID: Tab.ID
	public var revision: UInt64
	public var documentRevision: UInt64
	public var kind: Kind
	public var maximumBytes: Int

	/// A private page too (DEV-971): only the app's own Print and Save as PDF set it. The
	/// result stays in memory; MCP never sets it.
	public var allowsPrivate: Bool

	public init(
		tabID: Tab.ID,
		revision: UInt64,
		documentRevision: UInt64,
		kind: Kind,
		maximumBytes: Int,
		allowsPrivate: Bool = false
	) {
		self.tabID = tabID
		self.revision = revision
		self.documentRevision = documentRevision
		self.kind = kind
		self.maximumBytes = maximumBytes
		self.allowsPrivate = allowsPrivate
	}

	public enum Kind: Equatable, Sendable {
		/// Paper width and height are portrait inches; nil keeps the engine's US Letter.
		case export(
			landscape: Bool,
			printsBackground: Bool,
			scale: Double?,
			paperWidth: Double? = nil,
			paperHeight: Double? = nil
		)
		case source
	}
}

public struct PagePDF: Equatable, Sendable {
	public var request: PagePDFRequest
	public var documentID: String
	public var data: Data

	public init(
		request: PagePDFRequest,
		documentID: String,
		data: Data
	) {
		self.request = request
		self.documentID = documentID
		self.data = data
	}

	/// Lowercase hex SHA-256 of the bytes.
	public var digest: String {
		SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
	}
}

public enum PagePDFText {
	/// The document's text, page after page, with a blank line between pages.
	/// Nil when the bytes aren't a readable PDF.
	public static func extract(_ data: Data) -> (text: String, pageCount: Int)? {
		guard data.starts(with: Data("%PDF".utf8)), let document = PDFDocument(data: data)
		else { return nil }

		let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
		return (pages.joined(separator: "\n\n"), document.pageCount)
	}

	/// A chunk of at most `maximumBytes` UTF-8 bytes from `offset`, ending at a
	/// line boundary when one exists and never inside a scalar.
	public static func chunk(
		_ text: String,
		offset: Int,
		maximumBytes: Int
	) -> (chunk: String, next: Int?)? {
		let bytes = Array(text.utf8)
		guard offset <= bytes.count else { return nil }
		guard offset < bytes.count else { return ("", nil) }

		var end = min(bytes.count, offset + maximumBytes)
		if end < bytes.count {
			if let newline = bytes[offset..<end].lastIndex(of: 0x0A), newline > offset {
				end = newline + 1
			} else {
				while end > offset, bytes[end] & 0xC0 == 0x80 { end -= 1 }
			}
		}
		guard end > offset else { return nil }

		return (String(decoding: bytes[offset..<end], as: UTF8.self), end < bytes.count ? end : nil)
	}
}
