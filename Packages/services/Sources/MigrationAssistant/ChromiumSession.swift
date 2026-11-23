import Foundation

/// Reads the open tabs of a Chromium profile from its session file.
///
/// Chromium appends commands to `Sessions/Session_<timestamp>` as tabs change and
/// rebuilds its windows by replaying them. This reader replays the commands that
/// decide which tabs are open and where, following
/// `components/sessions/core/session_service_commands.cc` and
/// `command_storage_backend.cc` in Chromium 156:
///
/// - The file starts with the signature `SNSS` and version 3. Version 5 is encrypted
///   with the Keychain key and isn't read; Chromium still writes a cleartext copy
///   next to it in `Sessions`.
/// - Each command is a little-endian `UInt16` size, a one-byte command ID and
///   `size - 1` bytes of contents. A truncated last command is ignored, as Chromium does.
/// - Contents are either a fixed C struct or a `base::Pickle`.
internal enum ChromiumSession {
	/// A tab in a normal window, in the order Chromium shows it.
	internal struct Tab: Equatable, Sendable {
		internal var url: String
		internal var title: String
		internal var isPinned: Bool

		internal init(
			url: String,
			title: String,
			isPinned: Bool = false
		) {
			self.url = url
			self.title = title
			self.isPinned = isPinned
		}
	}

	internal static let signature: UInt32 = 0x5353_4E53
	internal static let version: Int32 = 3
	internal static let encryptedVersion: Int32 = 5
	internal static let sessionsDirectory: String = "Sessions"
	internal static let filePrefix: String = "Session_"

	internal enum Command: UInt8 {
		case setTabWindow = 0
		case setTabIndexInWindow = 2
		case tabNavigationPathPrunedFromBack = 5
		case updateTabNavigation = 6
		case setSelectedNavigationIndex = 7
		case setWindowType = 9
		case tabNavigationPathPrunedFromFront = 11
		case setPinnedState = 12
		case tabClosed = 16
		case windowClosed = 17
		case tabNavigationPathPruned = 24
	}

	/// `SessionWindow::TYPE_NORMAL`. Popups, app and DevTools windows aren't imported.
	private static let normalWindowType: Int32 = 0

	/// Command 255 ends the initial state Chromium writes when it starts a file. A file
	/// without it was cut short while being rewritten, and Chromium skips it too.
	internal static let initialStateMarker: UInt8 = 255

	/// The newest complete cleartext session file in a profile directory, as Chromium's
	/// `FindLastSessionFile` picks it: by timestamp, skipping files without the marker.
	internal static func latestSession(in profile: URL) -> Data? {
		let directory = profile.appending(path: sessionsDirectory, directoryHint: .isDirectory)
		let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
		let newestFirst = names
			.compactMap { name -> (UInt64, String)? in
				guard name.hasPrefix(filePrefix) else { return nil }

				return UInt64(name.dropFirst(filePrefix.count)).map { ($0, name) }
			}
			.sorted { $0.0 > $1.0 }
		for (_, name) in newestFirst {
			guard
				let data = try? Data(contentsOf: directory.appending(path: name)),
				hasInitialState(data)
			else { continue }

			return data
		}
		return nil
	}

	/// Whether a version 3 file has its initial-state marker.
	internal static func hasInitialState(_ data: Data) -> Bool {
		var reader: ByteReader = .init(data)
		guard reader.uint32() == signature, reader.int32() == version else { return false }

		while let size = reader.uint16() {
			guard size > 0, let body = reader.bytes(Int(size)) else { return false }

			if body[body.startIndex] == initialStateMarker { return true }
		}
		return false
	}

	/// The open tabs of every normal window, windows in the order they were opened.
	internal static func windows(_ data: Data) throws -> [[Tab]] {
		var reader: ByteReader = .init(data)
		guard
			let signature = reader.uint32(),
			let version = reader.int32(),
			signature == Self.signature
		else { throw MigrationFailure.unreadableSource("A Chromium session file has an unknown format.") }

		guard version == Self.version
		else { throw MigrationFailure.unreadableSource("A Chromium session file has an unsupported version.") }

		var state: ReplayState = .init()
		while let size = reader.uint16() {
			guard size > 0, let body = reader.bytes(Int(size)) else { break }

			let contents = body.dropFirst()
			if let command = Command(rawValue: body[body.startIndex]) {
				state.apply(command, contents: Data(contents))
			}
		}
		return state.windows()
	}

