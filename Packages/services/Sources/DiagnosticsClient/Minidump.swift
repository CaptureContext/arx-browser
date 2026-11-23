import Foundation

/// Reads the parts of a Chromium (Crashpad) minidump that locate a crash, for an engine helper
/// such as the renderer (DEV-887).
///
/// A minidump holds raw memory: thread stacks, and Chromium's annotations, including the page's
/// URL. None of it leaves this reader. It reads the exception, the module list (names and build
/// UUIDs) and the crashed thread's registers, then follows that thread's frame-pointer chain
/// through its stack and keeps only return addresses that fall inside a module, as
/// module-and-offset pairs. Only arm64 contexts are read; other architectures give no frames.
public enum Minidump {
	internal static let signature: UInt32 = 0x504D_444D // "MDMP"
	internal static let codeViewPDB70: UInt32 = 0x5344_5352 // "RSDS"

	internal enum Stream: UInt32 {
		case threadList = 3
		case moduleList = 4
		case exception = 6
		case systemInfo = 7
	}

	/// Byte offsets in Crashpad's `MinidumpContextARM64`.
	internal enum ARM64Context {
		internal static let fp: Int = 240
		internal static let lr: Int = 248
		internal static let sp: Int = 256
		internal static let pc: Int = 264
		internal static let size: Int = 272
	}

	/// User-space addresses fit in 47 bits; higher bits can carry pointer authentication codes.
	internal static let addressMask: UInt64 = 0x0000_7FFF_FFFF_FFFF

	public static func parse(
		_ data: Data,
		id: String,
		fallbackDate: Date
	) -> CrashReport? {
		let reader: Reader = .init(data: data)
		guard
			reader.u32(0) == signature,
			let count = reader.u32(8),
			let directory = reader.u32(12)
		else { return nil }

		var streams: [UInt32: (size: Int, offset: Int)] = [:]
		for index in 0..<Int(min(count, 256)) {
			let entry: Int = Int(directory) + index * 12
			guard
				let type = reader.u32(entry),
				let size = reader.u32(entry + 4),
				let offset = reader.u32(entry + 8)
			else { return nil }

			streams[type] = streams[type] ?? (Int(size), Int(offset))
		}

		let modules: [LoadedModule] = streams[Stream.moduleList.rawValue].map { moduleList(reader, at: $0.offset) } ?? []
		let exception: ExceptionInfo? = streams[Stream.exception.rawValue].flatMap { exceptionInfo(reader, at: $0.offset) }
		let addresses: [UInt64] = exception.map { backtrace(reader, exception: $0, threadList: streams[Stream.threadList.rawValue]?.offset) } ?? []

		var frames: [CrashReport.Frame] = []
		var used: [LoadedModule] = []
		for address in addresses {
			guard let module = modules.first(where: { $0.contains(address) })
			else { continue }

			frames.append(.init(module: module.name, offset: address - module.base))
			if !used.contains(module) { used.append(module) }
			if frames.count == CrashReport.frameLimit { break }
		}

		let timestamp: UInt32 = reader.u32(20) ?? 0
		return CrashReport(
			id: id,
			date: timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : fallbackDate,
			source: .engine,
			process: modules.first?.name ?? "Arx Helper",
			osVersion: streams[Stream.systemInfo.rawValue].flatMap { systemVersion(reader, at: $0.offset) },
			exception: exception.map(\.description),
			frames: frames,
			modules: used.map { .init(name: $0.name, uuid: $0.uuid) }
		)
	}

	// MARK: - Modules

	internal struct LoadedModule: Equatable {
		internal var name: String
		internal var base: UInt64
		internal var size: UInt64
		internal var uuid: String?

		internal func contains(_ address: UInt64) -> Bool {
			address >= base && address - base < size
		}
	}

	/// `MINIDUMP_MODULE` entries, 108 bytes each.
	private static func moduleList(
		_ reader: Reader,
		at offset: Int
	) -> [LoadedModule] {
		guard let count = reader.u32(offset)
		else { return [] }

		var modules: [LoadedModule] = []
		for index in 0..<Int(min(count, 4096)) {
			let entry: Int = offset + 4 + index * 108
			guard
				let base = reader.u64(entry),
				let size = reader.u32(entry + 8),
				let nameOffset = reader.u32(entry + 20),
				let name = reader.utf16String(Int(nameOffset))
			else { break }

			let codeViewSize: UInt32 = reader.u32(entry + 76) ?? 0
			let codeViewOffset: UInt32 = reader.u32(entry + 80) ?? 0
			modules.append(
				.init(
					name: CrashReport.fileName(name),
					base: base,
					size: UInt64(size),
					uuid: codeViewSize >= 24 ? uuid(reader, at: Int(codeViewOffset)) : nil
				)
			)
		}
		return modules
	}

	/// The Mach-O UUID from a CodeView PDB 7.0 record, written as a GUID in host byte order.
	private static func uuid(
		_ reader: Reader,
		at offset: Int
	) -> String? {
		guard
			reader.u32(offset) == codeViewPDB70,
			let first = reader.u32(offset + 4),
			let second = reader.u16(offset + 8),
			let third = reader.u16(offset + 10),
			let rest = reader.bytes(offset + 12, count: 8)
		else { return nil }

		let tail: String = rest.map { String(format: "%02X", $0) }.joined()
		let head: String = String(format: "%08X-%04X-%04X-", first, second, third)
		return head + String(tail.prefix(4)) + "-" + String(tail.dropFirst(4))
	}

	// MARK: - Exception

