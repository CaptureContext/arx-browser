import BrowserCore
import Darwin
import Foundation

/// One of Arx's processes as the Task Manager lists it (DEV-898): Arx itself, which is also
/// Chromium's browser process, and every helper it started.
public struct BrowserProcess: Equatable, Identifiable, Sendable {
	public enum Kind: Equatable, Sendable {
		/// Arx itself.
		case browser
		case gpu

		/// A utility process, with Chromium's service name when it has one, such as `NetworkService`.
		case utility(String?)
		case renderer

		/// Any other helper, with its `--type`.
		case other(String)
	}

	/// What runs in a renderer: tabs, extensions, or nothing Arx knows (a spare renderer).
	public enum Owner: Equatable, Hashable, Sendable {
		case tab(Tab.ID)
		case privateTab(Tab.ID)
		case extensionID(String)
	}

	public var id: Int32 { pid }
	public var pid: Int32
	public var kind: Kind
	public var owners: [Owner]

	/// Physical footprint in bytes, the number Activity Monitor shows as Memory.
	public var memory: UInt64

	/// User and system CPU time since the process started, in seconds.
	public var cpuTime: TimeInterval

	public init(
		pid: Int32,
		kind: Kind,
		owners: [Owner] = [],
		memory: UInt64,
		cpuTime: TimeInterval
	) {
		self.pid = pid
		self.kind = kind
		self.owners = owners
		self.memory = memory
		self.cpuTime = cpuTime
	}

	/// Only renderers end: a tab's or an extension's, as in Chrome's Task Manager. Arx itself, the
	/// GPU process and utility processes don't.
	public var canEnd: Bool { kind == .renderer }
}

/// Every process of Arx at one moment (DEV-898).
public struct BrowserProcessTable: Equatable, Sendable {
	public var processes: [BrowserProcess]
	public var sampledAt: Date

	public init(
		processes: [BrowserProcess],
		sampledAt: Date
	) {
		self.processes = processes
		self.sampledAt = sampledAt
	}
}

/// Reads Arx's own process tree without root, as `Scripts/core/process_metrics.py` does for the
/// benchmark (DEV-933): `proc_pid_rusage` for each process's footprint and CPU time, the child
/// processes of Arx, and each helper's role from its `--type=` switch. Nothing is matched by name.
public enum BrowserProcessSampler {
	/// Samples Arx and its helpers. `owners` names what runs in each renderer, from the engine.
	public static func sample(
		owners: [Int32: [BrowserProcess.Owner]],
		root: Int32 = getpid(),
		now: Date = Date()
	) -> BrowserProcessTable {
		let pids = [root] + descendants(of: root)
		let processes: [BrowserProcess] = pids.compactMap { pid in
			guard let usage = usage(pid) else { return nil }

			let kind: BrowserProcess.Kind = pid == root ? .browser : kind(arguments(pid) ?? [])
			return .init(
				pid: pid,
				kind: owners[pid] == nil ? kind : .renderer,
				owners: owners[pid] ?? [],
				memory: usage.memory,
				cpuTime: usage.cpuTime
			)
		}
		return .init(processes: processes, sampledAt: now)
	}

	/// A Chromium helper's role from its command line.
	public static func kind(_ arguments: [String]) -> BrowserProcess.Kind {
		guard let type = value(of: "--type=", in: arguments) else { return .other("unknown") }

		switch type {
		case "renderer": return .renderer
		case "gpu-process": return .gpu
		case "utility":
			let service = value(of: "--utility-sub-type=", in: arguments)
				.map { $0.split(separator: ".").last.map(String.init) ?? $0 }
			return .utility(service)
		default: return .other(type)
		}
	}

	private static func value(
		of prefix: String,
		in arguments: [String]
	) -> String? {
		arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
	}

	/// Every process started by `pid`, and theirs, depth first.
	public static func descendants(of pid: Int32) -> [Int32] {
		var result: [Int32] = []
		var pending: [Int32] = [pid]
		while let parent = pending.popLast(), result.count < 4_096 {
			let children = self.children(of: parent)
			result.append(contentsOf: children)
			pending.append(contentsOf: children)
		}
		return result
	}

	private static func children(of pid: Int32) -> [Int32] {
		let needed = proc_listchildpids(pid, nil, 0)
		guard needed > 0 else { return [] }

		var buffer = [Int32](repeating: 0, count: Int(needed) + 16)
		let count = buffer.withUnsafeMutableBytes { bytes in
			proc_listchildpids(pid, bytes.baseAddress, Int32(bytes.count))
		}
		guard count > 0 else { return [] }
		return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
	}

	/// The process's footprint and CPU time, or nil when it exited or can't be read.
	public static func usage(_ pid: Int32) -> (memory: UInt64, cpuTime: TimeInterval)? {
		var info = rusage_info_v4()
		let status = withUnsafeMutablePointer(to: &info) { pointer in
			pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
				proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
			}
		}
		guard status == 0 else { return nil }

		let ticks = Double(info.ri_user_time + info.ri_system_time)
		return (info.ri_phys_footprint, ticks * nanosecondsPerTick / 1_000_000_000)
	}

	/// rusage CPU times are Mach absolute time units: nanoseconds on Intel, 1/24 µs ticks on Apple silicon.
	private static let nanosecondsPerTick: Double = {
		var timebase = mach_timebase_info_data_t()
		mach_timebase_info(&timebase)
		return timebase.denom == 0 ? 1 : Double(timebase.numer) / Double(timebase.denom)
	}()

	/// The process's arguments after its executable, from `KERN_PROCARGS2`.
	public static func arguments(_ pid: Int32) -> [String]? {
		var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
		var size = 0
		guard
			sysctl(&mib, 3, nil, &size, nil, 0) == 0,
			size > MemoryLayout<Int32>.size
		else { return nil }

		var buffer = [UInt8](repeating: 0, count: size)
		guard
			sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
			size > MemoryLayout<Int32>.size
		else { return nil }

		let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }

		// argc, the executable path, padding NULs, then argv[0] to argv[argc - 1].
		var strings: [String] = []
		var start = MemoryLayout<Int32>.size
		while start < size, strings.count <= Int(argc) {
			guard let end = buffer[start..<size].firstIndex(of: 0) else { break }
			if end > start { strings.append(String(decoding: buffer[start..<end], as: UTF8.self)) }
			start = end + 1
		}

		// The first string is the executable path; argv[0] follows.
		return Array(strings.dropFirst().prefix(Int(argc)))
	}
}
