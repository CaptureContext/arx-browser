import AppKit
import BrowserCore
import Darwin
import Foundation
import UniformTypeIdentifiers

extension AppLinkClient {
	/// Scripts through ``AppLinkScriptRunner``, apps through `NSWorkspace`, copies through
	/// `NSPasteboard`.
	public static var live: Self {
		.init(
			runScript: { script in
				await AppLinkScriptRunner(logDirectory: AppLinkScriptRunner.defaultLogDirectory).run(script)
			},
			openApp: { url, application in
				guard let application else {
					guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil
					else { return .didNotOpen }
					do {
						_ = try await NSWorkspace.shared.open(url, configuration: .init())
						return .opened
					} catch {
						return .didNotOpen
					}
				}
				guard let bundle = AppLinkApplications.locate(application)
				else { return .applicationMissing }
				let moved = AppLinkApplications.refreshed(application, at: bundle)

				// The chosen copy, never another running copy of the same app (a workspace copy
				// and the installed one share a bundle ID).
				let configuration = NSWorkspace.OpenConfiguration()
				configuration.allowsRunningApplicationSubstitution = false
				do {
					_ = try await NSWorkspace.shared.open([url], withApplicationAt: bundle, configuration: configuration)
					return moved.map(AppLinkOpenOutcome.openedMoved) ?? .opened
				} catch {
					return .didNotOpen
				}
			},
			copyLink: { link in
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(link, forType: .string)
			},
			appName: { url in
				guard let application = NSWorkspace.shared.urlForApplication(toOpen: url)
				else { return nil }
				let name = FileManager.default.displayName(atPath: application.path(percentEncoded: false))
				return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
			},
			appPath: { url in
				NSWorkspace.shared.urlForApplication(toOpen: url)?.path(percentEncoded: false)
			},
			applicationsForScheme: { scheme in
				guard let sample = URL(string: scheme + "://") else { return [] }
				let urls = NSWorkspace.shared.urlsForApplications(toOpen: sample)
				let preferred = NSWorkspace.shared.urlForApplication(toOpen: sample)
				let ordered = (preferred.map { [$0] } ?? []) + urls.filter { $0 != preferred }
				return ordered.compactMap(AppLinkApplications.choice(at:))
			},
			installedApplications: {
				await Task.detached(priority: .utility) { AppLinkApplications.installed() }.value
			},
			chooseApplication: {
				let panel = NSOpenPanel()
				panel.canChooseFiles = true
				panel.canChooseDirectories = false
				panel.allowsMultipleSelection = false
				panel.treatsFilePackagesAsDirectories = false
				panel.allowedContentTypes = [.applicationBundle]
				panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
				let response = await withCheckedContinuation { continuation in
					panel.begin { continuation.resume(returning: $0) }
				}
				guard response == .OK, let url = panel.url else { return nil }
				return AppLinkApplications.choice(at: url)
			},
			bookmarked: AppLinkApplications.bookmarked
		)
	}
}

/// Reading apps from disk for App Links' picker (DEV-862).
public enum AppLinkApplications {
	/// Where installed apps are looked for, with one level of folders inside (`Utilities`,
	/// vendors' folders).
	public static var searchDirectories: [URL] {
		[
			URL(filePath: "/Applications", directoryHint: .isDirectory),
			URL(filePath: "/System/Applications", directoryHint: .isDirectory),
			URL.homeDirectory.appending(path: "Applications", directoryHint: .isDirectory),
		]
	}

	/// The app at `url`, with its name, bundle ID, schemes and a bookmark. Nil when it isn't an
	/// app bundle.
	public static func choice(at url: URL) -> AppLinkApplicationChoice? {
		guard
			url.pathExtension.lowercased() == "app",
			let bundle = Bundle(url: url)
		else { return nil }
		let path = url.standardizedFileURL.path(percentEncoded: false)
		var name = FileManager.default.displayName(atPath: path)
		if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
		let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
		return .init(
			application: .init(
				path: path,
				bundleID: bundle.bundleIdentifier,
				name: name,
				bookmark: bookmark
			),
			schemes: AppLinkApplicationChoice.schemes(fromURLTypes: bundle.object(forInfoDictionaryKey: "CFBundleURLTypes"))
		)
	}