	internal struct ExceptionInfo {
		internal var threadID: UInt32
		internal var type: UInt32
		internal var code: UInt32
		internal var contextOffset: Int
		internal var contextSize: Int

		/// The Mach exception and its first code, as macOS names them.
		internal var description: String {
			let names: [UInt32: String] = [
				1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
				5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD",
			]
			let name: String = names[type] ?? "exception \(type)"
			return "\(name) (code \(code))"
		}
	}

	/// `MINIDUMP_EXCEPTION_STREAM`: the thread, the exception record (152 bytes), then the context.
	private static func exceptionInfo(
		_ reader: Reader,
		at offset: Int
	) -> ExceptionInfo? {
		guard
			let thread = reader.u32(offset),
			let type = reader.u32(offset + 8),
			let code = reader.u32(offset + 12),
			let contextSize = reader.u32(offset + 160),
			let contextOffset = reader.u32(offset + 164)
		else { return nil }

		return .init(
			threadID: thread,
			type: type,
			code: code,
			contextOffset: Int(contextOffset),
			contextSize: Int(contextSize)
		)
	}

	// MARK: - Backtrace

	/// The program counter, then each return address on the frame-pointer chain. Without the
	/// thread's stack, the link register is the best guess at the caller.
	private static func backtrace(
		_ reader: Reader,
		exception: ExceptionInfo,
		threadList: Int?
	) -> [UInt64] {
		guard
			exception.contextSize >= ARM64Context.size,
			let pc = reader.u64(exception.contextOffset + ARM64Context.pc),
			let lr = reader.u64(exception.contextOffset + ARM64Context.lr),
			var fp = reader.u64(exception.contextOffset + ARM64Context.fp)
		else { return [] }

		let addresses: [UInt64] = [pc & addressMask]
		guard let stack = threadList.flatMap({ stackMemory(reader, at: $0, threadID: exception.threadID) })
		else { return addresses + [lr & addressMask] }

		// The link register is left out here: after a call returns it points inside the crashed
		// function itself, and nothing in the dump says whether it still names the caller.
		var returns: [UInt64] = []
		while returns.count < CrashReport.frameLimit, let record = stack.record(at: fp) {
			returns.append(record.returnAddress & addressMask)
			guard record.previous > fp else { break }
			fp = record.previous
		}
		return addresses + returns
	}

	internal struct StackMemory {
		internal var start: UInt64
		internal var bytes: Data

		/// The saved frame pointer and return address at `fp`, when both lie inside the stack.
		internal func record(at fp: UInt64) -> (previous: UInt64, returnAddress: UInt64)? {
			guard fp >= start, fp - start <= UInt64(bytes.count), UInt64(bytes.count) - (fp - start) >= 16
			else { return nil }

			let offset: Int = Int(fp - start)
			let reader: Reader = .init(data: bytes)
			guard let previous = reader.u64(offset), let returnAddress = reader.u64(offset + 8)
			else { return nil }

			return (previous, returnAddress)
		}
	}

	/// `MINIDUMP_THREAD` entries, 48 bytes each; the stack is a memory descriptor at +24.
	private static func stackMemory(
		_ reader: Reader,
		at offset: Int,
		threadID: UInt32
	) -> StackMemory? {
		guard let count = reader.u32(offset)
		else { return nil }

		for index in 0..<Int(min(count, 4096)) {
			let entry: Int = offset + 4 + index * 48
			guard reader.u32(entry) == threadID
			else { continue }

			guard
				let start = reader.u64(entry + 24),
				let size = reader.u32(entry + 32),
				let location = reader.u32(entry + 36),
				let bytes = reader.bytes(Int(location), count: Int(size))
			else { return nil }

			return .init(start: start, bytes: Data(bytes))
		}
		return nil
	}

	// MARK: - System

	/// `MINIDUMP_SYSTEM_INFO`: major, minor and build (macOS's patch version) at +8, +12 and +16.
	private static func systemVersion(
		_ reader: Reader,
		at offset: Int
	) -> String? {
		guard
			let major = reader.u32(offset + 8),
			let minor = reader.u32(offset + 12),
			let patch = reader.u32(offset + 16),
			major > 0
		else { return nil }

		return "macOS \(major).\(minor).\(patch)"
	}
}

// MARK: - Reader

/// Bounds-checked little-endian reads.
internal struct Reader {
	internal let data: Data

	internal func bytes(
		_ offset: Int,
		count: Int
	) -> [UInt8]? {
		guard offset >= 0, count >= 0, offset <= data.count, data.count - offset >= count
		else { return nil }

		let start: Data.Index = data.index(data.startIndex, offsetBy: offset)
		return Array(data[start..<data.index(start, offsetBy: count)])
	}

	internal func u16(_ offset: Int) -> UInt16? {
		bytes(offset, count: 2).map { UInt16($0[0]) | UInt16($0[1]) << 8 }
	}

	internal func u32(_ offset: Int) -> UInt32? {
		bytes(offset, count: 4).map { bytes in
			bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
		}
	}

	internal func u64(_ offset: Int) -> UInt64? {
		bytes(offset, count: 8).map { bytes in
			bytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
		}
	}

	/// A `MINIDUMP_STRING`: its length in bytes, then UTF-16LE.
	internal func utf16String(_ offset: Int) -> String? {
		guard
			let length = u32(offset),
			length <= 4096,
			let bytes = bytes(offset + 4, count: Int(length))
		else { return nil }

		let units: [UInt16] = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
		return String(decoding: units, as: UTF16.self)
	}
}
