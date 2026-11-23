import AppKit
import Darwin
import Foundation

/// A separate process exercises LaunchServices rather than invoking Arx's binary or reducer.
@main
private enum RoutingLauncher {
	private struct Configuration: Decodable {
		let application: URL
		let urls: [URL]
	}

	private enum Failure: Error {
		case invalidFixture, incorrectApplication, existingApplication, timedOut
	}

	@MainActor
	static func main() async {
		var owned: NSRunningApplication?
		do {
			if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--preflight" {
				let build = URL(fileURLWithPath: CommandLine.arguments[2])
				guard !NSWorkspace.shared.runningApplications.contains(where: {
					$0.bundleURL.map { isInside($0, directory: build) } == true
				}) else { throw Failure.existingApplication }
				return
			}
			guard CommandLine.arguments.count == 2 else { throw Failure.invalidFixture }
			let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
			guard
				root.resolvingSymlinksInPath() == root,
				root.lastPathComponent.hasPrefix("routing-smoke-"),
				try Data(contentsOf: root.appendingPathComponent(".arx-routing-smoke"))
					== Data("Arx external routing fixture v1\n".utf8)
			else { throw Failure.invalidFixture }
			let fixture = try JSONDecoder().decode(
				Configuration.self,
				from: Data(contentsOf: root.appendingPathComponent("fixture.json"))
			)
			let application = fixture.application.resolvingSymlinksInPath()
			guard
				application.isFileURL,
				application.pathExtension == "app",
				// Arx Dev (Debug, DEV-1013) or the installed Arx (Release).
				["dev.capturecontext.arx.dev", "dev.capturecontext.arx"].contains(Bundle(url: application)?.bundleIdentifier),
				fixture.urls.count == 4,
				fixture.urls.allSatisfy({ $0.scheme == "http" && $0.host == "127.0.0.1" })
			else { throw Failure.invalidFixture }

			let running = NSWorkspace.shared.runningApplications
			guard !running.contains(where: { $0.bundleURL.map { sameFile($0, application) } == true })
			else { throw Failure.existingApplication }
			let existing = Set(running.map(\.processIdentifier))
			let configuration = NSWorkspace.OpenConfiguration()
			configuration.createsNewApplicationInstance = true
			configuration.allowsRunningApplicationSubstitution = false
			configuration.addsToRecentItems = false
			configuration.promptsUserIfNeeded = false
			configuration.arguments = ["--arx-routing-smoke-root", root.path]
			let inherited = ProcessInfo.processInfo.environment.filter { key, _ in
				["PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL"].contains(key)
			}

			// The smoke reads the workspace back from its JSON file, so it keeps the SQLite workspace
			// off, which is on by default (DEV-1143).
			configuration.environment = inherited.merging([
				"ARX_ROUTING_SMOKE_ROOT": root.path,
				"ARX_ENGINE_PROFILE": root.appendingPathComponent("profile").path,
				"ARX_SQLITE_WORKSPACE": "0",
			]) { _, value in value }

			let launched = try await NSWorkspace.shared.open(
				fixture.urls,
				withApplicationAt: application,
				configuration: configuration
			)
			guard
				!existing.contains(launched.processIdentifier),
				let launchedBundle = launched.bundleURL,
				let launchedExecutable = launched.executableURL,
				sameFile(launchedBundle, application),
				sameFile(launchedExecutable, application.appendingPathComponent("Contents/MacOS/Arx")),
				launched.launchDate != nil
			else { throw Failure.incorrectApplication }
			owned = launched
			let identity: [String: Any] = ["pid": launched.processIdentifier, "application": application.path]
			try JSONSerialization.data(withJSONObject: identity).write(
				to: root.appendingPathComponent("launch.json"),
				options: [.atomic]
			)

			let clock = ContinuousClock()
			let deadline = clock.now.advanced(by: .seconds(75))
			while !launched.isTerminated {
				guard clock.now < deadline else { throw Failure.timedOut }
				try await Task.sleep(for: .milliseconds(100))
			}
			print("ARX_ROUTING_LAUNCHER_EXIT_SUCCESS")
		} catch {
			if let owned { await terminate(owned) }
			FileHandle.standardError.write(Data("Routing launcher failed: \(error)\n".utf8))
			exit(1)
		}
	}

	private static func sameFile(_ first: URL, _ second: URL) -> Bool {
		var firstInfo = stat()
		var secondInfo = stat()
		return stat(first.path, &firstInfo) == 0
		&& stat(second.path, &secondInfo) == 0
		&& firstInfo.st_dev == secondInfo.st_dev
		&& firstInfo.st_ino == secondInfo.st_ino
	}

	private static func isInside(_ application: URL, directory: URL) -> Bool {
		var ancestor = application.resolvingSymlinksInPath()
		while ancestor.path != "/" {
			if sameFile(ancestor, directory) { return true }
			ancestor.deleteLastPathComponent()
		}
		return false
	}

	@MainActor
	private static func terminate(_ owned: NSRunningApplication) async {
		guard
			!owned.isTerminated,
			let current = NSRunningApplication(processIdentifier: owned.processIdentifier),
			current.launchDate == owned.launchDate,
			let currentBundle = current.bundleURL,
			let ownedBundle = owned.bundleURL,
			sameFile(currentBundle, ownedBundle)
		else { return }
		_ = owned.terminate()
		for _ in 0..<30 {
			if owned.isTerminated { return }
			do { try await Task.sleep(for: .milliseconds(100)) }
			catch { break }
		}
		guard
			!owned.isTerminated,
			let remaining = NSRunningApplication(processIdentifier: owned.processIdentifier),
			remaining.launchDate == owned.launchDate,
			let remainingBundle = remaining.bundleURL,
			let ownedBundle = owned.bundleURL,
			sameFile(remainingBundle, ownedBundle)
		else { return }
		_ = owned.forceTerminate()
	}
}
