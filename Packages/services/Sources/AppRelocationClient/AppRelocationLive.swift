import AppKit
import Darwin
import Foundation

extension AppRelocationClient {
	/// The operating-system implementation. It runs before `NSApplication` exists, so prompts use
	/// `CFUserNotification` instead of `NSAlert`, and the administrator prompt is macOS's own.
	public static var live: Self { .live(texts: .untranslated) }

	/// The operating-system implementation with the prompts' text in the interface's language,
	/// which the app passes in from its catalog (DEV-1291).
	public static func live(texts: Texts) -> Self {
		.init(
			bundleURL: { Bundle.main.bundleURL },
			originalURL: { url in Live.originalURL(of: url) },
			diskImageVolume: { url in Live.diskImageVolume(containing: url) },
			userApplicationsDirectory: {
				URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory)
			},
			isWritable: { url in FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false)) },
			fileExists: { url in FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) },
			activateRunningCopy: { url in Live.activateRunningCopy(at: url) },
			isPromptSuppressed: { UserDefaults.standard.bool(forKey: Live.suppressPromptKey) },
			suppressPrompt: { UserDefaults.standard.set(true, forKey: Live.suppressPromptKey) },
			prompt: { Live.prompt(texts) },
			install: { installation in try Live.install(installation) },
			relaunch: { destination, volume in try Live.relaunch(destination, ejecting: volume) },
			trashOriginal: { url in try? FileManager.default.trashItem(at: url, resultingItemURL: nil) },
			reportFailure: { error in Live.reportFailure(error, texts: texts) }
		)
	}
}

private enum Live {
	internal static let suppressPromptKey: String = "AppRelocation.suppressPrompt"

	// MARK: - Location

	/// `SecTranslocateCreateOriginalPathForURL` has no public header, so it's looked up at runtime.
	internal static func originalURL(of url: URL) -> URL? {
		typealias Function = @convention(c) (
			CFURL,
			UnsafeMutablePointer<Unmanaged<CFError>?>?
		) -> Unmanaged<CFURL>?

		guard
			let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
			let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL")
		else { return nil }

		let function: Function = unsafeBitCast(symbol, to: Function.self)
		return function(url as CFURL, nil)?.takeRetainedValue() as URL?
	}

	/// Disk images mount under `/Volumes`; `hdiutil info` says which mount points are images.
	internal static func diskImageVolume(containing url: URL) -> URL? {
		let components: [String] = url.standardizedFileURL.pathComponents
		guard components.count > 2, components[1] == "Volumes"
		else { return nil }

		let volume: String = "/Volumes/" + components[2]
		guard
			let output = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
			let information = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
			let images = information["images"] as? [[String: Any]]
		else { return nil }

		let mountPoints: [String] = images
			.flatMap { $0["system-entities"] as? [[String: Any]] ?? [] }
			.compactMap { $0["mount-point"] as? String }
		guard mountPoints.contains(volume)
		else { return nil }

		return URL(filePath: volume, directoryHint: .isDirectory)
	}

	internal static func activateRunningCopy(at url: URL) -> Bool {
		guard let identifier = Bundle.main.bundleIdentifier
		else { return false }

		let target: URL = url.resolvingSymlinksInPath().standardizedFileURL
		let ownProcess: pid_t = ProcessInfo.processInfo.processIdentifier
		let copy: NSRunningApplication? = NSRunningApplication
			.runningApplications(withBundleIdentifier: identifier)
			.first { application in
				application.processIdentifier != ownProcess
					&& application.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == target
			}
		guard let copy
		else { return false }

		return copy.activate()
	}

	// MARK: - Prompts

	internal static func prompt(_ texts: AppRelocationClient.Texts) -> AppRelocationClient.PromptAnswer {
		let response: Alert.Response? = Alert.show(
			title: texts.promptTitle,
			message: texts.promptMessage,
			defaultButton: texts.move,
			alternateButton: texts.notNow,
			checkbox: texts.dontAskAgain
		)
		switch response {
		case .default: return .move
		case .alternate(checked: true): return .neverAsk
		case .alternate(checked: false), .none: return .notNow
		}
	}

	internal static func reportFailure(
		_ error: Error,
		texts: AppRelocationClient.Texts
	) {
		_ = Alert.show(
			title: texts.failureTitle,
			message: [
				error.localizedDescription,
				texts.failureMessage,
			].joined(separator: "\n\n"),
			defaultButton: texts.ok,
			alternateButton: nil,
			checkbox: nil
		)
	}

	// MARK: - Installation

