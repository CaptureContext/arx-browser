import AppKit
import BrowserCore
import DiagnosticsClient
@testable import FeedbackFeature
import Foundation
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// Help › Send Feedback (DEV-1284): the draft, the limits, the failures, the form, and which window
/// shows it (DEV-1308).
@Suite(.dependencies)
@MainActor
internal struct SendFeedbackTests {
	nonisolated private static let details: ProblemReport.Diagnostics = .init(hardwareModel: "Mac16,10", memoryGB: 24, crashReports: [])

	private static func store(
		_ state: SendFeedbackFeature.State = .init(isLoaded: true),
		saved: LockIsolated<[FeedbackDraft]> = .init([]),
		sent: LockIsolated<[FeedbackSubmission]> = .init([]),
		failure: FeedbackFailure? = nil
	) -> TestStoreOf<SendFeedbackFeature> {
		TestStore(initialState: state) {
			SendFeedbackFeature()
		} withDependencies: {
			$0.continuousClock = ImmediateClock()
			$0.uuid = .incrementing
			$0.diagnostics.environment = { .preview }
			$0.diagnostics.diagnostics = { Self.details }
			$0.sendFeedback.saveDraft = { draft in saved.withValue { $0.append(draft) } }
			$0.sendFeedback.send = { submission throws(FeedbackFailure) in
				sent.withValue { $0.append(submission) }
				if let failure { throw failure }
			}
		}
	}

	// MARK: - Draft

	@Test
	internal func theDraftIsReadOnOpeningKeptAsItsTypedAndSavedOnClose() async {
		let saved: LockIsolated<[FeedbackDraft]> = .init([])
		let kept: FeedbackDraft = .init(kind: .feature, message: "Tab groups", email: "me@example.com")
		let store = Self.store(.init(), saved: saved)
		store.dependencies.sendFeedback.loadDraft = { kept }

		// Nothing can be typed over the draft before it's read.
		await store.send(.ui(.messageChanged("lost")))
		await store.send(.ui(.task))
		await store.receive(\.event.loaded) {
			$0.draft = kept
			$0.environment = .preview
			$0.isLoaded = true
		}
		await store.send(.ui(.messageChanged("Tab groups in Little Arx"))) { $0.draft.message = "Tab groups in Little Arx" }
		await store.send(.ui(.kindSelected(.other))) { $0.draft.kind = .other }
		await store.send(.ui(.close))
		await store.receive(\.delegate.close)
		#expect(saved.value.last == .init(kind: .other, message: "Tab groups in Little Arx", email: "me@example.com"))
	}

	@Test
	internal func theTextAndEmailAreCappedAtTheBackendsLimits() async {
		let store = Self.store()
		store.exhaustivity = .off
		await store.send(.ui(.messageChanged(String(repeating: "a", count: 10_050))))
		#expect(store.state.draft.message.count == SendFeedback.Limits.messageCharacters)
		await store.send(.ui(.emailChanged(String(repeating: "b", count: 300))))
		#expect(store.state.draft.email.count == SendFeedback.Limits.emailCharacters)
		// Counted as the backend counts: an emoji is two UTF-16 units, and none is cut in half.
		await store.send(.ui(.messageChanged(String(repeating: "🙂", count: 5_001) + "a")))
		#expect(store.state.draft.message.utf16.count == SendFeedback.Limits.messageCharacters)
		#expect(store.state.draft.message == String(repeating: "🙂", count: 5_000))
		#expect(SendFeedback.capped("ab🙂", to: 3) == "ab")
	}

	// MARK: - Sending

	@Test
	internal func sendingWithNothingWrittenSaysWriteSomethingFirst() async {
		let store = Self.store(.init(draft: .init(message: "  \n "), isLoaded: true))
		await store.send(.ui(.send)) { $0.failure = .emptyMessage }
		#expect(SendFeedbackView.text(.emptyMessage) == "Write something first.")
		// Typing clears it.
		await store.send(.ui(.messageChanged("Crash"))) {
			$0.draft.message = "Crash"
			$0.failure = nil
		}
		await store.finish()
	}