	// MARK: - Replay

	private struct SessionTab {
		internal var windowID: Int32?
		internal var visualIndex: Int32 = 0
		internal var currentNavigationIndex: Int32 = -1
		internal var isPinned: Bool = false

		/// Sorted by navigation index, like Chromium's.
		internal var navigations: [Navigation] = []
	}

	private struct Navigation {
		internal var index: Int32
		internal var url: String
		internal var title: String
	}

	private struct ReplayState {
		internal var tabs: [Int32: SessionTab] = [:]
		internal var windowTypes: [Int32: Int32] = [:]

		internal mutating func apply(
			_ command: Command,
			contents: Data
		) {
			var reader: ByteReader = .init(contents)
			switch command {
			case .setTabWindow:
				guard
					contents.count == 8,
					let window = reader.int32(),
					let tab = reader.int32()
				else { return }

				tabs[tab, default: .init()].windowID = window

			case .setTabIndexInWindow:
				guard let (tab, index) = Self.idAndIndex(contents) else { return }

				tabs[tab, default: .init()].visualIndex = index

			case .setSelectedNavigationIndex:
				guard let (tab, index) = Self.idAndIndex(contents) else { return }

				tabs[tab, default: .init()].currentNavigationIndex = index

			case .setWindowType:
				guard let (window, type) = Self.idAndIndex(contents) else { return }

				windowTypes[window] = type

			case .setPinnedState:
				// struct { int32 tab_id; bool pinned_state; }, padded to 8 bytes.
				guard
					contents.count == 8,
					let tab = reader.int32(),
					let pinned = reader.bytes(1)
				else { return }

				tabs[tab, default: .init()].isPinned = pinned[pinned.startIndex] != 0

			case .tabClosed, .windowClosed:
				// struct { int32 id; int64 close_time; }, padded to 16 bytes.
				guard contents.count == 16, let id = reader.int32() else { return }

				if command == .tabClosed {
					tabs[id] = nil
				} else {
					windowTypes[id] = nil
				}

			case .tabNavigationPathPrunedFromBack:
				guard let (tab, index) = Self.idAndIndex(contents), tabs[tab] != nil else { return }

				tabs[tab]?.navigations.removeAll { $0.index >= index }

			case .tabNavigationPathPrunedFromFront:
				guard let (tab, count) = Self.idAndIndex(contents), count > 0 else { return }

				prune(tab, index: 0, count: count)

			case .tabNavigationPathPruned:
				guard
					contents.count == 12,
					let tab = reader.int32(),
					let index = reader.int32(),
					let count = reader.int32(),
					index >= 0,
					count > 0
				else { return }

				prune(tab, index: index, count: count)

			case .updateTabNavigation:
				guard let (tab, navigation) = Self.navigation(contents) else { return }

				var session = tabs[tab, default: .init()]
				if let position = session.navigations.firstIndex(where: { $0.index >= navigation.index }) {
					if session.navigations[position].index == navigation.index {
						session.navigations[position] = navigation
					} else {
						session.navigations.insert(navigation, at: position)
					}
				} else {
					session.navigations.append(navigation)
				}
				tabs[tab] = session
			}
		}

		/// `ProcessTabNavigationPathPrunedCommand`: removes the entries and moves the ones
		/// after them, and the selection, back by the count.
		private mutating func prune(
			_ tab: Int32,
			index: Int32,
			count: Int32
		) {
			// A malformed range past Int32 is ignored rather than trapping.
			guard
				var session = tabs[tab],
				Int64(index) + Int64(count) <= Int64(Int32.max)
			else { return }

			let end = index + count
			if session.currentNavigationIndex >= index, session.currentNavigationIndex < end {
				session.currentNavigationIndex = index - 1
			} else if session.currentNavigationIndex >= end {
				session.currentNavigationIndex -= count
			}
			session.navigations.removeAll { $0.index >= index && $0.index < end }
			for position in session.navigations.indices where session.navigations[position].index >= index {
				session.navigations[position].index -= count
			}
			tabs[tab] = session
		}

