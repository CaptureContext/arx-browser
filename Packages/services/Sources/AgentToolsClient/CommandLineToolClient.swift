import BrowserAutomationClient
import Foundation
import _Dependencies

/// Installs, updates and uninstalls the `arx` command at `~/.local/bin/arx`, copied from
/// the helper bundled in the app, and says whether that folder is on the person's PATH.
public struct CommandLineToolClient: Sendable {
	/// What is installed now.
	public var status: @Sendable () async -> Status

	/// Copies the bundled helper over Arx's own copy, or into an empty location. Also updates.
	public var install: @Sendable () async throws -> Void

	/// Removes Arx's copy.
	public var uninstall: @Sendable () async throws -> Void

	public init(
		status: @escaping @Sendable () async -> Status,
		install: @escaping @Sendable () async throws -> Void,
		uninstall: @escaping @Sendable () async throws -> Void
	) {
		self.status = status
		self.install = install
		self.uninstall = uninstall
	}
}

// MARK: - Types

extension CommandLineToolClient {
	public struct Status: Equatable, Sendable {
		public var installation: Installation

		/// The installed command, written with `~` for the home folder.
		public var location: String

		/// Whether the install folder is on the login shell's PATH; `nil` when it couldn't be read.
		public var isOnPath: Bool?

		/// What to add to the shell profile when the folder isn't on the PATH.
		public var pathAdvice: CommandLineTool.PathAdvice

		public init(
			installation: Installation,
			location: String = "~/" + CommandLineTool.relativePath,
			isOnPath: Bool? = nil,
			pathAdvice: CommandLineTool.PathAdvice = CommandLineTool.pathAdvice(shell: "/bin/zsh")
		) {
			self.installation = installation
			self.location = location
			self.isOnPath = isOnPath
			self.pathAdvice = pathAdvice
		}

		public static var unavailable: Self { .init(installation: .unavailable) }
	}

	public enum Installation: Equatable, Sendable {
		/// This run may not install anything, or the app has no bundled helper.
		case unavailable
		case notInstalled
		case current

		/// The bundled helper differs from the installed copy, so Update is offered.
		case outdated

		/// Another file is at the install location; Arx leaves it alone.
		case blocked
	}

	/// A client that never touches the file system, for automated runs.
	public static var unavailable: Self {
		.init(
			status: { .unavailable },
			install: { throw CommandLineTool.Failure.missingHelper },
			uninstall: {}
		)
	}

	/// Works on `home` only, so tests can point it at a temporary folder.
	///
	/// - Parameters:
	///   - bundled: The helper to copy, or `nil` when the app has none.
	///   - shell: The login shell, which picks the profile to suggest.
	///   - loginPath: The login shell's PATH, or `nil` when it can't be read.
	///   - isArxTool: Whether a file at the install location is Arx's helper.
	public static func files(
		home: URL,
		bundled: URL?,
		shell: String?,
		loginPath: @escaping @Sendable () async -> String?,
		isArxTool: @escaping @Sendable (URL) -> Bool
	) -> Self {
		let installed: URL = CommandLineTool.url(home: home)
		return .init(
			status: {
				guard let bundled, FileManager.default.isExecutableFile(atPath: bundled.path)
				else { return .unavailable }

				let installation: Installation = switch CommandLineTool.state(
					installed: installed,
					bundled: bundled,
					isArxTool: isArxTool
				) {
				case .notInstalled: .notInstalled
				case .current: .current
				case .outdated: .outdated
				case .foreign: .blocked
				}
				let isOnPath: Bool? = await loginPath().map { path in
					CommandLineTool.isOnPath(installed.deletingLastPathComponent(), path: path, home: home)
				}
				return .init(
					installation: installation,
					isOnPath: isOnPath,
					pathAdvice: CommandLineTool.pathAdvice(shell: shell)
				)
			},
			install: {
				guard let bundled
				else { throw CommandLineTool.Failure.missingHelper }

				try CommandLineTool.install(from: bundled, to: installed, isArxTool: isArxTool)
			},
			uninstall: {
				guard let bundled
				else { throw CommandLineTool.Failure.missingHelper }

				try CommandLineTool.uninstall(installed, bundled: bundled, isArxTool: isArxTool)
			}
		)
	}
}

// MARK: - Dependency

extension CommandLineToolClient: DependencyKey {
	/// The person's own home folder and the running app's helper. Automated runs get
	/// ``unavailable`` instead, so they never install anything.
	public static var liveValue: Self {
		guard !isTesting else {
			reportIssue("CommandLineToolClient.liveValue was used in a test. Supply CommandLineToolClient.files(home:…) over a temporary folder.")
			return .unavailable
		}

		guard
			AgentToolsRun.isAllowed(
				environment: ProcessInfo.processInfo.environment,
				arguments: CommandLine.arguments,
				bundlePath: Bundle.main.bundlePath
			)
		else { return .unavailable }

		let shell: String? = AgentToolsRun.loginShell()
		return .files(
			home: FileManager.default.homeDirectoryForCurrentUser,
			bundled: Bundle.main.bundleIdentifier == nil
			? nil
			: CommandLineTool.bundledHelper(in: Bundle.main.bundleURL),
			shell: shell,
			loginPath: { await AgentToolsRun.loginPath(shell: shell) },
			isArxTool: CommandLineTool.isSignedArxTool
		)
	}

	/// Tests must supply their own client, so an unexpected call fails the test.
	public static var testValue: Self {
		.init(
			status: unimplemented("CommandLineToolClient.status", placeholder: .unavailable),
			install: unimplemented("CommandLineToolClient.install"),
			uninstall: unimplemented("CommandLineToolClient.uninstall")
		)
	}

	/// Previews show the command installed but off the PATH, and change nothing.
	public static var previewValue: Self {
		.init(
			status: { .init(installation: .current, isOnPath: false) },
			install: {},
			uninstall: {}
		)
	}
}

extension DependencyValues {
	public var commandLineTool: CommandLineToolClient {
		get { self[CommandLineToolClient.self] }
		set { self[CommandLineToolClient.self] = newValue }
	}
}
