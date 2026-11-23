import AppLinkClient
import Foundation
import Testing

internal struct AppLinkScriptRunnerTests {
	private let directory: URL = FileManager.default.temporaryDirectory
		.appending(path: "arx-app-link-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

	private var runner: AppLinkScriptRunner { .init(logDirectory: directory.appending(path: "logs")) }

	private func script(
		_ text: String,
		link: String = "claude://login/callback?code=1",
		timeout: Duration = .seconds(10)
	) -> AppLinkScript {
		.init(
			script: text,
			link: link,
			scheme: "claude",
			profileID: "11111111-1111-1111-1111-111111111111",
			profileName: "Work",
			sourceOrigin: "https://claude.ai",
			timeout: timeout
		)
	}

	@Test
	internal func linkReachesScriptAsOneUnchangedArgument() async throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let recorded = directory.appending(path: "argument")
		let link = #"claude://x?a=1;touch /tmp/arx-pwned&b=$(id -u)&c='q'&d="dq"&e=`echo hi` f"#

		let outcome = await runner.run(script(
			#"printf '%s' "$#" > "$RECORD.count"; printf '%s' "$1" > "$RECORD"; printf '%s' "$ARX_LINK" > "$RECORD.env""#
				.replacingOccurrences(of: "$RECORD", with: recorded.path(percentEncoded: false)),
			link: link
		))

		#expect(outcome.succeeded)
		#expect(try String(contentsOf: recorded, encoding: .utf8) == link)
		#expect(try String(contentsOf: recorded.appendingPathExtension("env"), encoding: .utf8) == link)
		#expect(try String(contentsOf: recorded.appendingPathExtension("count"), encoding: .utf8) == "1")
		#expect(!FileManager.default.fileExists(atPath: "/tmp/arx-pwned"))
	}

	@Test
	internal func scriptGetsContextAndLogsOutput() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let outcome = await runner.run(script(
			#"echo "$0|$ARX_LINK_SCHEME|$ARX_PROFILE_ID|$ARX_PROFILE_NAME|$ARX_SOURCE_ORIGIN"; echo oops >&2"#
		))

		let log = try #require(outcome.log)
		#expect(outcome.succeeded)
		#expect(log.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
			.hasSuffix(directory.lastPathComponent + "/logs/"))
		let text = try String(contentsOf: log, encoding: .utf8)
		#expect(text.contains("arx-link|claude|11111111-1111-1111-1111-111111111111|Work|https://claude.ai"))
		#expect(text.contains("oops"))
	}

	@Test
	internal func nonZeroExitReportsItsError() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let outcome = await runner.run(script(#"echo "no workspace for $1" >&2; exit 3"#))

		guard case let .failed(status, message, log) = outcome else {
			Issue.record("Expected a failure, got \(outcome)")
			return
		}
		#expect(status == 3)
		#expect(message == "no workspace for claude://login/callback?code=1")
		#expect(log != nil)
	}

	@Test
	internal func failureReportsOnlyTheEndOfALargeLog() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let outcome = await runner.run(script(#"head -c 3000000 /dev/zero | tr '\0' x; echo; echo "the end" >&2; exit 4"#))
		guard case let .failed(status, message, _) = outcome else {
			Issue.record("Expected a failure, got \(outcome)")
			return
		}
		#expect(status == 4)
		#expect(message.hasSuffix("the end"))
		#expect(message.count <= 500)
	}

	@Test
	internal func scriptPastItsTimeoutIsStopped() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let clock = ContinuousClock()
		let start = clock.now
		let outcome = await runner.run(script("sleep 20", timeout: .milliseconds(300)))

		guard case .timedOut = outcome else {
			Issue.record("Expected a timeout, got \(outcome)")
			return
		}
		#expect(clock.now - start < .seconds(10))
	}

	@Test
	internal func timeoutStopsWhatTheScriptStartedInTheBackground() async throws {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }
		let marker = directory.appending(path: "survived").path(percentEncoded: false)
		let outcome = await runner.run(script(
			"trap '' TERM; (trap '' TERM; sleep 3; echo survived > '\(marker)') & wait",
			timeout: .milliseconds(300)
		))

		guard case .timedOut = outcome else {
			Issue.record("Expected a timeout, got \(outcome)")
			return
		}
		try await Task.sleep(for: .seconds(4))
		#expect(!FileManager.default.fileExists(atPath: marker))
	}

	@Test
	internal func scriptGetsNoInputAndRunsInTheHomeFolder() async throws {
		defer { try? FileManager.default.removeItem(at: directory) }
		let outcome = await runner.run(script(#"pwd; cat; echo "read:$?""#))
		let text = try String(contentsOf: try #require(outcome.log), encoding: .utf8)
		var home = URL.homeDirectory.path(percentEncoded: false)
		if home.hasSuffix("/") { home.removeLast() }
		#expect(text.hasPrefix(home + "\n"))
		#expect(text.contains("read:0"))
	}

	@Test
	internal func missingShellIsUnavailable() async {
		defer { try? FileManager.default.removeItem(at: directory) }
		let runner = AppLinkScriptRunner(
			logDirectory: directory.appending(path: "logs"),
			shell: URL(filePath: "/nonexistent/zsh")
		)
		guard case .unavailable = await runner.run(script("true")) else {
			Issue.record("Expected unavailable")
			return
		}
	}

	@Test
	internal func argumentsNeverSpliceTheLink() {
		let run = script("fxclaude open-url work \"$1\"", link: "claude://a;b")
		#expect(run.arguments == ["-c", "fxclaude open-url work \"$1\"", "arx-link", "claude://a;b"])
		#expect(run.environment["ARX_LINK"] == "claude://a;b")
	}
}
