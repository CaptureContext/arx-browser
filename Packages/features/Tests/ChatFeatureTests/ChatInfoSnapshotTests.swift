import AgentClient
import AppKit
import AppUI
import Foundation
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import ChatFeature

/// Offscreen PNGs of chat info (DEV-799) for visual self-review, when `ARX_DESIGN_SNAPSHOTS`
/// names a directory: a pinned chat and a temporary one, light and dark.
@MainActor
@Suite(.dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ChatInfoSnapshotTests {
	internal enum Scenario: String, CaseIterable, Sendable {
		case pinned
		case temporary
	}

	@Test(arguments: Scenario.allCases)
	internal func info(scenario: Scenario) throws {
		for dark in [false, true] {
			let store = Store(initialState: Self.state(scenario)) {
				EmptyReducer<ChatFeature.State, ChatFeature.Action>()
			}
			let view = ZStack {
				BrowserChromeBackground(textured: true)
				ChatPanelView(store: store, attachables: [], onHide: {})
					.frame(width: ChatMetrics.panelWidth)
					.padding(16)
			}
			try Self.write(
				view,
				size: .init(width: ChatMetrics.panelWidth + 32, height: 620),
				dark: dark,
				name: "chat-info-\(scenario.rawValue)-\(dark ? "dark" : "light").png"
			)
		}
	}

	// MARK: - Fixtures

	private static func state(_ scenario: Scenario) -> ChatFeature.State {
		let now = Date.now
		let conversation = AgentConversation(
			id: .init(rawValue: UUID(7)),
			profileID: ChatWorld.profileID,
			provider: .claude,
			title: scenario == .pinned ? "Plan a weekend in Lisbon" : "Hello",
			createdAt: now,
			updatedAt: now,
			retention: scenario == .pinned ? .persistent : .ephemeral,
			messages: [
				.init(id: UUID(1), role: .user, text: "Hello", createdAt: now),
				.init(id: UUID(2), role: .assistant, text: "Hi! How can I help?", createdAt: now),
			]
		)
		return .init(
			id: ChatWorld.profileID,
			isLoaded: true,
			conversations: [conversation],
			selectedID: conversation.id,
			screen: .info,
			browserAccess: .granted
		)
	}

	private static func write(
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