	@Test
	internal func anEmailThatIsntAnAddressStopsTheReport() async {
		let store = Self.store(.init(draft: .init(message: "Crash", email: "me at home"), isLoaded: true))
		await store.send(.ui(.send)) { $0.failure = .invalidEmail }
		#expect(SendFeedbackFeature.State.isValid(email: "me@example.com"))
		for invalid in ["me", "me@", "@example.com", "me@example", "me@@example.com", "me@example.", "m e@example.com"] {
			#expect(!SendFeedbackFeature.State.isValid(email: invalid), "\(invalid)")
		}
	}

	@Test
	internal func aSentReportClosesAtOnceAndKeepsOnlyTheEmail() async {
		let saved: LockIsolated<[FeedbackDraft]> = .init([])
		let sent: LockIsolated<[FeedbackSubmission]> = .init([])
		let picture: FeedbackAttachment = .init(id: UUID(0), name: "Shot.png", contentType: "image/png", data: Data([1, 2, 3]))
		let draft: FeedbackDraft = .init(kind: .vulnerability, message: "  XSS in arx://  \n", email: " me@example.com ", attachments: [picture])
		let store = Self.store(.init(draft: draft, isLoaded: true), saved: saved, sent: sent)

		await store.send(.ui(.send)) { $0.isSending = true }
		await store.receive(\.event.sent) {
			$0.isSending = false
			$0.draft = .init(email: " me@example.com ")
		}
		await store.receive(\.delegate.sent)

		let submission: FeedbackSubmission = try! #require(sent.value.first)
		#expect(submission.kind == .vulnerability)
		#expect(submission.message == "XSS in arx://")
		#expect(submission.email == "me@example.com")
		#expect(submission.attachments == [picture])
		#expect(submission.environment == .preview)
		#expect(submission.diagnostics.map { String(decoding: $0, as: UTF8.self) }?.contains("Mac16,10") == true)
		#expect(saved.value == [.init(email: " me@example.com ")])
	}

	@Test
	internal func nothingChangesOrClosesWhileAReportIsGoing() async {
		let store = Self.store(.init(draft: .init(message: "Crash"), isLoaded: true, isSending: true))
		await store.send(.ui(.messageChanged("other")))
		await store.send(.ui(.kindSelected(.other)))
		await store.send(.ui(.attachData(name: "a.txt", data: Data("a".utf8))))
		await store.send(.ui(.close))
		await store.send(.ui(.openPrivacyPolicy))
		await store.send(.ui(.send))
	}

	@Test
	internal func withoutDiagnosticsAndEmailNeitherIsSent() async {
		let sent: LockIsolated<[FeedbackSubmission]> = .init([])
		let store = Self.store(.init(draft: .init(message: "Idea", includesDiagnostics: false), isLoaded: true), sent: sent)
		await store.send(.ui(.send)) { $0.isSending = true }
		await store.receive(\.event.sent) {
			$0.isSending = false
			$0.draft = .init()
		}
		await store.receive(\.delegate.sent)
		#expect(sent.value.first?.diagnostics == nil)
		#expect(sent.value.first?.email == nil)
	}

	@Test(arguments: [FeedbackFailure.offline, .tooLarge, .tooMany, .unavailable, .refused])
	internal func aReportThatDidntGoStaysWithAPlainReason(failure: FeedbackFailure) async {
		let draft: FeedbackDraft = .init(message: "Crash")
		let saved: LockIsolated<[FeedbackDraft]> = .init([])
		let store = Self.store(.init(draft: draft, isLoaded: true), saved: saved, failure: failure)
		await store.send(.ui(.send)) { $0.isSending = true }
		await store.receive(\.event.sendFailed) {
			$0.isSending = false
			$0.failure = failure
		}
		#expect(store.state.draft == draft)
		#expect(!SendFeedbackView.text(failure).isEmpty)
		await store.finish()
		#expect(saved.value == [draft], "kept, though sending cancelled the save that was waiting")
	}

