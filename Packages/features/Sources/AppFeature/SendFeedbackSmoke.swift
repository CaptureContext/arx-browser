#if DEBUG
import AppKit
import BrowserCore
import FeedbackFeature
import Foundation
import _ComposableArchitecture

/// The app smoke's `send-feedback` phase (DEV-1284). Needs the screen: it checks the card is a
/// sheet on the window it was asked from.
///
/// Send Feedback, run as a command on the main window, puts the card on that window as a sheet.
/// A message, a pasted picture and an email go in; Cancel closes it and opening it again finds
/// them, the picture included. Send goes to Debug's fake backend (`ARX_BACKEND_URL` unset), and
/// the card closes at once with only the email kept. Then, run as a command on Settings, the card
/// is a sheet on the Settings window, and closing Settings closes it (DEV-1308). The person's own
/// draft is put back after.
@MainActor
internal enum SendFeedbackSmoke {
	/// `openSettings` opens the Settings window and returns it.
	internal static func run(
		store: StoreOf<AppFeature>,
		window: NSWindow,
		openSettings: () -> NSWindow?
	) async throws {
		guard FeatureFlag.feedbackForm.isOn(), ProcessInfo.processInfo.environment["ARX_BACKEND_URL"] == nil
		else { throw Failure.invalidFixture }

		let file: URL = SendFeedbackClient.draftFile
		let saved: Data? = try? Data(contentsOf: file)
		defer {
			if let saved { try? saved.write(to: file, options: .atomic) } else { try? FileManager.default.removeItem(at: file) }
		}
		try? FileManager.default.removeItem(at: file)

		store.send(.ui(.command(.sendFeedback, .window(store.main.id))))
		try await wait(context: { describe(store, window) }) {
			store.feedbackHost == .window(store.main.id) && store.feedback?.isLoaded == true && window.attachedSheet != nil
		}

		store.send(.feedback(.ui(.kindSelected(.bug))))
		store.send(.feedback(.ui(.messageChanged("Smoke: the sidebar flickers"))))
		store.send(.feedback(.ui(.emailChanged("smoke@example.com"))))
		store.send(.feedback(.ui(.attachData(name: "Pasted Picture.png", data: try picture()))))
		try await wait(context: { describe(store, window) }) {
			store.feedback?.draft.attachments.count == 1 && store.feedback?.pendingAttachments == 0
		}

		// Cancel keeps the draft, files included.
		store.send(.feedback(.ui(.close)))
		try await wait(context: { describe(store, window) }) { store.feedback == nil && window.attachedSheet == nil }
		store.send(.ui(.command(.sendFeedback, .window(store.main.id))))
		try await wait(context: { describe(store, window) }) {
			store.feedback?.isLoaded == true && window.attachedSheet != nil
		}
		guard
			store.feedback?.draft.message == "Smoke: the sidebar flickers",
			store.feedback?.draft.attachments.count == 1
		else { throw Failure.draftLost }

		store.send(.feedback(.ui(.send)))
		try await wait(context: { describe(store, window) }) { store.feedback == nil && window.attachedSheet == nil }
		try await wait(context: { "draft=\(String(describing: try? Data(contentsOf: file).count))" }) {
			(try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(FeedbackDraft.self, from: $0) }
				== FeedbackDraft(email: "smoke@example.com")
		}

		// DEV-1308: asked from Settings, the card is a sheet on the Settings window.
		guard let settings = openSettings()
		else { throw Failure.invalidFixture }

		store.send(.ui(.command(.sendFeedback, .settings)))
		try await wait(context: { describe(store, settings) }) {
			store.feedbackHost == .settings && store.feedback?.isLoaded == true && settings.attachedSheet != nil
		}
		guard window.attachedSheet == nil
		else { throw Failure.wrongWindow }

		store.send(.ui(.closeSettings))
		try await wait(context: { describe(store, settings) }) { store.feedback == nil && !store.settingsIsOpen }
		FileHandle.standardError.write(Data("ARX_SEND_FEEDBACK_SMOKE_OK\n".utf8))
	}

	private static func picture() throws -> Data {
		let image: NSImage = .init(size: .init(width: 64, height: 48), flipped: false) { rect in
			NSColor.systemTeal.setFill()
			rect.fill()
			return true
		}
		guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
		else { throw Failure.invalidFixture }

		return png
	}

	private static func describe(
		_ store: StoreOf<AppFeature>,
		_ window: NSWindow
	) -> String {
		"feedback=\(store.feedback != nil) host=\(String(describing: store.feedbackHost))"
			+ " loaded=\(store.feedback?.isLoaded ?? false) sending=\(store.feedback?.isSending ?? false)"
			+ " failure=\(String(describing: store.feedback?.failure)) sheet=\(window.attachedSheet != nil)"
	}

	private static func wait(
		line: UInt = #line,
		context: () -> String = { "" },
		until ready: () -> Bool
	) async throws {
		for _ in 0..<150 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		let message = "ARX_SEND_FEEDBACK_SMOKE_TIMEOUT line=\(line) \(context())\n"
		FileHandle.standardError.write(Data(message.utf8))
		throw Failure.timedOut
	}

	private enum Failure: Error {
		case invalidFixture
		case draftLost
		case wrongWindow
		case timedOut
	}
}
#endif
