import CryptoKit
import Foundation

/// What macOS's MetricKit reported about hangs from real use (DEV-1010), reduced like
/// ``CrashReport``: a hang diagnostic's duration and heaviest stack, or the day's histogram of hang
/// times. Payloads are read through an allowlist; exception reasons, termination messages and
/// anything else free-form never reach disk.
public struct HangReport: Codable, Equatable, Identifiable, Sendable {
	public enum Kind: String, Codable, Sendable {
		/// One hang, with the stack it was stuck in.
		case diagnostic

		/// How long hangs took over a period, as a histogram.
		case histogram
	}

	public struct Bucket: Codable, Equatable, Sendable {
		/// The bucket's range, in milliseconds.
		public var start: Double
		public var end: Double
		public var count: Int

		public init(
			start: Double,
			end: Double,
			count: Int
		) {
			self.start = start
			self.end = end
			self.count = count
		}
	}

	public var id: String
	public var kind: Kind

	/// The end of the period the payload covers.
	public var date: Date

	public var appVersion: String?
	public var appBuild: String?
	public var osVersion: String?

	/// A diagnostic's hang duration, in seconds.
	public var duration: TimeInterval?

	/// A diagnostic's stack: at each level the frame with the most samples, innermost first.
	public var frames: [CrashReport.Frame]
	public var modules: [CrashReport.Module]

	/// A histogram's buckets.
	public var buckets: [Bucket]

	public init(
		id: String,
		kind: Kind,
		date: Date,
		appVersion: String? = nil,
		appBuild: String? = nil,
		osVersion: String? = nil,
		duration: TimeInterval? = nil,
		frames: [CrashReport.Frame] = [],
		modules: [CrashReport.Module] = [],
		buckets: [Bucket] = []
	) {
		self.id = id
		self.kind = kind
		self.date = date
		self.appVersion = appVersion
		self.appBuild = appBuild
		self.osVersion = osVersion
		self.duration = duration
		self.frames = frames
		self.modules = modules
		self.buckets = buckets
	}
}

// MARK: - Reading MetricKit payloads

extension HangReport {
	/// What makes two reports the same, whatever ID each was given: the kind, the period's end to
	/// the second (as the log keeps dates), the duration and the stack, or the buckets.
	internal var identity: String {
		let frames: String = self.frames.map { "\($0.module)+\($0.offset)" }.joined(separator: ",")
		let buckets: String = self.buckets.map { "\($0.start)-\($0.end):\($0.count)" }.joined(separator: ",")
		return "\(kind.rawValue)|\(Int(date.timeIntervalSince1970))|\(duration ?? -1)|\(frames)|\(buckets)"
	}

	/// ``identity`` hashed, for remembering a report after it's removed without keeping any of it.
	internal var fingerprint: String {
		SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
	}
}

extension HangReport {
	/// The hang diagnostics in an `MXDiagnosticPayload`'s `jsonRepresentation()`.
	public static func diagnostics(
		fromPayload data: Data,
		received: Date
	) -> [HangReport] {
		guard let payload = object(data) else { return [] }

		let date: Date = timestamp(payload["timeStampEnd"]) ?? received
		let hangs: [[String: Any]] = payload["hangDiagnostics"] as? [[String: Any]] ?? []
		return hangs.map { hang in
			let metadata: [String: Any] = hang["diagnosticMetaData"] as? [String: Any] ?? [:]
			let (frames, modules) = heaviestStack(hang["callStackTree"] as? [String: Any])
			return .init(
				id: UUID().uuidString,
				kind: .diagnostic,
				date: date,
				appVersion: metadata["appVersion"] as? String,
				appBuild: metadata["appBuildVersion"] as? String,
				osVersion: metadata["osVersion"] as? String,
				duration: measurement(metadata["hangDuration"]).map { $0 / 1000 },
				frames: frames,
				modules: modules
			)
		}
	}

