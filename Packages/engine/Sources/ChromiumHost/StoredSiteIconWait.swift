import ChromiumEngine
import Foundation

/// Reads a page's icon from the profile's favicon database until it is there (DEV-943).
///
/// A site icon change only tells the app to look the page's icon up again. The end of a
/// load sends one before Chromium has fetched and stored the page's favicon, so a single
/// read right after a change can race the store. This reads the store every `interval`
/// until it holds a bitmap for the page under the expected favicon, and gives up after
/// `timeout` with what it saw. Used only by the disposable back/forward cache fixture.
@MainActor
internal struct StoredSiteIconWait {
	/// What one read of the store found.
	internal enum Read: Equatable, CustomStringConvertible {
		/// Nothing was read yet.
		case unread

		/// The store has no icon for the page.
		case missing
		case icon(width: Int, height: Int, iconURL: URL?)

		/// The lookup failed, as with a busy or timed-out request.
		case failed(String)

		internal init(_ icon: ChromiumSiteIcon?) {
			guard let icon else {
				self = .missing
				return
			}

			self = .icon(width: icon.width, height: icon.height, iconURL: icon.iconURL)
		}

		internal var description: String {
			switch self {
			case .unread: "unread"
			case .missing: "missing"
			case let .icon(width, height, iconURL): "icon(\(width)x\(height),\(iconURL?.absoluteString ?? "unknown"))"
			case let .failed(reason): "error(\(reason))"
			}
		}
	}

	/// The store never held the expected icon in time.
	internal struct TimedOut: Error, Equatable, CustomStringConvertible {
		internal let pageURL: URL
		internal let iconURL: URL
		internal let reads: Int

		/// The last read.
		internal let store: Read

		/// What the caller saw meanwhile, such as the icon changes.
		internal let context: String

		internal init(
			pageURL: URL,
			iconURL: URL,
			reads: Int,
			store: Read,
			context: String
		) {
			self.pageURL = pageURL
			self.iconURL = iconURL
			self.reads = reads
			self.store = store
			self.context = context
		}

		internal var description: String {
			"timed-out wait=stored-icon last=page=\(pageURL.absoluteString),icon=\(iconURL.absoluteString),"
			+ "store=\(store),reads=\(reads)"
			+ (context.isEmpty ? "" : ",\(context)")
		}
	}

	internal let pageURL: URL

	/// The favicon the page declares.
	internal let iconURL: URL
	internal let timeout: Duration
	internal let interval: Duration

	internal init(
		pageURL: URL,
		iconURL: URL,
		timeout: Duration = .seconds(5),
		interval: Duration = .milliseconds(100)
	) {
		self.pageURL = pageURL
		self.iconURL = iconURL
		self.timeout = timeout
		self.interval = interval
	}

	/// Whether `read` found a bitmap under the expected favicon.
	internal func matches(_ read: Read) -> Bool {
		guard case let .icon(width, height, storedIconURL) = read
		else { return false }

		return width > 0
		&& height > 0
		&& storedIconURL?.absoluteString == iconURL.absoluteString
	}

	/// Reads until a read matches. A failed read counts as a miss; cancellation stops the wait.
	internal func wait<C: Clock<Duration>>(
		clock: C,
		read: () async throws -> Read,
		context: () -> String
	) async throws {
		let deadline = clock.now.advanced(by: timeout)
		var reads = 0
		var last = Read.unread
		while true {
			do {
				last = try await read()
			} catch is CancellationError {
				throw CancellationError()
			} catch {
				last = .failed(String(describing: error))
			}
			reads += 1
			if matches(last) { return }

			guard clock.now < deadline else {
				throw TimedOut(
					pageURL: pageURL,
					iconURL: iconURL,
					reads: reads,
					store: last,
					context: context()
				)
			}

			try await clock.sleep(until: clock.now.advanced(by: interval), tolerance: nil)
		}
	}
}
