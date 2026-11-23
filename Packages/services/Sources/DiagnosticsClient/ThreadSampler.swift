import Darwin
import Foundation
import MachO

/// Reads another thread's stack (DEV-1010): suspends it, follows its frame-pointer chain, resumes
/// it, and only then names each address.
///
/// While the thread is suspended the sampler only reads registers and memory into buffers it
/// allocated up front, so it never waits on a lock the suspended thread may hold (malloc, dyld,
/// the Swift runtime). Memory is read with `vm_read_overwrite`, so a damaged chain ends the walk
/// instead of crashing.
internal final class ThreadSampler: @unchecked Sendable {
	/// The deepest stack it follows.
	internal static let frameLimit: Int = CrashReport.frameLimit

	private let thread: thread_act_t
	private let addresses: UnsafeMutablePointer<UInt>
	private let pair: UnsafeMutablePointer<UInt>

	/// - Parameters:
	///   - thread: a Mach thread port of this process, such as
	///     `pthread_mach_thread_np(pthread_self())` taken on the thread to watch.
	internal init(thread: thread_act_t) {
		self.thread = thread
		self.addresses = .allocate(capacity: Self.frameLimit)
		self.pair = .allocate(capacity: 2)
	}

	deinit {
		addresses.deallocate()
		pair.deallocate()
	}

	/// The thread's return addresses, innermost first, or none when it can't be suspended.
	internal func sample() -> [UInt] {
		guard thread != pthread_mach_thread_np(pthread_self()) else { return [] }
		guard thread_suspend(thread) == KERN_SUCCESS else { return [] }

		let count: Int = walk()
		thread_resume(thread)
		return Array(UnsafeBufferPointer(start: addresses, count: count))
	}

	/// The sampled stack, named: each address's binary, its offset there and the function.
	internal func frames() -> (frames: [CrashReport.Frame], modules: [CrashReport.Module]) {
		Self.symbolicate(sample())
	}

	// MARK: - Walking (thread suspended: no allocation)

	private func walk() -> Int {
		var count: Int = 0
		var framePointer: UInt = 0
		#if arch(arm64)
		var state: arm_thread_state64_t = .init()
		var stateCount: mach_msg_type_number_t = mach_msg_type_number_t(
			MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
		)
		let result: kern_return_t = withUnsafeMutablePointer(to: &state) { pointer in
			pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
				thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
			}
		}
		guard result == KERN_SUCCESS else { return 0 }

		addresses[count] = Self.strip(UInt(state.__pc))
		count += 1

		// A leaf function may not have saved its return address on the stack yet.
		addresses[count] = Self.strip(UInt(state.__lr))
		count += 1
		framePointer = UInt(state.__fp)
		#elseif arch(x86_64)
		var state: x86_thread_state64_t = .init()
		var stateCount: mach_msg_type_number_t = mach_msg_type_number_t(
			MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
		)
		let result: kern_return_t = withUnsafeMutablePointer(to: &state) { pointer in
			pointer.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
				thread_get_state(thread, thread_state_flavor_t(x86_THREAD_STATE64), $0, &stateCount)
			}
		}
		guard result == KERN_SUCCESS else { return 0 }

		addresses[count] = UInt(state.__rip)
		count += 1
		framePointer = UInt(state.__rbp)
		#endif

		while framePointer != 0, count < Self.frameLimit {
			var read: vm_size_t = 0
			let status: kern_return_t = vm_read_overwrite(
				mach_task_self_,
				vm_address_t(framePointer),
				vm_size_t(2 * MemoryLayout<UInt>.size),
				vm_address_t(UInt(bitPattern: pair)),
				&read
			)
			guard status == KERN_SUCCESS, read == vm_size_t(2 * MemoryLayout<UInt>.size) else { break }

			let next: UInt = pair[0]
			let returnAddress: UInt = Self.strip(pair[1])
			guard returnAddress != 0 else { break }

			addresses[count] = returnAddress
			count += 1

			// Frames grow toward higher addresses as the walk goes out; anything else is a broken chain.
			guard next > framePointer else { break }

			framePointer = next
		}
		return count
	}

	/// Drops pointer-authentication bits from a code address.
	private static func strip(_ address: UInt) -> UInt {
		#if arch(arm64)
		address & 0x0000_007F_FFFF_FFFF
		#else
		address
		#endif
	}

	// MARK: - Naming (thread running again)

	/// Names addresses with `dladdr`: a binary's file name (never its folder), the offset into it,
	/// and the demangled function when the binary exports a symbol for it.
	internal static func symbolicate(_ addresses: [UInt]) -> (frames: [CrashReport.Frame], modules: [CrashReport.Module]) {
		var frames: [CrashReport.Frame] = []
		var modules: [CrashReport.Module] = []
		var seenModules: Set<String> = []
		for (index, address) in addresses.enumerated() {
			// A return address points after its call; look up the call itself.
			let lookup: UInt = index == 0 || address == 0 ? address : address - 1
			var info: Dl_info = .init()
			guard
				let pointer = UnsafeRawPointer(bitPattern: lookup),
				dladdr(pointer, &info) != 0,
				let path = info.dli_fname,
				let base = info.dli_fbase
			else {
				frames.append(.init(module: "?", offset: UInt64(address)))
				continue
			}

			let module: String = CrashReport.fileName(String(cString: path))
			let symbol: String? = info.dli_sname.map { demangle(String(cString: $0)) }
			frames.append(.init(module: module, offset: UInt64(address - UInt(bitPattern: base)), symbol: symbol))
			if seenModules.insert(module).inserted {
				modules.append(.init(name: module, uuid: uuid(of: base)))
			}
		}
		return (frames, modules)
	}

	private typealias Demangle = @convention(c) (
		UnsafePointer<CChar>?,
		Int,
		UnsafeMutablePointer<CChar>?,
		UnsafeMutablePointer<Int>?,
		UInt32
	) -> UnsafeMutablePointer<CChar>?

	private static let swiftDemangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
		.map { unsafeBitCast($0, to: Demangle.self) }

	/// Swift symbols demangled; anything else unchanged.
	internal static func demangle(_ symbol: String) -> String {
		guard let swiftDemangle, symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return symbol }

		let name: String = symbol.hasPrefix("_") ? String(symbol.dropFirst()) : symbol
		return name.withCString { pointer in
			guard let demangled = swiftDemangle(pointer, strlen(pointer), nil, nil, 0) else { return symbol }

			defer { free(demangled) }
			return String(cString: demangled)
		}
	}

	/// The binary's `LC_UUID`, which matches its dSYM.
	private static func uuid(of base: UnsafeMutableRawPointer) -> String? {
		let header: UnsafePointer<mach_header_64> = UnsafeRawPointer(base).assumingMemoryBound(to: mach_header_64.self)
		guard header.pointee.magic == MH_MAGIC_64 else { return nil }

		var command: UnsafeRawPointer = UnsafeRawPointer(base).advanced(by: MemoryLayout<mach_header_64>.size)
		for _ in 0 ..< header.pointee.ncmds {
			let load: load_command = command.load(as: load_command.self)
			if load.cmd == LC_UUID {
				let value: uuid_command = command.load(as: uuid_command.self)
				return UUID(uuid: value.uuid).uuidString
			}
			command = command.advanced(by: Int(load.cmdsize))
		}
		return nil
	}
}