	/// `application` as found at `url`, with that path and a fresh bookmark, when it isn't where
	/// it was saved. Nil when it is: nothing to keep.
	public static func refreshed(
		_ application: AppLinkApplication,
		at url: URL
	) -> AppLinkApplication? {
		let path = url.standardizedFileURL.path(percentEncoded: false)
		let saved = URL(filePath: application.path, directoryHint: .isDirectory).standardizedFileURL.path(percentEncoded: false)
		guard path != saved else { return nil }
		var next = application
		next.path = path
		next.bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
			?? application.bookmark
		return next
	}

	/// `application` with a bookmark made now, when it has none and is still at its path.
	public static func bookmarked(_ application: AppLinkApplication) -> AppLinkApplication {
		guard application.bookmark == nil else { return application }
		var next = application
		let url = URL(filePath: application.path, directoryHint: .isDirectory)
		next.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
		return next
	}

	/// The user's Launch Services handler preferences, where an app that registers a scheme
	/// while it runs (`LSSetDefaultHandlerForURLScheme`, as Electron apps such as Linear do)
	/// is recorded instead of in its `Info.plist`.
	public static var launchServicesPreferences: URL {
		URL.libraryDirectory
			.appending(path: "Preferences/com.apple.LaunchServices", directoryHint: .isDirectory)
			.appending(path: "com.apple.launchservices.secure.plist", directoryHint: .notDirectory)
	}

	/// The schemes registered with Launch Services while apps ran (DEV-1259), lowercased, once
	/// each, without web schemes. Empty when the preferences can't be read.
	public static func registeredSchemes(in preferences: URL = launchServicesPreferences) -> [String] {
		guard
			let values = NSDictionary(contentsOf: preferences),
			let handlers = values["LSHandlers"] as? [[String: Any]]
		else { return [] }
		var seen: Set<String> = []
		return handlers
			.compactMap { ($0["LSHandlerURLScheme"] as? String)?.lowercased() }
			.filter { AppLinkHandler.schemeProblem($0) == nil && seen.insert($0).inserted }
	}

	/// Every app macOS registers for `scheme`, asked of Launch Services.
	public static func launchServicesApplications(for scheme: String) -> [URL] {
		guard let sample = URL(string: scheme + "://") else { return [] }
		return NSWorkspace.shared.urlsForApplications(toOpen: sample)
	}

	/// Installed apps that register at least one scheme a handler may take, by name: the
	/// schemes their `Info.plist` declares (`CFBundleURLTypes`), and those Launch Services
	/// registers for them (DEV-1259). An app that registers its scheme only while it runs, as
	/// Linear does, declares none, and is found by asking Launch Services which apps open each
	/// of `registeredSchemes`, wherever they are.
	public static func installed(
		in directories: [URL] = searchDirectories,
		registeredSchemes: [String] = registeredSchemes(),
		applicationsForScheme: (String) -> [URL] = launchServicesApplications(for:)
	) -> [AppLinkApplicationChoice] {
		let files = FileManager.default
		var apps: [URL] = []
		for directory in directories {
			let entries = (try? files.contentsOfDirectory(
				at: directory,
				includingPropertiesForKeys: [.isDirectoryKey],
				options: [.skipsHiddenFiles]
			)) ?? []
			for entry in entries {
				if entry.pathExtension.lowercased() == "app" {
					apps.append(entry)
				} else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
					let inner = (try? files.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
					apps.append(contentsOf: inner.filter { $0.pathExtension.lowercased() == "app" })
				}
			}
		}

		// Each app's schemes by its path: its own declarations first, then what Launch Services
		// registers for it.
		var schemes: [String: [String]] = [:]
		var urls: [String: URL] = [:]
		var order: [String] = []
		func add(_ url: URL, _ found: [String]) {
			let path = url.standardizedFileURL.path(percentEncoded: false)
			if urls[path] == nil {
				urls[path] = url
				order.append(path)
			}
			let known = schemes[path] ?? []
			schemes[path] = known + found.filter { !known.contains($0) }
		}
		for url in apps {
			guard let bundle = Bundle(url: url) else { continue }
			add(url, AppLinkApplicationChoice.schemes(fromURLTypes: bundle.object(forInfoDictionaryKey: "CFBundleURLTypes")))
		}
		for scheme in registeredSchemes where AppLinkHandler.schemeProblem(scheme) == nil {
			for url in applicationsForScheme(scheme) where url.pathExtension.lowercased() == "app" {
				add(url, [scheme])
			}
		}

		return order
			.compactMap { path -> AppLinkApplicationChoice? in

				// Bookmarks are made when an app is picked, not for every installed one.
				guard
					let url = urls[path],
					let found = schemes[path],
					!found.isEmpty,
					let bundle = Bundle(url: url)
				else { return nil }
				var name = FileManager.default.displayName(atPath: path)
				if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
				return .init(
					application: .init(path: path, bundleID: bundle.bundleIdentifier, name: name),
					schemes: found
				)
			}
			.sorted { $0.application.name.localizedStandardCompare($1.application.name) == .orderedAscending }
	}

