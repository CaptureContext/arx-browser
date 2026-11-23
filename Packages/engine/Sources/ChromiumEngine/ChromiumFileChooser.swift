import ChromiumBridge
import Foundation

/// ABI30. A file chooser the page opened right after an automation pointer or
/// keyboard action, held for the app instead of being cancelled.
public struct ChromiumFileChooser: Equatable, Sendable {
	public let token: UInt64
	public let allowsMultiple: Bool

	/// The page's accept types, untrusted page data.
	public let acceptTypes: [String]

	public init(
		token: UInt64,
		allowsMultiple: Bool,
		acceptTypes: [String]
	) {
		self.token = token
		self.allowsMultiple = allowsMultiple
		self.acceptTypes = acceptTypes
	}
}

public enum ChromiumFileChooserFailure: Error, Equatable, Sendable {
	/// No chooser is held for this page any more, or it is another one.
	case stale

	/// A path isn't absolute, or more paths than the chooser takes.
	case invalid
	case unavailable
}

extension ChromiumPage {
	/// The chooser held for this page, if any.
	public func fileChooser() -> ChromiumFileChooser? {
		let value = openOwner?.performIfOpen(on: self) { api, id -> ChromiumFileChooser? in

			// An engine without file chooser support holds none.
			guard let read = api.page_file_chooser else { return nil }
			var info = ArxFileChooserInfo()
			guard read(id, &info) else { return nil }
			let accept = info.accept.map { String(cString: $0) } ?? ""
			return ChromiumFileChooser(
				token: info.token,
				allowsMultiple: info.multiple,
				acceptTypes: accept.split(separator: ",").map(String.init)
			)
		}
		return value ?? nil
	}

	/// Answers the held chooser with absolute file paths the caller has checked
	/// and the user approved, or cancels it with no paths.
	public func answerFileChooser(
		_ chooser: ChromiumFileChooser,
		paths: [String]
	) throws(ChromiumFileChooserFailure) {
		let status: ArxFileChooserStatus
		do {
			status = try owner().perform(on: self) { api, id in
				guard let answer = api.answer_file_chooser else { throw ChromiumError.incompatibleBridge }
				return Self.withCStrings(paths) { pointers in
					answer(id, chooser.token, pointers.baseAddress, pointers.count)
				}
			}
		} catch {
			throw .unavailable
		}
		switch status {
		case ARX_FILE_CHOOSER_OK: return
		case ARX_FILE_CHOOSER_INVALID: throw .invalid
		default: throw .stale
		}
	}

	private static func withCStrings<Result>(
		_ strings: [String],
		_ body: (UnsafeBufferPointer<UnsafePointer<CChar>?>) -> Result
	) -> Result {
		let copies = strings.map { strdup($0) }
		defer { copies.forEach { free($0) } }
		let pointers = copies.map { $0.map { UnsafePointer($0) } }
		return pointers.withUnsafeBufferPointer(body)
	}
}
