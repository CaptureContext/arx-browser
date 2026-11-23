import AgentClient
import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import ChatFeature

/// Offscreen PNGs of the chat panel for visual self-review, when `ARX_DESIGN_SNAPSHOTS` names a
/// directory: a new chat, a short answer, a long one with tool activity, a failure, Your Chats,
/// and each placement.
@MainActor
@Suite(.dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ChatPanelSnapshotTests {
	internal enum Scenario: String, CaseIterable, Sendable {
		case new
		case short
		case long
		case failure
		case chats
	}

	@Test(arguments: Scenario.allCases)
	internal func panel(scenario: Scenario) throws {
		for dark in [false, true] {
			let store = Store(initialState: Self.state(scenario)) {
				EmptyReducer<ChatFeature.State, ChatFeature.Action>()
			}
			let view = ZStack {
				BrowserChromeBackground(textured: true)
				ChatPanelView(store: store, attachables: Self.attachables, onHide: {})
					.frame(width: ChatMetrics.panelWidth)
					.padding(16)
			}
			try Self.write(
				view,
				size: .init(width: 392, height: 760),
				dark: dark,
				name: "chat-\(scenario.rawValue)-\(dark ? "dark" : "light").png"
			)
		}
	}

	/// Where a chat shows (DEV-761): the window's panel, a panel pinned to a tab with its pin
	/// in the header, and a chat tab at a pane's width without ×.
	internal enum Placement: String, CaseIterable, Sendable {
		case panel
		case pinned
		case tab
	}

	@Test(arguments: Placement.allCases)
	internal func placement(_ placement: Placement) throws {
		for dark in [false, true] {
			let store = Store(initialState: Self.state(.short)) {
				EmptyReducer<ChatFeature.State, ChatFeature.Action>()
			}
			let chatPlacement: ChatPlacement = switch placement {
			case .panel: .init(kind: .panel, pinToTab: { _ in }, openInTab: { _ in })
			case .pinned: .init(kind: .pinned, unpin: {}, openInTab: { _ in })
			case .tab: .init(kind: .tab, moveToSidebar: { _ in })
			}
			let width: CGFloat = placement == .tab ? 760 : ChatMetrics.panelWidth
			let view = ZStack {
				BrowserChromeBackground(textured: true)
				ChatPanelView(store: store, attachables: Self.attachables, placement: chatPlacement, onHide: {})
					.frame(width: width)
					.padding(16)
			}
			try Self.write(
				view,
				size: .init(width: width + 32, height: 520),
				dark: dark,
				name: "chat-placement-\(placement.rawValue)-\(dark ? "dark" : "light").png"
			)
		}
	}

	/// The composer (DEV-798): one line, several lines, and with a tab, an image and a file
	/// attached; then a chat tab wider than the readable width, with its transcript and
	/// composer capped and centered.
	internal enum Composer: String, CaseIterable, Sendable {
		case singleLine
		case multiLine
		case attachments
		case wide
	}

	@Test(arguments: Composer.allCases)
	internal func composer(_ composer: Composer) throws {
		for dark in [false, true] {
			var state: ChatFeature.State = Self.state(composer == .wide ? .long : .new)
			switch composer {
			case .singleLine:
				state.draft = "What's the pricing for teams?"

			case .multiLine:
				state.draft = "Compare these plans:\n- Pro\n- Team\n- Enterprise\nWhich one fits a team of eight?"

			case .attachments:
				state.draft = "What's different in this screenshot?"
				state.attachments = [
					.tabs([.init(title: "Raycast for iOS", url: "https://www.raycast.com/ios")]),
					.file(.init(
						id: UUID(60),
						name: "Pricing.png",
						kind: .image,
						mediaType: "image/png",
						data: Data(),
						byteCount: 120_000,
						preview: Self.preview()
					)),
					.file(.init(id: UUID(61), name: "notes.md", kind: .text, mediaType: "text/markdown", data: Data("# Notes".utf8))),
				]
				state.attachmentIssue = .unsupported(name: "Archive.zip")

			case .wide:
				state.draft = "Thanks!"
			}
			let store = Store(initialState: state) {
				EmptyReducer<ChatFeature.State, ChatFeature.Action>()
			}
			let width: CGFloat = composer == .wide ? 1_200 : ChatMetrics.panelWidth
			let placement: ChatPlacement = composer == .wide
			? .init(kind: .tab, moveToSidebar: { _ in })
			: .init(kind: .panel, capture: { _ in })
			let view = ZStack {
				BrowserChromeBackground(textured: true)
				ChatPanelView(store: store, attachables: Self.attachables, placement: placement, onHide: {})
					.frame(width: width)
					.padding(16)
			}
			try Self.write(
				view,
				size: .init(width: width + 32, height: composer == .wide ? 640 : 560),
				dark: dark,
				name: "chat-composer-\(composer.rawValue)-\(dark ? "dark" : "light").png"
			)
		}
	}

	/// A small gradient PNG standing in for a captured page.
	private static func preview() -> Data {
		let image = NSImage(size: .init(width: 80, height: 60), flipped: false) { rect in
			NSGradient(colors: [.systemBlue, .systemTeal])?.draw(in: rect, angle: 45)
			NSColor.white.setFill()
			NSBezierPath(roundedRect: rect.insetBy(dx: 14, dy: 18), xRadius: 4, yRadius: 4).fill()
			return true
		}
		let tiff = image.tiffRepresentation ?? Data()
		return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) ?? Data()
	}

	// MARK: - Fixtures

	private static let conversationID: AgentConversation.ID = .init(rawValue: UUID(7))

	/// The window's tab, which a new chat's suggestions are about.
	private static let attachables: [ChatAttachable] = [
		.init(
			id: ChatAttachable.currentID,
			title: "Raycast for iOS",
			symbol: "macwindow",
			tabs: [.init(title: "Raycast for iOS", url: "https://www.raycast.com/ios")]
		),
	]

	private static func state(_ scenario: Scenario) -> ChatFeature.State {
		let now = Date.now
		var messages: [AgentMessage] = []
		var turns: [AgentConversation.ID: ChatTurn] = [:]
		var failures: [AgentConversation.ID: ChatFailure] = [:]
		switch scenario {
		case .new:
			return .init(
				id: ChatWorld.profileID,
				isLoaded: true,
				conversations: Self.history(now: now),
				browserAccess: .granted
			)

		case .chats:
			var state = ChatFeature.State(
				id: ChatWorld.profileID,
				isLoaded: true,
				conversations: Self.history(now: now),
				selectedID: Self.history(now: now)[1].id,
				screen: .chats,
				turns: [Self.history(now: now)[0].id: .init(prompt: "Plan", attachments: [], promptID: UUID(90), replyID: UUID(91))],
				unreadIDs: [Self.history(now: now)[2].id],
				browserAccess: .granted
			)
			state.failures[Self.history(now: now)[3].id] = .init(
				reason: .interrupted,
				prompt: "Again",
				attachments: [],
				promptID: UUID(92)
			)
			return state

		case .short:
			messages = [
				.init(id: UUID(1), role: .user, text: "hey", createdAt: now),
				.init(
					id: UUID(2),
					role: .assistant,
					text: "Hey! What can I help you with — a question about a page, Arx itself, or something else?",
					createdAt: now
				),
			]

		case .long:
			let tab = AgentContextAttachment.Tab(title: "Raycast for iOS", url: "https://www.raycast.com/ios")
			messages = [
				.init(id: UUID(1), role: .user, text: "What's on this page?", attachments: [.tabs([tab])], createdAt: now),
				.init(
					id: UUID(2),
					role: .assistant,
					text: """
					## Raycast for iOS
					The page introduces Raycast's **iPhone app**. It covers:
					- AI chat with the same models as on the Mac
					- Notes that sync through iCloud
					- Quick links and snippets

					Pricing is in the `Pro` plan. Sign in with your Raycast account to sync.
					""",
					tools: [
						.init(id: "t1", name: "browser_page_snapshot", input: "{}"),
						.init(id: "t2", name: "browser_find_text", input: "{}"),
					],
					createdAt: now
				),
				.init(id: UUID(3), role: .user, text: "Compare it with the Mac app and open the pricing page", createdAt: now),
				.init(
					id: UUID(4),
					role: .assistant,
					text: "Looking at the pricing page now…",
					tools: [
						.init(id: "t3", name: "browser_open_tab", input: "{}"),
						.init(id: "t4", name: "browser_click", input: "{}"),
						.init(id: "t5", name: "browser_page_snapshot", input: "{}"),
					],
					createdAt: now
				),
			]
			turns[conversationID] = .init(
				prompt: "Compare it with the Mac app and open the pricing page",
				attachments: [],
				promptID: UUID(3),
				replyID: UUID(4),
				runningTools: ["t5"],
				failedTools: ["t4"]
			)

		case .failure:
			messages = [
				.init(id: UUID(1), role: .user, text: "Summarize my open tabs", createdAt: now),
				.init(
					id: UUID(2),
					role: .assistant,
					text: "You have three tabs open: a pricing page, a GitHub pull request and the Arx manual.",
					tools: [.init(id: "t1", name: "browser_tabs", input: "{}")],
					createdAt: now
				),
				.init(id: UUID(3), role: .user, text: "And the archived ones?", createdAt: now),
			]

			// The failed prompt stays in the transcript, with the failure under it (DEV-643).
			failures[conversationID] = .init(
				reason: .loginExpired,
				prompt: "And the archived ones?",
				attachments: [],
				promptID: UUID(3)
			)
		}
		let conversation = AgentConversation(
			id: conversationID,
			profileID: ChatWorld.profileID,
			provider: .claude,
			title: scenario == .short ? "hey" : "What's on this page?",
			createdAt: now,
			updatedAt: now,
			messages: messages
		)
		return .init(
			id: ChatWorld.profileID,
			isLoaded: true,
			conversations: [conversation],
			selectedID: conversation.id,
			turns: turns,
			failures: failures,
			browserAccess: .granted
		)
	}

	/// Chats over the past weeks for Your Chats and a new chat's recents.
	private static func history(now: Date) -> IdentifiedArrayOf<AgentConversation> {
		let day: TimeInterval = 24 * 60 * 60
		let chats: [(String, String, TimeInterval, Int, AgentRetention)] = [
			("Plan a weekend in Lisbon", "Here's a two-day plan with the tram 28 route…", 600, 3, .persistent),
			("What's on this page?", "The page introduces Raycast's iPhone app.", 3_600, 2, .ephemeral),
			("Compare M4 MacBook Air prices", "The best price is at the Apple Store education…", day + 600, 4, .persistent),
			("Summarize my open tabs", "You have three tabs open: a pricing page…", day + 7_200, 1, .persistent),
			("Translate the menu into English", "Here's the menu in English…", 3 * day, 0, .persistent),
			("Explain SwiftUI focus state", "FocusState tracks which view has focus…", 12 * day, 0, .persistent),
		]
		return IdentifiedArray(uniqueElements: chats.enumerated().map { index, chat in
			let (title, answer, age, tools, retention) = chat
			let date = now.addingTimeInterval(-age)
			return AgentConversation(
				id: .init(rawValue: UUID(100 + index)),
				profileID: ChatWorld.profileID,
				provider: index == 4 ? .openAI : .claude,
				title: title,
				createdAt: date,
				updatedAt: date,
				retention: retention,
				messages: [
					.init(id: UUID(200 + index * 2), role: .user, text: title, createdAt: date),
					.init(
						id: UUID(201 + index * 2),
						role: .assistant,
						text: answer,
						tools: (0..<tools).map { .init(id: "h\(index)-\($0)", name: "browser_page_snapshot", input: "{}") },
						createdAt: date
					),
				]
			)
		})
	}

	internal static func write(
		_ view: some View,
		size: CGSize,
		dark: Bool,
		name: String
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = CGRect(origin: .zero, size: size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: name))
		window.close()
	}
}