	/// Where the chosen app is now: where its bookmark leads, or for an app without one, its
	/// path. Nil when that isn't an app bundle with the same bundle ID, so another app is never
	/// opened in its place. Bookmarks resolve by path first, then follow a move or rename: an
	/// app with the same bundle ID back at the chosen path counts as the chosen one, which is
	/// what keeps it found after an update replaces its bundle (and its file ID) in place.
	public static func locate(_ application: AppLinkApplication) -> URL? {
		guard let bookmark = application.bookmark else {
			let atPath = URL(filePath: application.path, directoryHint: .isDirectory)
			return isApp(atPath, bundleID: application.bundleID) ? atPath : nil
		}
		var isStale = false
		guard
			let moved = try? URL(
				resolvingBookmarkData: bookmark,
				options: [.withoutUI, .withoutMounting],
				relativeTo: nil,
				bookmarkDataIsStale: &isStale
			),
			isApp(moved, bundleID: application.bundleID)
		else { return nil }
		return moved
	}

	private static func isApp(
		_ url: URL,
		bundleID: String?
	) -> Bool {
		var isDirectory: ObjCBool = false
		guard
			url.pathExtension.lowercased() == "app",
			FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
			isDirectory.boolValue
		else { return false }
		guard let bundleID else { return true }

		// Read fresh: `Bundle` caches by path, and another app may have taken this one's place.
		let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory))
		return info?["CFBundleIdentifier"] as? String == bundleID
	}
}

/// Runs a handler's script as `/bin/zsh -c <script> arx-link <link>`.
///
/// The link reaches the script only as an argument and in `ARX_LINK`, so a page can't add
/// commands unless the script itself `eval`s it. Standard output and error go to one log file
/// per run; no other descriptor of Arx's reaches the script. The script leads its own process
/// group: a run past its timeout gets SIGTERM, then SIGKILL two seconds later, sent to the
/// whole group, so commands it started in the background stop with it.
public struct AppLinkScriptRunner: Sendable {
	/// `~/Library/Logs/Arx/App Links`.
	public static var defaultLogDirectory: URL {
		URL.libraryDirectory
			.appending(path: "Logs", directoryHint: .isDirectory)
			.appending(path: "Arx", directoryHint: .isDirectory)
			.appending(path: "App Links", directoryHint: .isDirectory)
	}

	public let logDirectory: URL
	public let shell: URL

	public init(
		logDirectory: URL,
		shell: URL = URL(filePath: "/bin/zsh")
	) {
		self.logDirectory = logDirectory
		self.shell = shell
	}

	public func run(_ script: AppLinkScript) async -> AppLinkScriptOutcome {
		let log: URL
		let handle: FileHandle
		do {
			try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
			log = logDirectory.appending(path: Self.logName(scheme: script.scheme), directoryHint: .notDirectory)
			guard FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
			else { return .unavailable("Couldn't create the log") }
			handle = try FileHandle(forWritingTo: log)
		} catch {
			return .unavailable(error.localizedDescription)
		}
		defer { try? handle.close() }

		let environment = ProcessInfo.processInfo.environment.merging(script.environment) { _, new in new }
		let pid: pid_t
		let spawned = Self.spawn(
			shell.path(percentEncoded: false),
			arguments: script.arguments,
			environment: environment.map { $0.key + "=" + $0.value },
			output: handle.fileDescriptor,
			directory: URL.homeDirectory.path(percentEncoded: false)
		)
		guard spawned.code == 0
		else { return .unavailable(String(cString: strerror(spawned.code))) }
		pid = spawned.pid

		let exit = ProcessExit(pid: pid)
		let timeout = script.timeout
		let status: Int32? = await withTaskGroup(of: Int32?.self) { group in
			group.addTask { await exit.status() }
			group.addTask {
				try? await Task.sleep(for: timeout)
				return nil
			}
			let first = await group.next() ?? nil
			group.cancelAll()
			return first
		}

		guard let status else {
			// Still running: stop the script's whole group, then make sure.
			kill(-pid, SIGTERM)
			for _ in 0 ..< 40 where !exit.hasExited {
				try? await Task.sleep(for: .milliseconds(50))
			}
			kill(-pid, SIGKILL)
			return .timedOut(log: log)
		}
		guard status == 0 else {
			return .failed(status: status, message: Self.tail(of: log), log: log)
		}
		return .succeeded(log: log)
	}