	/// The hang-time histogram in an `MXMetricPayload`'s `jsonRepresentation()`, if it has one.
	public static func histogram(
		fromPayload data: Data,
		received: Date
	) -> HangReport? {
		guard
			let payload = object(data),
			let responsiveness = payload["applicationResponsivenessMetrics"] as? [String: Any],
			let histogram = responsiveness["histogrammedAppHangTime"] as? [String: Any],
			let values = histogram["histogramValue"] as? [String: Any]
		else { return nil }

		let metadata: [String: Any] = payload["metaData"] as? [String: Any] ?? [:]

		// The version is at the payload's root; older payloads put it in `metaData`.
		let appVersion: String? = payload["appVersion"] as? String ?? metadata["appVersion"] as? String
		let buckets: [Bucket] = values.values
			.compactMap { $0 as? [String: Any] }
			.compactMap { bucket in
				guard
					let start = measurement(bucket["bucketStart"]),
					let end = measurement(bucket["bucketEnd"]),
					let count = (bucket["bucketCount"] as? NSNumber)?.intValue
				else { return nil }

				return .init(start: start, end: end, count: count)
			}
			.sorted { $0.start < $1.start }
		guard !buckets.isEmpty else { return nil }

		return .init(
			id: UUID().uuidString,
			kind: .histogram,
			date: timestamp(payload["timeStampEnd"]) ?? received,
			appVersion: appVersion,
			appBuild: metadata["appBuildVersion"] as? String,
			osVersion: metadata["osVersion"] as? String,
			buckets: buckets
		)
	}

	// MARK: - Helpers

	private static func object(_ data: Data) -> [String: Any]? {
		(try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}

	/// MetricKit writes times as `2024-01-02 03:04:05 +0000`, or without the zone, in UTC.
	internal static func timestamp(_ value: Any?) -> Date? {
		guard let text = value as? String else { return nil }

		let formatter: DateFormatter = .init()
		formatter.locale = Locale(identifier: "en_US_POSIX")
		formatter.timeZone = TimeZone(identifier: "UTC")
		for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss"] {
			formatter.dateFormat = format
			if let date = formatter.date(from: text) { return date }
		}
		return nil
	}

	/// A duration such as `2.5 sec`, `250 ms` or `1 min`, in milliseconds.
	internal static func measurement(_ value: Any?) -> Double? {
		if let number = value as? NSNumber { return number.doubleValue }
		guard let text = value as? String else { return nil }

		let parts: [Substring] = text.split(separator: " ", omittingEmptySubsequences: true)
		guard let first = parts.first, let amount = Double(first.replacingOccurrences(of: ",", with: "")) else { return nil }

		switch parts.dropFirst().first?.lowercased() {
		case "ms", nil: return amount
		case "s", "sec", "secs", "second", "seconds": return amount * 1000
		case "min", "mins", "minute", "minutes": return amount * 60_000
		case "h", "hr", "hour", "hours": return amount * 3_600_000
		default: return nil
		}
	}

	/// Follows the attributed thread's call tree, taking the most-sampled frame at each level.
	/// Each frame is a binary's file name and the address's offset into it.
	private static func heaviestStack(_ tree: [String: Any]?) -> ([CrashReport.Frame], [CrashReport.Module]) {
		let stacks: [[String: Any]] = tree?["callStacks"] as? [[String: Any]] ?? []
		let stack: [String: Any]? = stacks.first { ($0["threadAttributed"] as? Bool) == true } ?? stacks.first
		var level: [[String: Any]] = stack?["callStackRootFrames"] as? [[String: Any]] ?? []
		var outermostFirst: [CrashReport.Frame] = []
		var modules: [CrashReport.Module] = []
		var seen: Set<String> = []
		while
			outermostFirst.count < CrashReport.frameLimit,
			let frame = level.max(by: { samples($0) < samples($1) })
		{
			let name: String = (frame["binaryName"] as? String).map(CrashReport.fileName) ?? "?"
			let address: UInt64 = (frame["address"] as? NSNumber)?.uint64Value ?? 0

			// `offsetIntoBinaryTextSegment` holds the binary's load address on current systems.
			let base: UInt64 = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.uint64Value ?? 0
			outermostFirst.append(.init(module: name, offset: address >= base ? address - base : base))
			if seen.insert(name).inserted {
				modules.append(.init(name: name, uuid: frame["binaryUUID"] as? String))
			}
			level = frame["subFrames"] as? [[String: Any]] ?? []
		}
		return (outermostFirst.reversed(), modules)
	}

	private static func samples(_ frame: [String: Any]) -> Int {
		(frame["sampleCount"] as? NSNumber)?.intValue ?? 0
	}
}

