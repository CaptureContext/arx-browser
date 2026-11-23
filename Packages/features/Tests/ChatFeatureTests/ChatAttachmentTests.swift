import AgentClient
import BrowserCore
import ChatFeature
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

/// Files, images and captures in the composer, and what plain Return does (DEV-798).
@Suite(.dependencies)
@MainActor
internal struct ChatAttachmentTests {
	private typealias ID = AgentConversation.ID

	private let profileID: Profile.ID = ChatWorld.profileID
	private let start: Date = ChatWorld.start

	// MARK: - Return key

	@Test(arguments: ChatReturnKeyBehavior.allCases)
	internal func shiftReturnStartsALineAndCommandReturnSendsWhateverTheSetting(_ behavior: ChatReturnKeyBehavior) {
		for draft in ["", "one line", "two\nlines"] {
			#expect(behavior.action(modifiers: .shift, draft: draft) == .newLine)
			#expect(behavior.action(modifiers: .option, draft: draft) == .newLine)
			#expect(behavior.action(modifiers: .command, draft: draft) == .send)
			#expect(behavior.action(modifiers: [.command, .shift], draft: draft) == .send)
		}
	}

	@Test
	internal func plainReturnFollowsTheSetting() {
		#expect(ChatReturnKeyBehavior.send.action(modifiers: [], draft: "one\ntwo") == .send)
		#expect(ChatReturnKeyBehavior.newLine.action(modifiers: [], draft: "one") == .newLine)
		#expect(ChatReturnKeyBehavior.sendOneLiners.action(modifiers: [], draft: "one line") == .send)
		#expect(ChatReturnKeyBehavior.sendOneLiners.action(modifiers: [], draft: "one\ntwo") == .newLine)
	}

	// MARK: - Attachments

	@Test
	internal func droppedFilesJoinTheComposerAndAProblemIsShownInstead() async throws {
		let world: ChatWorld = .init()
		let image: AgentFileAttachment = Self.file("shot.png", kind: .image, bytes: 10)
		let tooLarge: AgentFileAttachment = Self.file("huge.png", kind: .image, bytes: 4_000_000)
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
			$0.chatAttachmentLoader = .init(
				files: { urls in
					urls.map { url in
						switch url.lastPathComponent {
						case "shot.png": .loaded(image)
						case "huge.png": .loaded(tooLarge)
						default: .failed(.unsupported(name: url.lastPathComponent))
						}
					}
				},
				image: { _, name, _ in .failed(.unreadable(name: name)) }
			)
		}

		await store.send(.ui(.filesAdded([URL(fileURLWithPath: "/tmp/shot.png")])))
		var attached: AgentFileAttachment = image
		attached.id = UUID(0)
		await store.receive(\.event.attachmentsLoaded) {
			$0.attachments = [.file(attached)]
			$0.focusRequest = 1
		}

		await store.send(.ui(.filesAdded([URL(fileURLWithPath: "/tmp/huge.png"), URL(fileURLWithPath: "/tmp/app.zip")])))
		await store.receive(\.event.attachmentsLoaded) {
			$0.attachmentIssue = .unsupported(name: "app.zip")
			$0.focusRequest = 2
		}
		await store.send(.ui(.filesAdded([URL(fileURLWithPath: "/tmp/huge.png")])))
		await store.receive(\.event.attachmentsLoaded) {
			$0.attachmentIssue = .limit(.tooLarge(name: "huge.png", limit: 3_750_000), provider: .claude)
			$0.focusRequest = 3
		}

