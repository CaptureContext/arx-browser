import Darwin
import Dispatch
import _Dependencies

/// The system's memory pressure, which Arx answers by unloading hidden tabs (DEV-873).
///
/// The live client reads the macOS source Chromium's own evaluator reads: the kernel's
/// pressure level, then the dispatch memory-pressure source for each change.
public struct MemoryPressureClient: Sendable {
	/// The current level, when the system reports one, then every change, until the consumer
	/// stops listening.
	public var levels: @Sendable () -> AsyncStream<MemoryPressureLevel>

	public init(levels: @escaping @Sendable () -> AsyncStream<MemoryPressureLevel>) {
		self.levels = levels
	}
}

/// How short of memory the system is, as macOS reports it.
public enum MemoryPressureLevel: Int, Comparable, Equatable, Sendable {
	case normal

	/// The system is compressing and swapping memory.
	case warning

	/// The system is about to end processes to get memory back.
	case critical

	public static func < (lhs: Self, rhs: Self) -> Bool {
		lhs.rawValue < rhs.rawValue
	}
}

// MARK: - Live

extension MemoryPressureClient {
	public static var live: Self {
		.init(levels: {
			AsyncStream { continuation in
				if let level = MemoryPressureLevel.current { continuation.yield(level) }
				let source = PressureSource(continuation: continuation)
				continuation.onTermination = { _ in source.cancel() }
			}
		})
	}
}

extension MemoryPressureLevel {
	/// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
	internal init(kernelLevel: Int32) {
		switch kernelLevel {
		case 4: self = .critical
		case 2: self = .warning
		default: self = .normal
		}
	}

	internal init(_ event: DispatchSource.MemoryPressureEvent) {
		if event.contains(.critical) {
			self = .critical
		} else if event.contains(.warning) {
			self = .warning
		} else {
			self = .normal
		}
	}

	/// The kernel's level now, or nil when it can't be read.
	fileprivate static var current: Self? {
		var level: Int32 = 0
		var size: Int = MemoryLayout<Int32>.size
		guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
		else { return nil }

		return .init(kernelLevel: level)
	}
}

/// Owns one dispatch memory-pressure source for one stream.
private final class PressureSource: @unchecked Sendable {
	private let source: DispatchSourceMemoryPressure

	fileprivate init(continuation: AsyncStream<MemoryPressureLevel>.Continuation) {
		let source = DispatchSource.makeMemoryPressureSource(
			eventMask: [.normal, .warning, .critical],
			queue: .main
		)
		source.setEventHandler { [weak source] in
			guard let source else { return }
			continuation.yield(MemoryPressureLevel(source.data))
		}
		self.source = source
		source.activate()
	}

	fileprivate func cancel() {
		source.cancel()
	}
}

// MARK: - Dependency

extension MemoryPressureClient: DependencyKey {
	public static var liveValue: Self { .live }

	/// Tests that start tab unloading supply their own levels.
	public static var testValue: Self {
		.init(levels: unimplemented("MemoryPressureClient.levels", placeholder: .finished))
	}

	/// Previews never come under pressure.
	public static var previewValue: Self {
		.init(levels: { .finished })
	}
}

extension DependencyValues {
	public var memoryPressure: MemoryPressureClient {
		get { self[MemoryPressureClient.self] }
		set { self[MemoryPressureClient.self] = newValue }
	}
}
