import AppKit
import Foundation

/// Lets `make benchmark` time tab commands through the path a person's keyboard takes
/// (DEV-939): it posts synthesized key events to the app's own event queue, so they pass
/// the same key monitor, menu and command routing as real keys, and reports back when
/// asked. It only runs with `ARX_BENCHMARK_DRIVER=1` on a throwaway `ARX_ENGINE_PROFILE`,
/// in a windowed run.
///
/// Commands are JSON lines on stdin; each gets one reply line on stdout,
/// `ARX_BENCHMARK_DRIVER {"id":…,"ok":…}`:
/// - `activate`: bring Arx and its main window forward, so keys reach the key window.
/// - `key`: post a key down and up (`keyCode`, `characters`, `modifiers`).
/// - `awaitTextInput`: wait until an empty text field has keyboard focus (a command bar).
/// - `insertText`: insert `text` into the focused text field, as a paste would.
@MainActor
internal final class BenchmarkDriver {
	private struct Command: Decodable {
		internal var id: Int
		internal var action: String
		internal var keyCode: UInt16?
		internal var characters: String?
		internal var modifiers: [String]?
		internal var text: String?
		internal var timeout: Double?
	}

	private struct Reply: Encodable {
		internal var id: Int
		internal var ok: Bool
		internal var detail: String?
	}

	private static var running: BenchmarkDriver?

	private let mainWindow: () -> NSWindow?
	private var buffer: Data = .init()

	private init(mainWindow: @escaping () -> NSWindow?) {
		self.mainWindow = mainWindow
	}

	internal static func isRequested(environment: [String: String]) -> Bool {
		environment["ARX_BENCHMARK_DRIVER"] == "1"
		&& environment["ARX_ENGINE_PROFILE"] != nil
	}

	internal static func start(mainWindow: @escaping () -> NSWindow?) {
		guard running == nil else { return }
		let driver = BenchmarkDriver(mainWindow: mainWindow)
		running = driver
		FileHandle.standardInput.readabilityHandler = { handle in
			let data = handle.availableData

			// The main queue keeps chunks in arrival order; a line may span two of them.
			DispatchQueue.main.async {
				MainActor.assumeIsolated { driver.receive(data) }
			}
		}
	}

	private func receive(_ data: Data) {
		guard !data.isEmpty else {
			FileHandle.standardInput.readabilityHandler = nil
			return
		}
		buffer.append(data)
		while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
			let line = buffer[buffer.startIndex..<newline]
			buffer = Data(buffer[buffer.index(after: newline)...])
			guard let command = try? JSONDecoder().decode(Command.self, from: line) else {
				reply(.init(id: -1, ok: false, detail: "invalidCommand"))
				continue
			}
			Task { await perform(command) }
		}
	}

	private func perform(_ command: Command) async {
		switch command.action {
		case "activate":
			NSApplication.shared.activate(ignoringOtherApps: true)
			mainWindow()?.makeKeyAndOrderFront(nil)
			reply(.init(id: command.id, ok: NSApplication.shared.isActive, detail: nil))

		case "key":
			guard
				let keyCode = command.keyCode,
				let characters = command.characters
			else { return reply(.init(id: command.id, ok: false, detail: "missingKey")) }
			let posted: Bool = postKey(
				keyCode: keyCode,
				characters: characters,
				modifiers: Self.modifierFlags(command.modifiers ?? [])
			)
			reply(.init(id: command.id, ok: posted, detail: posted ? nil : "noWindow"))

		case "awaitTextInput":
			let deadline: Date = .now.addingTimeInterval(command.timeout ?? 5)
			while Date.now < deadline {
				if let field = Self.focusedTextField, field.string.isEmpty {
					return reply(.init(id: command.id, ok: true, detail: nil))
				}
				try? await Task.sleep(for: .milliseconds(2))
			}
			reply(.init(id: command.id, ok: false, detail: "timeout"))

		case "insertText":
			guard
				let field = Self.focusedTextField,
				let text = command.text
			else { return reply(.init(id: command.id, ok: false, detail: "noTextField")) }
			field.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
			reply(.init(id: command.id, ok: true, detail: nil))

		default:
			reply(.init(id: command.id, ok: false, detail: "unknownAction"))
		}
	}

	/// The field editor of the key window's focused text field.
	private static var focusedTextField: NSTextView? {
		guard
			let field = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
			field.isFieldEditor
		else { return nil }

		return field
	}

	private func postKey(
		keyCode: UInt16,
		characters: String,
		modifiers: NSEvent.ModifierFlags
	) -> Bool {
		guard let window = NSApplication.shared.keyWindow ?? mainWindow()
		else { return false }

		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: modifiers,
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: keyCode
			)
			else { return false }

			NSApplication.shared.postEvent(event, atStart: false)
		}
		return true
	}

	private static func modifierFlags(_ names: [String]) -> NSEvent.ModifierFlags {
		names.reduce(into: []) { flags, name in
			switch name {
			case "command": flags.insert(.command)
			case "shift": flags.insert(.shift)
			case "option": flags.insert(.option)
			case "control": flags.insert(.control)
			default: break
			}
		}
	}

	private func reply(_ reply: Reply) {
		guard let json = try? JSONEncoder().encode(reply) else { return }
		FileHandle.standardOutput.write(Data("ARX_BENCHMARK_DRIVER ".utf8) + json + Data("\n".utf8))
	}
}
