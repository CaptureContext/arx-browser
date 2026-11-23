import BrowserCore
import Foundation
import Synchronization

/// The last filter's results over a command bar's candidates, made again when the candidates are
/// set (DEV-946).
///
/// One keystroke or arrow key reads `entries` several times (the reducer, the view and the
/// highlighted result's actions), and only the first read filters. Matching itself is unchanged:
/// `localizedCaseInsensitiveContains` on each title and subtitle, which no case folding done once
/// reproduces for every script (emoji sequences, combining marks, the Turkish dotted i, ß).
public struct CandidateMatcher: Equatable, Sendable, CustomReflectable {
	/// What a filter's results depend on besides the candidates themselves.
	internal struct Key: Hashable, Sendable {
		internal var mode: CommandBarFeature.Mode
		internal var filter: String
	}

	private final class Storage: Sendable {
		internal let results: Mutex<(key: Key, entries: [CommandBarFeature.Entry])?> = .init(nil)
	}

	private let storage: Storage = .init()

	public static let empty: Self = .init()

	public init() {}

	/// The results for `key`, computed by `compute` only when the last results were for another key.
	///
	/// Callers read `candidates` themselves before asking, so a cached answer still makes observers
	/// of the results depend on the candidates.
	internal func results(
		for key: Key,
		_ compute: () -> [CommandBarFeature.Entry]
	) -> [CommandBarFeature.Entry] {
		if let last = storage.results.withLock({ $0 }), last.key == key { return last.entries }

		WorkProbe.record(.commandBarFilter)
		let entries = compute()
		storage.results.withLock { $0 = (key: key, entries: entries) }
		return entries
	}

	/// Derived from the candidates, which the state compares itself; the kept results are a cache.
	public static func == (lhs: Self, rhs: Self) -> Bool {
		true
	}

	public var customMirror: Mirror {
		Mirror(self, children: [])
	}
}

extension WorkProbe.Work {
	/// One pass of the command bar's filter over its candidates.
	internal static let commandBarFilter: Self = .init("CommandBarFeature.filter")
}
