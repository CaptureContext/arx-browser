import ChromiumEngine
import Foundation

/// Hide Element (⇧⌘H, DEV-1019) opens uBlock Origin's element picker on an ordinary page. The
/// app's shortcut calls the same `startElementPicker(on:)`. arx.js reports what uBlock made of
/// the ask as `arxElementPickerStatus`, which this reads back: anything but an opened picker
/// whose probe script ran fails the smoke with that status. The picker's frame must then be
/// on the page.
@MainActor
internal enum ExtensionSmokeElementPicker {
	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		phase: (String) -> Void
	) async throws {
		phase("element-picker")
		guard
			runtime.supportsElementHiding,
			runtime.supportsDeveloperTier
		else { throw Failure.unsupported }

		let status = try await pickerStatus(runtime: runtime, page: page)

		guard
			status["outcome"] as? String == "opened",
			status["probe"] as? String == "ok"
		else { throw Failure.picker(describe(status)) }

		phase("element-picker-frame")
		try await waitForPickerFrame(runtime: runtime, page: page)
	}

	/// The status of a picker ask this phase made. uBlock may still be starting in the profile,
	/// or restarting after its first run, and miss an ask, so a quiet one is asked again.
	private static func pickerStatus(
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws -> [String: Any] {
		var last: [String: Any] = [:]

		for _ in 0..<attempts {
			let previous = try await read(runtime: runtime, page: page)["request"] as? Double
			guard runtime.startElementPicker(on: page)
			else { throw Failure.refused }

			for _ in 0..<pollsPerAttempt {
				try await Task.sleep(for: .milliseconds(100))
				last = try await read(runtime: runtime, page: page)

				let isNew = last["request"] as? Double != previous
				let outcome = last["outcome"] as? String
				if isNew, let outcome, outcome != "queued" { return last }
			}
		}

		throw Failure.picker("no answer after \(attempts) asks; last \(describe(last))")
	}

	private static func read(
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws -> [String: Any] {
		try Task.checkCancellation()
		guard let status = await runtime.elementPickerStatus(on: page)
		else { throw Failure.unsupported }

		return status
	}

	/// epicker.js puts its dialog in a frame at the page's root.
	private static func waitForPickerFrame(
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws {
		for _ in 0..<pollsPerAttempt {
			try Task.checkCancellation()
			let value = try await runtime.evaluateScript(
				page,
				source: "return document.documentElement.querySelector(':scope > iframe') !== null;",
				maximumBytes: 1024,
				timeoutMilliseconds: 2000
			)
			if value == .json("true") { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		throw Failure.picker("uBlock reported the picker opened, but its frame never reached the page")
	}

	/// The status as JSON: ids, outcomes and error messages only, never a page's address.
	private static func describe(_ status: [String: Any]) -> String {
		guard
			JSONSerialization.isValidJSONObject(status),
			let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys])
		else { return "{}" }

		return String(decoding: data, as: UTF8.self)
	}

	private static let attempts: Int = 4
	private static let pollsPerAttempt: Int = 50

	private enum Failure: Error, CustomStringConvertible {
		case unsupported
		case refused
		case picker(String)

		var description: String {
			switch self {
			case .unsupported: "element picker unsupported by this engine"
			case .refused: "the engine refused to start the element picker"
			case let .picker(status): "element picker: \(status)"
			}
		}
	}
}
