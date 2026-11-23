import Darwin
import Foundation

/// A stretch of time the main thread didn't get back to its run loop (DEV-1010), with the stack it
/// was stuck in. Like ``CrashReport``, it never holds a URL, a title, page content or a path:
/// frames are binary file names, offsets and function names.
public struct StallRecord: Codable, Equatable, Identifiable, Sendable {
	public var id: String

	/// When the stall began.
	public var date: Date

	/// How long it lasted, or had lasted when last written, in seconds.
	public var duration: TimeInterval

	/// Whether the run loop came back. A stall that never ended is how a kill after a hang looks.
	public var ended: Bool

	/// Whether it went past strict mode's limit, which ends the run (``StallWatchdog``).
	public var exceededStrictLimit: Bool

	public var appVersion: String?
	public var appBuild: String?

	/// The stalled process, to match an unended stall to the run it ended (DEV-1018).
	public var processID: Int32?

	/// The main thread's stack about a threshold into the stall, innermost first.
	public var frames: [CrashReport.Frame]
	public var modules: [CrashReport.Module]

	public init(
		id: String,
		date: Date,
		duration: TimeInterval,
		ended: Bool = false,
		exceededStrictLimit: Bool = false,
		appVersion: String? = nil,
		appBuild: String? = nil,
		processID: Int32? = nil,
		frames: [CrashReport.Frame] = [],
		modules: [CrashReport.Module] = []
	) {
		self.id = id
		self.processID = processID
		self.date = date
		self.duration = duration
		self.ended = ended
		self.exceededStrictLimit = exceededStrictLimit
		self.appVersion = appVersion
		self.appBuild = appBuild
		self.frames = frames
		self.modules = modules
	}
}

/// The stall log, `…/Diagnostics/Hangs/stalls.jsonl`: one JSON record per line, appended as a
/// stall begins and again when it ends, so a stall the process was killed in is still there.
/// Reading merges each stall's lines; the file is rewritten without old records once it grows.
public struct StallLog: Sendable {
	public static let retention: TimeInterval = 30 * 24 * 3600
	public static let limit: Int = 100

	/// Past this size the log is rewritten with only the newest ``limit`` records.
	internal static let compactionSize: Int = 256 * 1024

	public var file: URL
	public var now: @Sendable () -> Date

	public init(
		file: URL,
		now: @escaping @Sendable () -> Date = Date.init
	) {
		self.file = file
		self.now = now
	}

	/// `stalls.jsonl` in `folder`.
	public init(folder: URL) {
		self.init(file: folder.appendingPathComponent("stalls.jsonl"))
	}

	/// Every stall kept, newest first, each with its latest duration: at most ``limit``, none past
	/// the ``retention``.
	public func records() -> [StallRecord] {
		Array(
			merged()
				.filter { $0.date >= now().addingTimeInterval(-Self.retention) }
				.sorted { $0.date > $1.date }
				.prefix(Self.limit)
		)
	}

	/// Each stall's lines merged, whatever their age.
	private func merged() -> [StallRecord] {
		JSONLines.read(StallRecord.self, from: file)
			.reduce(into: [String: StallRecord]()) { merged, record in
				if var existing = merged[record.id] {
					existing.duration = max(existing.duration, record.duration)
					existing.ended = existing.ended || record.ended
					existing.exceededStrictLimit = existing.exceededStrictLimit || record.exceededStrictLimit
					merged[record.id] = existing
				} else {
					merged[record.id] = record
				}
			}
			.values
			.map { $0 }
	}

	public func records(since date: Date) -> [StallRecord] {
		records().filter { $0.date >= date }
	}

	/// The newest stall, ended or not.
	public var last: StallRecord? {
		records().first
	}

	/// Appends a stall as it begins, or its update when it ends, then rewrites the log without
	/// records past the retention or the limit, or merged lines once it's large.
	public func append(_ record: StallRecord) {
		JSONLines.withLock(file) {
			JSONLines.append(record, to: file)
			prune()
		}
	}