	/// `posix_spawn` with the script as a new process group's leader, standard input from
	/// `/dev/null`, output and errors to the log, every other descriptor closed, and default
	/// signal handling.
	private static func spawn(
		_ path: String,
		arguments: [String],
		environment: [String],
		output: Int32,
		directory: String
	) -> (pid: pid_t, code: Int32) {
		var attributes: posix_spawnattr_t?
		posix_spawnattr_init(&attributes)
		defer { posix_spawnattr_destroy(&attributes) }

		// Signals Arx ignores or blocks (SIGPIPE, say) start at their defaults in the script.
		posix_spawnattr_setflags(&attributes, Int16(
			POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
		))
		posix_spawnattr_setpgroup(&attributes, 0)
		var all = sigset_t()
		sigfillset(&all)
		posix_spawnattr_setsigdefault(&attributes, &all)
		var none = sigset_t()
		sigemptyset(&none)
		posix_spawnattr_setsigmask(&attributes, &none)

		var actions: posix_spawn_file_actions_t?
		posix_spawn_file_actions_init(&actions)
		defer { posix_spawn_file_actions_destroy(&actions) }
		posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
		posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
		posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO)
		posix_spawn_file_actions_addchdir(&actions, directory)

		let argv = ([path] + arguments).map { strdup($0) } + [nil]
		let envp = environment.map { strdup($0) } + [nil]
		defer {
			argv.forEach { free($0) }
			envp.forEach { free($0) }
		}
		var pid: pid_t = 0
		let code = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
		return (pid, code)
	}

	/// `2026-11-12T13-40-05Z-claude-<id>.log`: sortable and never reused.
	internal static func logName(scheme: String) -> String {
		let time = Date.now.formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
		let safe = scheme.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "+" }
		return "\(time)-\(safe)-\(UUID().uuidString.prefix(8)).log"
	}

	/// The last lines of the log, at most 500 characters, for the prompt's error.
	internal static func tail(of log: URL) -> String {
		// Only the end: a script's output has no size limit.
		guard let handle = try? FileHandle(forReadingFrom: log) else { return "" }
		defer { try? handle.close() }
		guard
			let size = try? handle.seekToEnd(),
			(try? handle.seek(toOffset: size > 2_048 ? size - 2_048 : 0)) != nil,
			let data = try? handle.readToEnd()
		else { return "" }
		let text = String(decoding: data, as: UTF8.self)
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return String(text.suffix(500))
	}
}

/// Reaps one spawned script on a thread of its own, so waiting never holds a task thread.
private final class ProcessExit: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var exitStatus: Int32?
	private var waiters: [UUID: CheckedContinuation<Int32?, Never>] = [:]

	internal init(pid: pid_t) {
		let thread = Thread { [self] in
			var raw: Int32 = 0
			while waitpid(pid, &raw, 0) == -1, errno == EINTR {}

			// A normal exit's code, or 128 plus the signal, as shells report it.
			let status = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
			lock.lock()
			exitStatus = status
			let waiting = waiters.values
			waiters = [:]
			lock.unlock()
			waiting.forEach { $0.resume(returning: status) }
		}
		thread.name = "Arx App Link script"
		thread.start()
	}

	internal var hasExited: Bool {
		lock.lock()
		defer { lock.unlock() }
		return exitStatus != nil
	}

	/// The exit status, or nil when the waiting task is cancelled first.
	internal func status() async -> Int32? {
		let id = UUID()
		return await withTaskCancellationHandler {
			await withCheckedContinuation { continuation in
				lock.lock()
				if let exitStatus {
					lock.unlock()
					continuation.resume(returning: exitStatus)
				} else if Task.isCancelled {
					lock.unlock()
					continuation.resume(returning: nil)
				} else {
					waiters[id] = continuation
					lock.unlock()
				}
			}
		} onCancel: {
			lock.lock()
			let waiter = waiters.removeValue(forKey: id)
			lock.unlock()
			waiter?.resume(returning: nil)
		}
	}
}