	@Test
	internal func failuresInPlainWords() {
		#expect(SendFeedbackView.text(.offline) == "Arx couldn't reach its server. Check your connection and try again.")
		#expect(SendFeedbackView.text(.tooManyFiles) == "You can attach up to 5 files.")
		let fourMB: String = (4 * 1_024 * 1_024).formatted(.byteCount(style: .memory))
		let fiveMB: String = (5 * 1_024 * 1_024).formatted(.byteCount(style: .memory))
		#expect(SendFeedbackView.text(.fileTooLarge(name: "Film.mov", total: 5 * 1_024 * 1_024)) == "With “Film.mov”, the files come to \(fiveMB), over the limit of \(fourMB). Leave one out.")
	}

	@Test
	internal func theBackendsAnswersMapToReasons() {
		#expect(FeedbackForm.failure(status: 201) == nil)
		#expect(FeedbackForm.failure(status: 413) == .tooLarge)
		#expect(FeedbackForm.failure(status: 415) == .tooLarge)
		#expect(FeedbackForm.failure(status: 429) == .tooMany)
		#expect(FeedbackForm.failure(status: 400) == .refused)
		#expect(FeedbackForm.failure(status: 502) == .unavailable)
		#expect(FeedbackForm.failure(status: 503) == .unavailable)
	}

	// MARK: - Attachments

	@Test
	internal func filesAreLimitedToFive() async {
		let store = Self.store()
		store.exhaustivity = .off
		let text: Data = Data("steps".utf8)
		await store.send(.ui(.attachData(name: "1.txt", data: text)))
		await store.send(.ui(.attachData(name: "2.txt", data: text)))
		await store.send(.ui(.attachData(name: "3.txt", data: text)))
		await store.send(.ui(.attachData(name: "4.txt", data: text)))
		await store.send(.ui(.attachData(name: "5.txt", data: text)))
		await store.skipReceivedActions()
		#expect(store.state.draft.attachments.map(\.name) == ["1.txt", "2.txt", "3.txt", "4.txt", "5.txt"])
		#expect(!store.state.canAttach)
		await store.send(.ui(.attachData(name: "6.txt", data: text)))
		#expect(store.state.failure == .tooManyFiles)
		#expect(store.state.draft.attachments.count == 5)
	}

	@Test
	internal func aFileOverTheRoomIsRefusedWithTheTotalAndRemovingOneMakesRoom() async {
		let store = Self.store()
		store.exhaustivity = .off
		let three: Data = Data(repeating: 1, count: 3 * 1_024 * 1_024)
		await store.send(.ui(.attachData(name: "a.txt", data: three)))
		await store.skipReceivedActions()
		await store.send(.ui(.attachData(name: "b.mp4", data: Data(repeating: 2, count: 2 * 1_024 * 1_024))))
		await store.skipReceivedActions()
		#expect(store.state.failure == .fileTooLarge(name: "b.mp4", total: 5 * 1_024 * 1_024))
		#expect(store.state.draft.attachments.map(\.name) == ["a.txt"])

		await store.send(.ui(.removeAttachment(store.state.draft.attachments[0].id)))
		#expect(store.state.draft.attachments.isEmpty)
		#expect(store.state.failure == nil)
	}

	@Test
	internal func anEmptyFileIsRefusedBeforeItCanStopTheReport() async {
		let store = Self.store()
		store.exhaustivity = .off
		await store.send(.ui(.attachData(name: "empty.txt", data: Data())))
		await store.skipReceivedActions()
		#expect(store.state.failure == .unreadableFile(name: "empty.txt"))
		#expect(store.state.draft.attachments.isEmpty)
	}

	@Test
	internal func leftOutFilesDontCountAsFinishedOnes() async {
		// Three attached and one still being read from an earlier choice: room for one more.
		let store = Self.store(.init(
			draft: .init(message: "Crash", attachments: (0 ..< 3).map {
				.init(id: UUID($0 + 100), name: "\($0).txt", contentType: "text/plain", data: Data("x".utf8))
			}),
			isLoaded: true,
			pendingAttachments: 1
		))
		await store.send(.ui(.attachFiles([URL(fileURLWithPath: "/nonexistent/b.txt"), URL(fileURLWithPath: "/nonexistent/c.txt")]))) {
			$0.pendingAttachments = 2
		}
		await store.receive(\.event.attached) {
			$0.pendingAttachments = 1
			$0.failure = .unreadableFile(name: "b.txt")
		}
		await store.receive(\.event.overflowed) { $0.failure = .tooManyFiles }

		// The earlier file is still on its way, so Send and closing wait for it.
		#expect(store.state.pendingAttachments == 1)
		await store.send(.ui(.send))
		await store.send(.ui(.close))
		await store.send(.ui(.openPrivacyPolicy))
	}