		/// Normal windows with tabs, oldest first; their tabs in visual order.
		internal func windows() -> [[Tab]] {
			var byWindow: [Int32: [(id: Int32, tab: SessionTab)]] = [:]
			for (id, tab) in tabs {
				guard
					let window = tab.windowID,
					window != 0,
					!tab.navigations.isEmpty
				else { continue }

				byWindow[window, default: []].append((id, tab))
			}
			return byWindow.keys.sorted().compactMap { window in

				// A window whose type was never set is still "constrained" and dropped.
				guard windowTypes[window] == ChromiumSession.normalWindowType, let entries = byWindow[window]
				else { return nil }

				return entries
					.sorted { lhs, rhs in
						lhs.tab.visualIndex == rhs.tab.visualIndex
						? lhs.id < rhs.id
						: lhs.tab.visualIndex < rhs.tab.visualIndex
					}
					.map { entry in
						let navigation = Self.current(of: entry.tab)
						return Tab(url: navigation.url, title: navigation.title, isPinned: entry.tab.isPinned)
					}
			}
		}

		/// `AddTabsToWindows`: the first navigation at or after the selected index, else the last.
		private static func current(of tab: SessionTab) -> Navigation {
			tab.navigations.first { $0.index >= tab.currentNavigationIndex } ?? tab.navigations[tab.navigations.count - 1]
		}

		/// `IDAndIndexPayload`: struct { int32 id; int32 index; }.
		private static func idAndIndex(_ contents: Data) -> (Int32, Int32)? {
			var reader: ByteReader = .init(contents)
			guard
				contents.count == 8,
				let id = reader.int32(),
				let index = reader.int32()
			else { return nil }

			return (id, index)
		}

		/// A pickle of the tab ID, then `SerializedNavigationEntry::WriteToPickle`:
		/// index, virtual URL, title and fields this reader doesn't need.
		private static func navigation(_ contents: Data) -> (Int32, Navigation)? {
			var pickle: PickleReader = .init(contents)
			guard
				let tab = pickle.int32(),
				let index = pickle.int32(),
				let url = pickle.string(),
				let title = pickle.string16()
			else { return nil }

			return (tab, .init(index: index, url: url, title: title))
		}
	}
}

// MARK: - Bytes

/// Reads little-endian values from the front of some bytes.
internal struct ByteReader {
	private let data: Data
	internal private(set) var offset: Int

	internal init(_ data: Data) {
		self.data = data
		self.offset = data.startIndex
	}

	internal var remaining: Int { data.endIndex - offset }

	internal mutating func bytes(_ count: Int) -> Data? {
		guard count >= 0, count <= remaining else { return nil }

		defer { offset += count }
		return data[offset..<offset + count]
	}

	internal mutating func skip(_ count: Int) -> Bool {
		bytes(count) != nil
	}

	internal mutating func uint16() -> UInt16? {
		bytes(2).map { bytes in
			bytes.reversed().reduce(0) { $0 << 8 | UInt16($1) }
		}
	}

	internal mutating func uint32() -> UInt32? {
		bytes(4).map { bytes in
			bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
		}
	}

	internal mutating func int32() -> Int32? {
		uint32().map { Int32(bitPattern: $0) }
	}
}

/// Reads a `base::Pickle`: a `UInt32` payload size, then fields aligned to four bytes.
internal struct PickleReader {
	private var reader: ByteReader

	internal init(_ data: Data) {
		var reader: ByteReader = .init(data)

		// The header's payload size; the command's own size already bounds the data.
		_ = reader.uint32()
		self.reader = reader
	}

	internal mutating func int32() -> Int32? {
		reader.int32()
	}

	/// A length, then UTF-8 bytes padded to four bytes.
	internal mutating func string() -> String? {
		guard
			let length = reader.int32(),
			length >= 0,
			let bytes = aligned(Int(length))
		else { return nil }

		return String(decoding: bytes, as: UTF8.self)
	}

	/// A length in UTF-16 code units, then the units padded to four bytes.
	internal mutating func string16() -> String? {
		guard
			let length = reader.int32(),
			length >= 0,
			length <= Int32.max / 2,
			let bytes = aligned(Int(length) * 2)
		else { return nil }

		let units = stride(from: bytes.startIndex, to: bytes.endIndex, by: 2).map { index in
			UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
		}
		return String(decoding: units, as: UTF16.self)
	}

	private mutating func aligned(_ count: Int) -> Data? {
		guard let bytes = reader.bytes(count) else { return nil }

		let padding = (4 - count % 4) % 4
		_ = reader.skip(min(padding, reader.remaining))
		return bytes
	}
}