/// MetricKit's reduced hang reports, `…/Diagnostics/Hangs/metrickit.jsonl`.
public struct HangReportLog: Sendable {
	/// A report this log has taken in, kept in ``seenFile`` after the report itself is removed.
	internal struct Seen: Codable, Equatable, Sendable {
		internal var fingerprint: String
		internal var date: Date

		internal init(
			fingerprint: String,
			date: Date
		) {
			self.fingerprint = fingerprint
			self.date = date
		}
	}

	public static let retention: TimeInterval = 30 * 24 * 3600
	public static let limit: Int = 100

	public var file: URL
	public var now: @Sendable () -> Date

	public init(
		file: URL,
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.file = file
		self.now = now
	}

	/// `metrickit.jsonl` in `folder`.
	public init(folder: URL) {
		self.init(file: folder.appendingPathComponent("metrickit.jsonl"))
	}

	/// `metrickit.seen` beside the log: a hash and the date of every report taken in, so a payload
	/// macOS delivers again isn't saved again, even after ``removeAll()`` (DEV-1079). Holds nothing
	/// a report could be read back from.
	public var seenFile: URL {
		file.deletingPathExtension().appendingPathExtension("seen")
	}

	/// Every report kept, newest first: at most ``limit``, none past the ``retention``.
	public func reports() -> [HangReport] {
		Array(
			JSONLines.read(HangReport.self, from: file)
				.filter { $0.date >= now().addingTimeInterval(-Self.retention) }
				.sorted { $0.date > $1.date }
				.prefix(Self.limit)
		)
	}

	public func reports(since date: Date) -> [HangReport] {
		reports().filter { $0.date >= date }
	}

	/// Appends the reports this log hasn't taken in yet: the same payload can arrive again, as
	/// MetricKit's past payloads do at every launch, including the ones removed since.
	public func append(_ reports: [HangReport]) {
		JSONLines.withLock(file) {
			var seen: [String: Date] = seenDates()
			let count: Int = seen.count
			for report in reports where seen[report.fingerprint] == nil {
				seen[report.fingerprint] = report.date
				JSONLines.append(report, to: file)
			}
			if seen.count != count { writeSeen(seen) }
			prune()
		}
	}

	/// Rewrites the log without reports past the retention or the limit, as ``StallLog/prune()``,
	/// and forgets reports past the retention, which ``reports()`` would leave out anyway.
	public func prune() {
		JSONLines.withLock(file) {
			let all: [HangReport] = JSONLines.read(HangReport.self, from: file)
			let oldest: Date = now().addingTimeInterval(-Self.retention)
			let stale: Bool = all.count > Self.limit || all.contains { $0.date < oldest }
			JSONLines.compact(file: file, force: stale, threshold: StallLog.compactionSize, values: self.reports().reversed())

			let seen: [Seen] = JSONLines.read(Seen.self, from: seenFile)
			if seen.contains(where: { $0.date < oldest }) {
				writeSeen(Dictionary(seen.map { ($0.fingerprint, $0.date) }, uniquingKeysWith: max))
			}
		}
	}

	/// Removes every report. The list of reports taken in stays, so none of them comes back.
	public func removeAll() {
		JSONLines.withLock(file) {
			// A log written before the list existed adds its reports to it first.
			writeSeen(seenDates())
			try? FileManager.default.removeItem(at: file)
		}
	}

	// MARK: - Seen

	/// The reports taken in: the list, and the log's own reports in case it predates the list.
	private func seenDates() -> [String: Date] {
		var seen: [String: Date] = Dictionary(
			JSONLines.read(Seen.self, from: seenFile).map { ($0.fingerprint, $0.date) },
			uniquingKeysWith: max
		)
		for report in JSONLines.read(HangReport.self, from: file) where seen[report.fingerprint] == nil {
			seen[report.fingerprint] = report.date
		}
		return seen
	}

	private func writeSeen(_ seen: [String: Date]) {
		let oldest: Date = now().addingTimeInterval(-Self.retention)
		JSONLines.compact(
			file: seenFile,
			force: true,
			threshold: 0,
			values: seen
				.filter { $0.value >= oldest }
				.map { Seen(fingerprint: $0.key, date: $0.value) }
				.sorted { ($0.date, $0.fingerprint) < ($1.date, $1.fingerprint) }
		)
	}
}