	@Test
	internal func aFileOfAnotherTypeIsRefused() async {
		let store = Self.store()
		store.exhaustivity = .off
		await store.send(.ui(.attachData(name: "run.sh", data: Data("echo".utf8))))
		await store.skipReceivedActions()
		#expect(store.state.failure == .unsupportedFile(name: "run.sh"))
		#expect(store.state.draft.attachments.isEmpty)
	}

	@Test
	internal func aLargePictureIsMadeSmallerToFit() throws {
		let png: Data = try #require(Self.noisePicture(width: 2_400, height: 1_800))
		#expect(png.count > SendFeedback.Limits.attachmentBytes)

		let result = FeedbackAttachments.attachment(id: UUID(0), name: "Screen.png", data: png, room: SendFeedback.Limits.attachmentBytes)
		let attachment: FeedbackAttachment = try result.get()
		#expect(attachment.name == "Screen.jpg")
		#expect(attachment.contentType == "image/jpeg")
		#expect(attachment.data.count <= SendFeedback.Limits.attachmentBytes)

		// A small picture goes as it is.
		let small: Data = try #require(Self.noisePicture(width: 40, height: 30))
		#expect(try FeedbackAttachments.attachment(id: UUID(1), name: "s.png", data: small, room: 1_000_000).get().data == small)
	}

	// MARK: - Form

	@Test
	internal func theFormCarriesExactlyTheBackendsFields() {
		let submission: FeedbackSubmission = .init(
			kind: .bug,
			message: "Line one\nLine two",
			email: "me@example.com",
			environment: .preview,
			diagnostics: Data("{}".utf8),
			attachments: [.init(id: UUID(0), name: "a\"b.png", contentType: "image/png", data: Data([9]))]
		)
		let body: String = String(decoding: FeedbackForm.body(submission, boundary: "B"), as: UTF8.self)
		let names: [String] = body.components(separatedBy: "form-data; name=\"").dropFirst().map { String($0.prefix { $0 != "\"" }) }
		#expect(names == ["kind", "message", "email", "appVersion", "engineVersion", "macOSVersion", "diagnostics", "attachment"])
		#expect(body.contains("\r\n\r\nbug\r\n"))
		#expect(body.contains("\r\n\r\n0.3.0 (12)\r\n"))
		#expect(body.contains("\r\n\r\nHelium 0.20.1.1, Chromium 147.0.7727.55\r\n"))
		#expect(body.contains("\r\n\r\nmacOS 27.0 (26A425), arm64\r\n"))
		#expect(body.contains("filename=\"ab.png\"\r\nContent-Type: image/png"))
		#expect(body.hasSuffix("--B--\r\n"))

		var anonymous: FeedbackSubmission = submission
		anonymous.email = nil
		anonymous.diagnostics = nil
		let plain: String = String(decoding: FeedbackForm.body(anonymous, boundary: "B"), as: UTF8.self)
		#expect(!plain.contains("name=\"email\""))
		#expect(!plain.contains("name=\"diagnostics\""))
	}

	@Test
	internal func diagnosticsOverTheLimitLeaveOutTheOldestUntilTheyFit() throws {
		let reports: [CrashReport] = (0 ..< 40).map {
			.init(id: "crash-\($0)", date: Date(timeIntervalSince1970: TimeInterval(1_000 - $0)), source: .engine, process: String(repeating: "x", count: 400))
		}
		let details: ProblemReport.Diagnostics = .init(hardwareModel: "Mac16,10", memoryGB: 24, crashReports: reports)
		let all: Data = try #require(FeedbackForm.diagnostics(details, environment: .preview))
		let data: Data = try #require(FeedbackForm.diagnostics(details, environment: .preview, limit: all.count / 3))
		#expect(data.count <= all.count / 3)
		let text: String = String(decoding: data, as: UTF8.self)
		#expect(text.contains("crash-0"), "the newest is kept")
		#expect(!text.contains("crash-39"), "the oldest goes first")
		#expect(text.contains("0.3.0"))
	}

