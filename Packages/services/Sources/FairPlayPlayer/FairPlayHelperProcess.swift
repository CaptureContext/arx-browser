import AppKit
import FairPlayProtocol
import Foundation

/// The helper process's run loop (DEV-1144): commands arrive as JSON lines on standard input,
/// events leave as JSON lines on standard output. The helper exits when its input closes, which
/// is how the app ends it, and on a line too long to be the app's.
public enum FairPlayHelperProcess {
	/// Unattended runs (the smokes) keep the Mac's media keys and stay silent.
	public static let systemControlsVariable: String = "ARX_FAIRPLAY_SYSTEM_CONTROLS"
	public static let silentVariable: String = "ARX_FAIRPLAY_SILENT"

	@MainActor
	public static func run(environment: [String: String] = ProcessInfo.processInfo.environment) -> Never {
		// An accessory app: Now Playing names it, the Dock never shows it.
		NSApplication.shared.setActivationPolicy(.accessory)

		// Nothing the helper fetches (segments, artwork) leaves cookies or a cache behind, whatever
		// profile the page plays from, private ones included.
		HTTPCookieStorage.shared.cookieAcceptPolicy = .never
		HTTPCookieStorage.shared.removeCookies(since: .distantPast)
		URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
		let output = FileHandle.standardOutput
		let helper = FairPlayHelper(
			publishesNowPlaying: environment[systemControlsVariable] != "0",
			isSilent: environment[silentVariable] == "1"
		) { event in
			output.write(FairPlayLineBuffer.line(event.encoded))
		}

		let input = FairPlayHelperInput(helper: helper)
		FileHandle.standardInput.readabilityHandler = { handle in
			let data = handle.availableData

			// In order: the main queue keeps the pipe's lines in sequence.
			DispatchQueue.main.async { MainActor.assumeIsolated { input.receive(data) } }
		}

		let interval = FairPlayHelper.reportInterval
		let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
		Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
			MainActor.assumeIsolated { helper.report() }
		}
		RunLoop.main.run()
		exit(0)
	}
}

/// The app's commands, split into lines on the main actor.
@MainActor
private final class FairPlayHelperInput {
	private let helper: FairPlayHelper
	private var buffer: FairPlayLineBuffer = FairPlayLineBuffer()

	init(helper: FairPlayHelper) {
		self.helper = helper
	}

	func receive(_ data: Data) {
		// The app closed the pipe: it's done with the helper.
		if data.isEmpty { exit(0) }
		guard let lines = try? buffer.append(data) else { exit(1) }
		for line in lines {
			guard let command = FairPlayHelperCommand(decoding: line) else { continue }
			helper.handle(command)
		}
	}
}
