import Foundation

/// A crash of Arx or one of its engine helpers, reduced to what's needed to find the bug
/// (DEV-887): where it crashed, in which binaries, on which versions.
///
/// It never holds a URL, a page title, page content, a file path or memory. Frames are
/// module-and-offset pairs, modules are file names with their build UUIDs, and the exception
/// is its type and signal only. Raw crash files stay where macOS and Chromium put them.
public struct CrashReport: Codable, Equatable, Hashable, Identifiable, Sendable {
	public enum Source: String, Codable, Hashable, Sendable {
		/// macOS's crash report (`~/Library/Logs/DiagnosticReports/*.ips`), written for Arx itself.
		case system

		/// A minidump Chromium's crash handler wrote for an engine helper (renderer, GPU, network…).
		case engine
	}

	public struct Frame: Codable, Equatable, Hashable, Sendable {
		/// The binary's file name, such as `Arx Framework`.
		public var module: String

		/// The address's offset into that binary.
		public var offset: UInt64

		/// The function, when macOS's report already named it.
		public var symbol: String?

		public init(
			module: String,
			offset: UInt64,
			symbol: String? = nil
		) {
			self.module = module
			self.offset = offset
			self.symbol = symbol
		}
	}

	public struct Module: Codable, Equatable, Hashable, Sendable {
		public var name: String

		/// The Mach-O UUID that matches the binary's dSYM.
		public var uuid: String?

		public init(
			name: String,
			uuid: String?
		) {
			self.name = name
			self.uuid = uuid
		}
	}

	public var id: String
	public var date: Date
	public var source: Source

	/// The crashed process: `Arx`, or a helper such as `Arx Helper (Renderer)`.
	public var process: String

	/// Its process ID, when macOS's report names it, to match it to the run it ended (DEV-1018).
	public var processID: Int32?

	/// Arx's version and build. Only macOS's reports say; an engine helper's report doesn't, and
	/// its `Arx Framework` module UUID identifies the engine build instead.
	public var appVersion: String?
	public var appBuild: String?
	public var osVersion: String?

	/// Such as `EXC_BAD_ACCESS (SIGSEGV)`.
	public var exception: String?

	/// The crashed thread, innermost first.
	public var frames: [Frame]

	/// The binaries the frames are in.
	public var modules: [Module]

	public init(
		id: String,
		date: Date,
		source: Source,
		process: String,
		processID: Int32? = nil,
		appVersion: String? = nil,
		appBuild: String? = nil,
		osVersion: String? = nil,
		exception: String? = nil,
		frames: [Frame] = [],
		modules: [Module] = []
	) {
		self.id = id
		self.date = date
		self.source = source
		self.process = process
		self.processID = processID
		self.appVersion = appVersion
		self.appBuild = appBuild
		self.osVersion = osVersion
		self.exception = exception
		self.frames = frames
		self.modules = modules
	}

	/// The most frames a report keeps.
	public static let frameLimit: Int = 64

	/// A file name without its folders: paths would name the person's account.
	internal static func fileName(_ path: String) -> String {
		path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
	}
}
