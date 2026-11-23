import Synchronization

/// Counts work that must stay in proportion to what changed rather than to the number of tabs or
/// history entries, on paths that run for every store action, keystroke or edit (DEV-682).
///
/// Production code only records. Nothing counts unless a test binds `counts` around the work, so a
/// recording costs one task-local read.
public enum WorkProbe {
	/// A kind of counted work. Each module names its own.
	public struct Work: Hashable, Sendable {
		public let name: String

		public init(_ name: String) {
			self.name = name
		}
	}

	/// How often each kind of work ran while bound to `WorkProbe.counts`.
	public final class Counts: Sendable {
		private let storage: Mutex<[Work: Int]> = .init([:])

		public init() {}

		public subscript(_ work: Work) -> Int {
			storage.withLock { $0[work, default: 0] }
		}

		fileprivate func record(_ work: Work) {
			storage.withLock { $0[work, default: 0] += 1 }
		}
	}

	@TaskLocal
	public static var counts: Counts?

	public static func record(_ work: Work) {
		counts?.record(work)
	}
}

extension WorkProbe.Work {
	/// A search of the whole organization for one tab (`BrowserOrganization.location(of:)`).
	public static let tabLocationSearch: Self = .init("BrowserCore.location(of:)")

	/// A check of every archived tab (`BrowserOrganization.validateArchive()`).
	public static let archiveValidation: Self = .init("BrowserCore.validateArchive")
}
