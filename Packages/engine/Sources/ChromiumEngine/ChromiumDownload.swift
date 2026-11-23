import ChromiumBridge
import Foundation

/// A copied native snapshot. Chromium remains the authority for transfer state and files.
public struct ChromiumDownload: Equatable, Sendable {
	public var guid: String
	public var profileKey: String
	public var sourcePage: UInt64
	public var url: URL?
	public var target: URL?
	public var filename: String
	public var state: State
	public var interruptReason: Int
	public var receivedBytes: Int64
	public var totalBytes: Int64
	public var startedAt: Date
	public var isDangerous: Bool
	public var isMissing: Bool
	public var isPrivate: Bool

	internal init(
		profileKey: String,
		native: ArxDownloadSnapshot
	) {
		self.guid = native.guid.map(String.init(cString:)) ?? ""
		self.profileKey = profileKey
		self.sourcePage = native.source_page
		self.url = native.url.flatMap { URL(string: String(cString: $0)) }

		self.target = native.target_path.flatMap { pointer in
			let path = String(cString: pointer)
			return path.hasPrefix("/") ? URL(filePath: path) : nil
		}

		self.filename = native.filename.map(String.init(cString:)) ?? ""
		self.state = State(rawValue: Int(native.state)) ?? .interrupted
		self.interruptReason = Int(native.interrupt_reason)
		self.receivedBytes = native.received_bytes
		self.totalBytes = native.total_bytes
		self.startedAt = Date(timeIntervalSince1970: native.started_at)
		self.isDangerous = native.dangerous
		self.isMissing = native.missing
		self.isPrivate = native.private_context
	}

	public enum State: Int, Equatable, Sendable {
		case inProgress = 0
		case complete = 1
		case cancelled = 2
		case interrupted = 3
	}
}

public enum ChromiumDownloadEvent: Equatable, Sendable {
	case changed(ChromiumDownload)
	case initialized(profileKey: String)
}

/// ABI33. Why `ChromiumRuntime.startDownload` produced no item.
public enum ChromiumDownloadStartFailure: Error, Equatable, Sendable {
	/// The runtime, the bridge or the profile can't start downloads, or the URL was refused.
	case unavailable

	/// Chromium refused the request before creating an item, with its interrupt reason.
	case failed(interruptReason: Int)

	/// Nothing answered within 30 seconds. An item that still arrives is cancelled.
	case timedOut

	internal init(
		status: ArxDownloadStartStatus,
		interruptReason: Int32
	) {
		self = switch status {
		case ARX_DOWNLOAD_START_FAILED: .failed(interruptReason: Int(interruptReason))
		case ARX_DOWNLOAD_START_TIMEOUT: .timedOut
		default: .unavailable
		}
	}
}
