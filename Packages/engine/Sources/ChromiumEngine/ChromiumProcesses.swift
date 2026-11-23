import ChromiumBridge
import Foundation

/// A live renderer process the engine knows, for the Task Manager (DEV-898).
public struct ChromiumProcess: Equatable, Sendable {
	public enum Owner: Equatable, Sendable {
		/// A page's renderer. Several pages can share one process.
		case page(UInt64)

		/// An extension's renderer: its background page, service worker or popup.
		case extensionID(String)
	}

	public var pid: Int32
	public var owner: Owner
	public var isPrivate: Bool

	public init(
		pid: Int32,
		owner: Owner,
		isPrivate: Bool
	) {
		self.pid = pid
		self.owner = owner
		self.isPrivate = isPrivate
	}
}

extension ChromiumRuntime {
	/// Whether this engine can list and end its renderer processes (DEV-898).
	public var supportsProcesses: Bool { processFunctions != nil }

	/// The engine's live renderer processes: one entry per page and per extension running in one.
	/// Empty while the engine isn't running or predates the Task Manager.
	public func processes() -> [ChromiumProcess] {
		guard state == .running, let processFunctions else { return [] }

		// The count can grow between the two calls; a second, larger read settles it.
		var capacity = 64
		for _ in 0..<3 {
			var entries = [ArxEngineProcess](repeating: .init(), count: capacity)
			let count = entries.withUnsafeMutableBufferPointer { buffer in
				processFunctions.copy(buffer.baseAddress, capacity)
			}
			guard count > capacity else {
				return entries.prefix(count).compactMap(Self.process)
			}
			capacity = min(count + 16, 4_096)
		}
		return []
	}

	/// Ends a renderer process the engine reported, the way Chrome's Task Manager does. False for
	/// any other process.
	public func endProcess(_ pid: Int32) -> Bool {
		guard state == .running, let processFunctions else { return false }
		return processFunctions.end(pid)
	}

	private static func process(_ entry: ArxEngineProcess) -> ChromiumProcess? {
		guard entry.pid > 0 else { return nil }

		switch entry.kind {
		case Int32(ARX_ENGINE_PROCESS_PAGE.rawValue):
			return .init(pid: entry.pid, owner: .page(entry.page), isPrivate: entry.is_private)

		case Int32(ARX_ENGINE_PROCESS_EXTENSION.rawValue):
			let id = withUnsafeBytes(of: entry.extension_id) { bytes in
				String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
			}
			guard !id.isEmpty else { return nil }
			return .init(pid: entry.pid, owner: .extensionID(id), isPrivate: entry.is_private)

		default:
			return nil
		}
	}
}
