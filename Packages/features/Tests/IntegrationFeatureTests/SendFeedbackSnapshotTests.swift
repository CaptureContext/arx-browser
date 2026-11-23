import AppKit
import AppUI
import DiagnosticsClient
@testable import FeedbackFeature
import SwiftUI
import Testing
import _ComposableArchitecture

/// Writes offscreen PNGs of Help's report sheets (DEV-1284), in light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory: before, Report a Problem; after, the Send Feedback
/// card empty, written with files, a vulnerability, sending, failed, and with files dragged over.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct SendFeedbackSnapshotTests {
	private static func picture(_ color: NSColor) -> Data {
		let image: NSImage = .init(size: .init(width: 160, height: 100), flipped: false) { rect in
			color.setFill()
			rect.fill()
			NSColor.white.withAlphaComponent(0.7).setFill()
			NSRect(x: 12, y: 60, width: 90, height: 12).fill()
			NSRect(x: 12, y: 40, width: 120, height: 8).fill()
			return true
		}
		return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
	}

	private static let written: FeedbackDraft = .init(
		kind: .bug,
		message: "The sidebar flickers when I switch spaces with ⌃→.\nIt started after the last update, on a Mac with two displays.",
		email: "someone@example.com",
		attachments: [
			.init(id: UUID(0), name: "Flicker.png", contentType: "image/png", data: picture(.systemTeal)),
			.init(id: UUID(1), name: "Second display.png", contentType: "image/png", data: picture(.systemIndigo)),
			.init(id: UUID(2), name: "Steps.txt", contentType: "text/plain", data: Data("steps".utf8)),
		]
	)

	private static let states: [(String, SendFeedbackFeature.State, Bool)] = [
		("empty", .init(environment: .preview, isLoaded: true), false),
		("written", .init(draft: written, environment: .preview, isLoaded: true), false),
		("kind-bug", .init(draft: .init(kind: .bug, email: "someone@example.com"), environment: .preview, isLoaded: true), false),
		("kind-feature", .init(draft: .init(kind: .feature), environment: .preview, isLoaded: true), false),
		("vulnerability", .init(draft: .init(kind: .vulnerability, message: "arx:// pages run a script from the address."), environment: .preview, isLoaded: true), false),
		("kind-other", .init(draft: .init(kind: .other, includesDiagnostics: false), environment: .preview, isLoaded: true), false),
		("sending", .init(draft: written, environment: .preview, isLoaded: true, isSending: true), false),
		("failed", .init(draft: written, environment: .preview, isLoaded: true, failure: .offline), false),
		("too-large", .init(draft: written, environment: .preview, isLoaded: true, failure: .fileTooLarge(name: "Screen Recording.mov", total: 9_400_000)), false),
		("nothing-written", .init(environment: .preview, isLoaded: true, failure: .emptyMessage), false),
		("drop", .init(draft: written, environment: .preview, isLoaded: true), true),
	]

	@Test(arguments: [false, true])
	internal func sendFeedback(dark: Bool) throws {
		for (name, state, dropping) in Self.states {
			let store: StoreOf<SendFeedbackFeature> = .init(initialState: state) { SendFeedbackFeature() } withDependencies: {
				$0.sendFeedback = .fake(draftFile: nil)
				$0.diagnostics = .previewValue
			}
			try render(SendFeedbackView(store: store, isDropTargeted: dropping), name: "send-feedback-\(name)", dark: dark)
		}
	}

	@Test(arguments: [false, true])
	internal func reportAProblemBefore(dark: Bool) throws {
		let store: StoreOf<ProblemReportFeature> = .init(
			initialState: .init(text: "The sidebar flickers when I switch spaces.", environment: .preview, diagnostics: .init(hardwareModel: "Mac16,10", memoryGB: 24, crashReports: [CrashReport]()))
		) { ProblemReportFeature() } withDependencies: { $0.diagnostics = .previewValue }
		try render(ProblemReportView(store: store).background(ArxModalMetrics.background), name: "report-a-problem-before", dark: dark)
	}

	private func render(
		_ content: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let view = content
			.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
			.padding(24)
			.background(Color.gray.opacity(0.35))
			.fixedSize()
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<8 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		host.frame = .init(origin: .zero, size: host.fittingSize)
		window.setContentSize(host.frame.size)
		host.layoutSubtreeIfNeeded()
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