	// MARK: - App

	@Test
	internal func helpOpensOneCardOnTheMainWindowAndSendingClosesIt() async {
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.windowIsOpen = false
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.continuousClock = ImmediateClock()
			$0.diagnostics.environment = { .preview }
			$0.diagnostics.diagnostics = { Self.details }
			$0.sendFeedback.loadDraft = { .init() }
			$0.sendFeedback.saveDraft = { _ in }
			$0.sendFeedback.send = { _ throws(FeedbackFailure) in }
		}
		store.exhaustivity = .off

		await store.send(.ui(.sendFeedback(nil)))
		#expect(store.state.feedback != nil)
		#expect(store.state.feedbackHost == .window(store.state.main.id))
		#expect(store.state.windowIsOpen)

		await store.send(.feedback(.ui(.task)))
		await store.receive(\.feedback.event.loaded)
		await store.send(.feedback(.ui(.messageChanged("Crash"))))

		// Asking again keeps what's typed.
		await store.send(.ui(.sendFeedback(.window(UUID()))))
		#expect(store.state.feedback?.draft.message == "Crash")
		#expect(store.state.feedbackHost == .window(store.state.main.id), "an unknown window falls back to the main one")

		await store.send(.feedback(.ui(.send)))
		await store.receive(\.feedback.delegate.sent)
		#expect(store.state.feedback == nil)
		#expect(store.state.feedbackHost == nil)
	}

	@Test
	internal func thePrivacyPolicyOpensInATabAfterTheCardCloses() async {
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.feedback = .init(draft: .init(message: "Draft"), isLoaded: true)
		initial.feedbackHost = .window(initial.main.id)
		let saved: LockIsolated<[FeedbackDraft]> = .init([])
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.sendFeedback.saveDraft = { draft in saved.withValue { $0.append(draft) } }
		}
		store.exhaustivity = .off

		await store.send(.feedback(.ui(.openPrivacyPolicy)))
		await store.receive(\.feedback.delegate.open, ArxService.privacyPolicy)
		await store.receive(\.main.ui.openInNewTab, ArxService.privacyPolicy)
		#expect(store.state.feedback == nil)
		#expect(saved.value == [.init(message: "Draft")])
	}

	@Test
	internal func sendFeedbackIsACommandInTheHelpMenuWithAShortcut() {
		#expect(BrowserCommand.sendFeedback.shortcut == .init(key: "i", modifiers: [.command, .option, .shift]))
		#expect(BrowserCommand.sendFeedback.isEnabled(in: .init(host: .application)))
		#expect(ArxService.privacyPolicy.absoluteString == "https://arxbrowser.net/privacy-policy")
	}

	/// DEV-1308: only Vulnerability has a tooltip among the kinds, and the privacy agreement links
	/// the policy's name, not the whole sentence.
	@Test
	internal func onlyVulnerabilityHasAHintAndThePolicysNameIsTheLink() throws {
		#expect(SendFeedbackView.hint(.vulnerability) == "Marked urgent and kept private until fixed")
		for kind in [SendFeedback.Kind.bug, .feature, .other] {
			#expect(SendFeedbackView.hint(kind) == nil, "\(kind)")
		}

		let agreement = SendFeedbackView.privacyAgreement
		#expect(String(agreement.characters) == "By sending this report, you agree to our Privacy Policy.")
		let linked = agreement.runs.compactMap { run in run.link.map { (String(agreement[run.range].characters), $0) } }
		#expect(linked.count == 1)
		#expect(linked.first?.0 == "Privacy Policy")
		#expect(linked.first?.1 == ArxService.privacyPolicy)
	}

	// MARK: - Which window (DEV-1308)

	/// `feedback` is a card already open on Settings.
	private static func appStore(
		settingsIsOpen: Bool,
		feedback: SendFeedbackFeature.State? = nil
	) -> TestStoreOf<AppFeature> {
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.settingsIsOpen = settingsIsOpen
		if let feedback {
			initial.feedback = feedback
			initial.feedbackHost = .settings
		}
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.continuousClock = ImmediateClock()
			$0.diagnostics.environment = { .preview }
			$0.diagnostics.diagnostics = { Self.details }
			$0.sendFeedback.loadDraft = { .init() }
			$0.sendFeedback.saveDraft = { _ in }
			$0.sendFeedback.send = { _ throws(FeedbackFailure) in }
		}
		store.exhaustivity = .off
		return store
	}

	@Test
	internal func askedFromSettingsTheCardIsOnTheSettingsWindow() async {
		let store = Self.appStore(settingsIsOpen: true)

		await store.send(.ui(.command(.sendFeedback, .settings)))
		await store.receive(\.ui.sendFeedback, .settings)
		#expect(store.state.feedback != nil)
		#expect(store.state.feedbackHost == .settings)

		// Asked again from a browser window, the card moves there with what's typed.
		await store.send(.feedback(.ui(.task)))
		await store.receive(\.feedback.event.loaded)
		await store.send(.feedback(.ui(.messageChanged("Crash"))))
		await store.send(.ui(.command(.sendFeedback, .window(store.state.main.id))))
		await store.receive(\.ui.sendFeedback, .window(store.state.main.id))
		#expect(store.state.feedbackHost == .window(store.state.main.id))
		#expect(store.state.feedback?.draft.message == "Crash")
	}

	@Test
	internal func askedFromABrowserWindowTheCardStaysOnIt() async {
		let store = Self.appStore(settingsIsOpen: true)

		await store.send(.ui(.command(.sendFeedback, .window(store.state.main.id))))
		await store.receive(\.ui.sendFeedback, .window(store.state.main.id))
		#expect(store.state.feedbackHost == .window(store.state.main.id), "Settings being open doesn't take the card")
	}

	@Test
	internal func askedForSettingsAfterItClosedTheCardIsOnTheMainWindow() async {
		let store = Self.appStore(settingsIsOpen: false)

		await store.send(.ui(.sendFeedback(.settings)))
		#expect(store.state.feedbackHost == .window(store.state.main.id))
	}

	@Test
	internal func closingSettingsClosesTheCardOnItAndKeepsTheDraft() async {
		let saved: LockIsolated<[FeedbackDraft]> = .init([])
		let store = Self.appStore(settingsIsOpen: true)
		store.dependencies.sendFeedback.saveDraft = { draft in saved.withValue { $0.append(draft) } }

		await store.send(.ui(.sendFeedback(.settings)))
		await store.send(.feedback(.ui(.task)))
		await store.receive(\.feedback.event.loaded)
		await store.send(.feedback(.ui(.messageChanged("Crash"))))
		await store.send(.ui(.closeSettings))
		await store.receive(\.feedback.delegate.close)
		#expect(store.state.feedback == nil)
		#expect(store.state.feedbackHost == nil)
		#expect(saved.value.last?.message == "Crash")
	}

	@Test
	internal func closingSettingsWhileAReportIsGoingMovesTheCardToTheMainWindow() async {
		let store = Self.appStore(settingsIsOpen: true, feedback: .init(draft: .init(message: "Crash"), isLoaded: true, isSending: true))

		await store.send(.ui(.closeSettings))
		await store.receive(\.ui.sendFeedback, nil)
		#expect(store.state.feedback?.isSending == true)
		#expect(store.state.feedbackHost == .window(store.state.main.id))
	}

	@Test
	internal func closingSettingsLeavesACardOnABrowserWindow() async {
		let store = Self.appStore(settingsIsOpen: true)

		await store.send(.ui(.sendFeedback(.window(store.state.main.id))))
		await store.send(.ui(.closeSettings))
		#expect(store.state.feedback != nil)
		#expect(store.state.feedbackHost == .window(store.state.main.id))
	}

	// MARK: - Helpers

	/// A PNG of random pixels, which compresses badly, so it's large.
	private static func noisePicture(
		width: Int,
		height: Int
	) -> Data? {
		guard let bitmap = NSBitmapImageRep(
			bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 3,
			hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24
		), let pixels = bitmap.bitmapData
		else { return nil }

		var generator: SystemRandomNumberGenerator = .init()
		for index in 0 ..< width * height * 3 {
			pixels[index] = UInt8.random(in: 0 ... 255, using: &generator)
		}
		return bitmap.representation(using: .png, properties: [:])
	}
}