		await store.send(.ui(.attachmentIssueDismissed)) {
			$0.attachmentIssue = nil
		}
		await store.send(.ui(.detached(0))) {
			$0.attachments = []
		}
	}

	@Test
	internal func aPastedImageOrCaptureIsReadForTheSurfaceItCameFrom() async throws {
		let world: ChatWorld = .init()
		let capture: AgentFileAttachment = Self.file("Docs.png", kind: .image, bytes: 20, pageURL: "https://docs.example/")
		let store = TestStore(initialState: ChatFeature.State(id: profileID, isLoaded: true)) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
			$0.chatAttachmentLoader = .init(
				files: { _ in [] },
				image: { _, _, _ in .loaded(capture) }
			)
		}
		let surfaceID: ChatSurfaceID = .window(UUID(40))

		await store.send(.surfaces(.element(
			id: surfaceID,
			action: .ui(.imageAdded(Data([1, 2, 3]), name: "Docs.png", pageURL: "https://docs.example/"))
		))) {
			$0.activeSurfaceID = surfaceID
			$0.surfaces[surfaceID] = .init(newChatProvider: .claude)
		}
		var attached: AgentFileAttachment = capture
		attached.id = UUID(0)
		await store.receive(\.event.attachmentsLoaded) {
			$0.surfaces[surfaceID]?.attachments = [.file(attached)]
			$0.surfaces[surfaceID]?.focusRequest = 1
		}
		#expect(store.state.surfaces[.standalone]?.attachments == [])
	}

	@Test
	internal func theTurnCarriesTheBytesAndTheTranscriptKeepsOnlyThePreview() async throws {
		let world: ChatWorld = .init()
		world.script.setValue(.endless)
		var image: AgentFileAttachment = Self.file("shot.png", kind: .image, bytes: 10)
		image.preview = Data([9])
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, draft: "What's this?")
		initialState.attachments = [.file(image)]
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}
		store.exhaustivity = .off

		await store.send(.ui(.sendTapped))
		let message: AgentMessage? = store.state.conversations.first?.messages.first
		expectNoDifference(message?.attachments, [.file(image.withoutData)])
		#expect(message?.attachments.first?.file?.preview == Data([9]))
		#expect(message?.attachments.first?.file?.byteCount == 10)
		expectNoDifference(store.state.turn?.attachments, [.file(image)])

		await store.receive(\.event.turnStarted)
		expectNoDifference(world.requests.value.first?.attachments, [.file(image)])
		await store.send(.ui(.stopTapped))
		await store.finish()
	}

	@Test
	internal func sendingStopsWhenTheProviderCantTakeTheAttachments() async throws {
		let world: ChatWorld = .init()
		let pdf: AgentFileAttachment = Self.file("book.pdf", kind: .pdf, bytes: 30_000_000)
		var initialState: ChatFeature.State = .init(id: profileID, isLoaded: true, draft: "Summarize")
		initialState.attachments = [.file(pdf)]
		let store = TestStore(initialState: initialState) {
			ChatFeature()
		} withDependencies: {
			world.install(into: &$0)
		}

		await store.send(.ui(.sendTapped)) {
			$0.attachmentIssue = .limit(.tooLarge(name: "book.pdf", limit: 20_000_000), provider: .claude)
		}
		#expect(world.requests.value.isEmpty)
	}

	@Test
	internal func providerLimitsCountFilesAndImages() {
		let images: [AgentContextAttachment] = (0..<11).map { .file(Self.file("\($0).png", kind: .image, bytes: 1)) }
		#expect(AgentAttachmentLimits.codex.problem(with: images) == .tooManyFiles(limit: 10))
		#expect(AgentAttachmentLimits.codex.problem(with: Array(images.prefix(10))) == nil)
		var heic: AgentFileAttachment = Self.file("photo.heic", kind: .image, bytes: 1)
		heic.mediaType = "image/heic"
		#expect(AgentAttachmentLimits.claude.problem(with: [.file(heic)]) == .unsupported(name: "photo.heic"))
		#expect(AgentProvider.openAI.attachmentLimits == .codex)
		#expect(AgentProvider.claude.attachmentLimits == .claude)
	}

	// MARK: - Fixtures

	internal static func file(
		_ name: String,
		kind: AgentFileAttachment.Kind,
		bytes: Int,
		pageURL: String? = nil
	) -> AgentFileAttachment {
		let mediaType: String = switch kind {
		case .image: "image/png"
		case .pdf: "application/pdf"
		case .text: "text/plain"
		}
		return .init(
			id: UUID(99),
			name: name,
			kind: kind,
			mediaType: mediaType,
			data: Data(repeating: 1, count: min(bytes, 64)),
			byteCount: bytes,
			pageURL: pageURL
		)
	}
}
