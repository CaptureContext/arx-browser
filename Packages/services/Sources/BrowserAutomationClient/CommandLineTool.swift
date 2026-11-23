import Darwin
import Foundation
import Security

/// The `arx` command a person runs from a terminal: a copy of the app's bundled helper
/// at `~/.local/bin/arx`, which needs no password to write.
///
/// The app's Install and the command's own `arx setup command` both use these, so they
/// agree on what counts as Arx's copy and never replace a file that isn't one.
public enum CommandLineTool {
	/// The installed command, relative to the home folder.
	public static let relativePath: String = ".local/bin/arx"

	/// The helper's file name inside `Arx.app/Contents/Helpers`.
	public static let helperName: String = "ArxMCP"

	/// What is at the install location now.
	public enum State: Equatable, Sendable {
		/// Nothing is there.
		case notInstalled

		/// Arx's copy, the same as the app's bundled one.
		case current

		/// Arx's copy from another build, or a link left by an older `arx setup command`.
		case outdated

		/// A file that isn't Arx's. Install and Uninstall leave it alone.
		case foreign
	}

	public enum Failure: Error, Equatable, Sendable {
		/// The install location holds a file that isn't Arx's.
		case occupied

		/// The app has no bundled helper to copy.
		case missingHelper
	}

	public static func url(home: URL) -> URL {
		home.appending(path: relativePath)
	}

	/// The bundled helper inside an app bundle.
	public static func bundledHelper(in application: URL) -> URL {
		application.appending(path: "Contents/Helpers/" + helperName)
	}

	/// Compares the installed file with the bundled helper.
	///
	/// - Parameters:
	///   - isArxTool: Whether a regular file is Arx's helper, read from its code signature in the app.
	public static func state(
		installed: URL,
		bundled: URL,
		isArxTool: (URL) -> Bool
	) -> State {
		let manager: FileManager = .default
		if let destination = try? manager.destinationOfSymbolicLink(atPath: installed.path) {
			return URL(fileURLWithPath: destination).lastPathComponent == helperName ? .outdated : .foreign
		}

		guard manager.fileExists(atPath: installed.path)
		else { return .notInstalled }

		guard isArxTool(installed)
		else { return .foreign }

		return manager.contentsEqual(atPath: installed.path, andPath: bundled.path) ? .current : .outdated
	}

	/// Copies the bundled helper to the install location, replacing only Arx's own copy or link.
	///
	/// The copy is written next to the destination and renamed over it, so a failed copy
	/// never leaves a half-written command behind.
	public static func install(
		from bundled: URL,
		to installed: URL,
		isArxTool: (URL) -> Bool
	) throws {
		try RealHomeGuard.check(installed)
		let manager: FileManager = .default
		guard manager.isExecutableFile(atPath: bundled.path)
		else { throw Failure.missingHelper }

		guard state(installed: installed, bundled: bundled, isArxTool: isArxTool) != .foreign
		else { throw Failure.occupied }

		let folder: URL = installed.deletingLastPathComponent()
		try manager.createDirectory(at: folder, withIntermediateDirectories: true)

		let temporary: URL = folder.appending(path: ".arx-" + UUID().uuidString)
		do {
			try manager.copyItem(at: bundled, to: temporary)
			try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
			guard rename(temporary.path, installed.path) == 0
			else { throw CocoaError(.fileWriteUnknown) }
		} catch {
			try? manager.removeItem(at: temporary)
			throw error
		}
	}

	/// Removes Arx's copy or link; anything else at the location is left alone.
	public static func uninstall(
		_ installed: URL,
		bundled: URL,
		isArxTool: (URL) -> Bool
	) throws {
		try RealHomeGuard.check(installed)
		switch state(installed: installed, bundled: bundled, isArxTool: isArxTool) {
		case .notInstalled:
			return

		case .foreign:
			throw Failure.occupied

		case .current, .outdated:
			try FileManager.default.removeItem(at: installed)
		}
	}

	/// Whether `folder` is one of the entries of a `PATH` value.
	public static func isOnPath(
		_ folder: URL,
		path: String,
		home: URL
	) -> Bool {
		let target: String = folder.standardizedFileURL.path
		return path.split(separator: ":").contains { entry in
			let expanded: String = entry.hasPrefix("~/")
			? home.path + entry.dropFirst(1)
			: String(entry)
			return URL(fileURLWithPath: expanded).standardizedFileURL.path == target
		}
	}

	/// Whether `url` is signed as Arx's helper. Signed and ad-hoc builds both carry the identifier.
	public static func isSignedArxTool(_ url: URL) -> Bool {
		var code: SecStaticCode?
		guard
			SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
			let code
		else { return false }

		var information: CFDictionary?
		guard
			SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
			let information = information as? [String: Any]
		else { return false }

		return information[kSecCodeInfoIdentifier as String] as? String == helperName
	}
}

// MARK: - Shell profile

extension CommandLineTool {
	/// The line that puts `~/.local/bin` on the PATH, and the file it belongs in.
	public struct PathAdvice: Equatable, Sendable {
		/// The shell profile, written with `~` for the home folder.
		public var profile: String

		/// The line to add to it.
		public var line: String

		public init(
			profile: String,
			line: String
		) {
			self.profile = profile
			self.line = line
		}
	}

	/// What to add for the login shell at `shell`, such as `/bin/zsh`.
	public static func pathAdvice(shell: String?) -> PathAdvice {
		let export: String = #"export PATH="$HOME/.local/bin:$PATH""#
		switch shell.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
		case "zsh":
			return .init(profile: "~/.zshrc", line: export)

		case "bash":
			return .init(profile: "~/.bash_profile", line: export)

		case "fish":
			return .init(profile: "~/.config/fish/config.fish", line: "fish_add_path $HOME/.local/bin")

		default:
			return .init(profile: "~/.profile", line: export)
		}
	}
}