	/// Rewrites the log without records past the retention or the limit, or merged once large.
	/// Runs on every append, at launch and when crash reports are collected, so an old stall
	/// leaves the disk even when no new one comes.
	public func prune() {
		JSONLines.withLock(file) {
			let all: [StallRecord] = merged()
			let oldest: Date = now().addingTimeInterval(-Self.retention)
			let stale: Bool = all.count > Self.limit || all.contains { $0.date < oldest }
			JSONLines.compact(file: file, force: stale, threshold: Self.compactionSize, values: records().reversed())
		}
	}

	public func removeAll() {
		JSONLines.withLock(file) {
			try? FileManager.default.removeItem(at: file)
		}
	}
}

/// Newline-delimited JSON files that a crash can at worst leave one partial last line in.
internal enum JSONLines {
	/// Serializes a log's appends, rewrites and removal, so a prune never drops a record appended
	/// meanwhile or brings back a removed file: across threads with one reentrant lock (an append
	/// prunes), and across Arx processes, which share these logs when they run on different
	/// profiles, with `flock` on `<log>.lock`.
	private static let lock: NSRecursiveLock = .init()

	/// Each log's open lock file and how deeply this process holds it. Guarded by `lock`.
	nonisolated(unsafe) private static var held: [String: (descriptor: Int32, depth: Int)] = [:]

	internal static func withLock<Result>(
		_ file: URL,
		_ body: () throws -> Result
	) rethrows -> Result {
		lock.lock()
		defer { lock.unlock() }

		let key: String = file.path
		if var entry = held[key] {
			entry.depth += 1
			held[key] = entry
		} else {
			try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
			let descriptor: Int32 = open(key + ".lock", O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
			if descriptor >= 0 { flock(descriptor, LOCK_EX) }
			held[key] = (descriptor, 1)
		}
		defer {
			if var entry = held[key] {
				entry.depth -= 1
				if entry.depth == 0 {
					if entry.descriptor >= 0 {
						flock(entry.descriptor, LOCK_UN)
						close(entry.descriptor)
					}
					held[key] = nil
				} else {
					held[key] = entry
				}
			}
		}
		return try body()
	}

	internal static func read<Value: Decodable>(
		_ type: Value.Type,
		from file: URL
	) -> [Value] {
		guard let data = try? Data(contentsOf: file) else { return [] }

		let decoder: JSONDecoder = CrashReportStore.decoder
		return data.split(separator: UInt8(ascii: "\n")).compactMap { line in
			try? decoder.decode(type, from: Data(line))
		}
	}

	internal static func append<Value: Encodable>(
		_ value: Value,
		to file: URL
	) {
		guard var line = try? CrashReportStore.encoder.encode(value) else { return }

		line.append(UInt8(ascii: "\n"))
		try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
		if let handle = try? FileHandle(forUpdating: file) {
			defer { try? handle.close() }

			// A write a crash cut short leaves a partial last line; end it so this record stands alone.
			if let end = try? handle.seekToEnd(), end > 0 {
				try? handle.seek(toOffset: end - 1)
				if (try? handle.read(upToCount: 1)) != Data([UInt8(ascii: "\n")]) {
					line.insert(UInt8(ascii: "\n"), at: line.startIndex)
				}
				_ = try? handle.seekToEnd()
			}
			try? handle.write(contentsOf: line)
		} else {
			try? line.write(to: file, options: .atomic)
			ownerOnly(file)
		}
	}

	/// Rewrites `file` with `values`, oldest first, when `force` says it holds records it
	/// shouldn't, or once it's larger than `threshold` bytes.
	internal static func compact<Value: Encodable>(
		file: URL,
		force: Bool,
		threshold: Int,
		values: @autoclosure () -> [Value]
	) {
		let size: Int = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
		guard force || size > threshold else { return }

		let encoder: JSONEncoder = CrashReportStore.encoder
		var data: Data = .init()
		for value in values() {
			guard let line = try? encoder.encode(value) else { continue }

			data.append(line)
			data.append(UInt8(ascii: "\n"))
		}
		try? data.write(to: file, options: .atomic)
		ownerOnly(file)
	}

	/// Diagnostics are the person's own: readable by their account only.
	internal static func ownerOnly(_ file: URL) {
		try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
	}
}