	internal static func install(_ installation: AppRelocationClient.Installation) throws {
		let source: String = installation.source.path(percentEncoded: false)
		let destination: String = installation.destination.path(percentEncoded: false)
		let trash: String = trashDestination(for: installation.destination).path(percentEncoded: false)

		guard installation.privileged else {
			let manager: FileManager = .default
			do {
				try manager.createDirectory(
					at: installation.destination.deletingLastPathComponent(),
					withIntermediateDirectories: true
				)
				if manager.fileExists(atPath: destination) {
					try manager.trashItem(at: installation.destination, resultingItemURL: nil)
				}

				// ditto keeps the code signature, stapled ticket and framework symlinks intact.
				try run("/usr/bin/ditto", [source, destination])
				try clearQuarantine(destination)
			} catch {
				throw AppRelocationClient.Failure.copyFailed(error.localizedDescription)
			}
			return
		}

		// The old copy goes to the person's Trash, never deleted, like Finder would.
		let script: String = [
			"set -e",
			"if [ -e \(quoted(destination)) ]; then /bin/mv \(quoted(destination)) \(quoted(trash)); fi",
			"/usr/bin/ditto \(quoted(source)) \(quoted(destination))",
			"/usr/bin/xattr -dr com.apple.quarantine \(quoted(destination)) || true",
		].joined(separator: "\n")
		let appleScript: String = "do shell script \(appleScriptString(script)) with administrator privileges"
		var error: NSDictionary?
		_ = NSAppleScript(source: appleScript)?.executeAndReturnError(&error)
		guard let error
		else { return }

		if error[NSAppleScript.errorNumber] as? Int == userCancelledError {
			throw AppRelocationClient.Failure.authorizationDeclined
		}
		let message: String = error[NSAppleScript.errorMessage] as? String ?? ""
		throw AppRelocationClient.Failure.copyFailed(message)
	}

	/// Without this the copy would be translocated again on its first launch from Applications.
	/// The app already passed Gatekeeper when it opened from the disk image.
	private static func clearQuarantine(_ path: String) throws {
		try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", path])
	}

	private static func trashDestination(for url: URL) -> URL {
		let name: String = url.deletingPathExtension().lastPathComponent
		let stamp: Int = Int(Date().timeIntervalSince1970)
		return URL.homeDirectory
			.appending(path: ".Trash", directoryHint: .isDirectory)
			.appending(path: "\(name) \(stamp).app", directoryHint: .isDirectory)
	}

	// MARK: - Relaunch

	/// A detached shell waits for this process to exit, ejects the disk image, then opens the copy.
	internal static func relaunch(
		_ destination: URL,
		ejecting volume: URL?
	) throws {
		let script: String = """
		while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
		if [ -n "$2" ]; then
			/usr/bin/hdiutil detach "$2" -quiet || /usr/bin/hdiutil detach "$2" -quiet -force
		fi
		/usr/bin/open "$3"
		"""
		let process: Process = .init()
		process.executableURL = URL(filePath: "/bin/sh")
		process.arguments = [
			"-c", script, "sh",
			String(ProcessInfo.processInfo.processIdentifier),
			volume?.path(percentEncoded: false) ?? "",
			destination.path(percentEncoded: false),
		]
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = FileHandle.nullDevice
		process.standardError = FileHandle.nullDevice
		do {
			try process.run()
		} catch {
			throw AppRelocationClient.Failure.relaunchFailed(error.localizedDescription)
		}
	}

	// MARK: - Helpers

	private static let userCancelledError: Int = -128

	@discardableResult
	private static func run(
		_ executable: String,
		_ arguments: [String]
	) throws -> Data {
		let process: Process = .init()
		let output: Pipe = .init()
		process.executableURL = URL(filePath: executable)
		process.arguments = arguments
		process.standardOutput = output
		process.standardError = FileHandle.nullDevice
		try process.run()
		let data: Data = output.fileHandleForReading.readDataToEndOfFile()
		process.waitUntilExit()
		guard process.terminationStatus == 0 else {
			throw CocoaError(
				.fileWriteUnknown,
				userInfo: [NSLocalizedDescriptionKey: "\(executable) exited with status \(process.terminationStatus)."]
			)
		}
		return data
	}

	private static func quoted(_ value: String) -> String {
		"'" + value.replacing("'", with: "'\\''") + "'"
	}

	private static func appleScriptString(_ value: String) -> String {
		"\"" + value.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\""
	}
}

// MARK: - Alert

/// A modal alert that works before `NSApplication` exists, as Chromium's
/// `BrowserCrApplication` must be the first application instance.
private enum Alert {
	internal enum Response: Equatable {
		case `default`
		case alternate(checked: Bool)
	}

	internal static func show(
		title: String,
		message: String,
		defaultButton: String,
		alternateButton: String?,
		checkbox: String?
	) -> Response? {
		var dictionary: [CFString: Any] = [
			kCFUserNotificationAlertHeaderKey: title,
			kCFUserNotificationAlertMessageKey: message,
			kCFUserNotificationDefaultButtonTitleKey: defaultButton,
		]
		if let alternateButton {
			dictionary[kCFUserNotificationAlternateButtonTitleKey] = alternateButton
		}
		if let checkbox {
			dictionary[kCFUserNotificationCheckBoxTitlesKey] = [checkbox]
		}
		if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
			dictionary[kCFUserNotificationIconURLKey] = icon
		}

		var error: Int32 = 0
		guard let notification = CFUserNotificationCreate(
			kCFAllocatorDefault,
			0,
			kCFUserNotificationNoteAlertLevel,
			&error,
			dictionary as CFDictionary
		) else { return nil }

		var flags: CFOptionFlags = 0
		CFUserNotificationReceiveResponse(notification, 0, &flags)
		let checked: Bool = flags & CFOptionFlags(1 << 8) != 0
		switch flags & 0x3 {
		case CFOptionFlags(kCFUserNotificationDefaultResponse): return .default
		case CFOptionFlags(kCFUserNotificationAlternateResponse): return .alternate(checked: checked)
		default: return nil
		}
	}
}
