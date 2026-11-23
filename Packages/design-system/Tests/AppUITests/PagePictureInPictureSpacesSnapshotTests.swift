import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Page PiP's header with the space picker, and the question before a move to another profile
/// (DEV-1184). The picker fits Page PiP's narrowest window as the profile picker did. With
/// `ARX_DESIGN_SNAPSHOTS` naming a directory, writes the headers and the questions in light and
/// dark.
@MainActor
@Suite(.renderTurn)
internal struct PagePictureInPictureSpacesSnapshotTests {
	private static let url: URL = .init(string: "https://www.example.com/watch/live")!
	private static let profile: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
	private static let spaces: [Space] = [
		.init(id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!), profileID: profile, name: "Home"),
		.init(id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!), profileID: profile, name: "Reading"),
		.init(
			id: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!),
			profileID: .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
			name: "Office"
		),
	]

	/// The header with the space picker is as tall as Little Arx's and fits Page PiP's narrowest
	/// window, 300 points.
	@Test
	internal func theHeaderFitsItsNarrowestWindow() async throws {
		let header = Self.header(current: 1)
		let fitting = NSHostingView(rootView: header.frame(width: 480)).fittingSize
		#expect(fitting.height == BrowserMetrics.LittleArx.toolbarHeight)
		let narrowest = NSHostingController(rootView: header)
			.sizeThatFits(in: .init(width: 1, height: BrowserMetrics.LittleArx.toolbarHeight))
		#expect(narrowest.width <= 300)
	}

	/// The options carry each space's shortcut and, for another profile's space, its profile.
	@Test
	internal func theOptionsNameTheShortcutsAndOtherProfiles() async throws {
		let options = Self.options
		expectEqual(options.map(\.shortcut), ["⌃1", "⌃2", "⌃3"])
		expectEqual(options.map(\.otherProfileName), [nil, nil, "Work"])
	}

	/// The question's words for one tab, several and a whole space.
	@Test
	internal func theQuestionSaysWhatHappens() async throws {
		let tab = ProfileMoveConfirmation.Content(subject: .tab, spaceName: "Office", profileName: "Work")
		expectEqual(tab.title, "Move this tab to “Office”?")
		expectEqual(
			tab.detail,
			"The page reloads in the Work profile. Its sign-ins don’t carry over, so you may need to sign in again."
		)
		let tabs = ProfileMoveConfirmation.Content(subject: .tabs(3), spaceName: "Office", profileName: "Work")
		expectEqual(tabs.title, "Move 3 tabs to “Office”?")
		expectEqual(
			tabs.detail,
			"The pages reload in the Work profile. Their sign-ins don’t carry over, so you may need to sign in again."
		)
	}

	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func headers(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"
		let headers = VStack(alignment: .leading, spacing: 12) {
			Text(verbatim: "Page PiP, 480 pt, space 2").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.header(current: 1), width: 480)
			Text(verbatim: "Page PiP, 300 pt, space 1").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.header(current: 0), width: 300)
			Text(verbatim: "Page PiP, 300 pt, space 12").font(.caption).foregroundStyle(.secondary)
			Self.window(Self.header(shortcut: "12"), width: 300)
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(headers, dark: dark, to: directory.appending(path: "page-pip-space-picker-\(appearance).png"))
	}

	@Test(
		.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil),
		arguments: [false, true]
	)
	internal func questions(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let appearance = dark ? "dark" : "light"
		let questions = VStack(alignment: .leading, spacing: 12) {
			Text(verbatim: "One tab, as a window's sheet").font(.caption).foregroundStyle(.secondary)
			Self.card(.init(subject: .tab, spaceName: "Office", profileName: "Work"))
			Text(verbatim: "Several tabs").font(.caption).foregroundStyle(.secondary)
			Self.card(.init(subject: .tabs(3), spaceName: "Office", profileName: "Work"))
			Text(verbatim: "A space").font(.caption).foregroundStyle(.secondary)
			Self.card(.init(subject: .space("Reading"), spaceName: "Reading", profileName: "Work"))
		}
		.padding(16)
		.background(Color.gray.opacity(0.3))
		try write(questions, dark: dark, to: directory.appending(path: "profile-move-question-\(appearance).png"))
	}

	// MARK: - Fixture

	private static var options: [PagePictureInPictureSpacePicker.Option] {
		PagePictureInPictureSpacePicker.Option.options(
			spaces: spaces,
			profiles: [
				.init(id: profile, name: "Personal"),
				.init(id: spaces[2].profileID, name: "Work"),
			],
			profileID: profile,
			shortcuts: []
		)
	}

	private static func header(current: Int) -> some View {
		header(options: options, current: spaces[current].id)
	}

	/// A space past the ninth, which shows its number.
	private static func header(shortcut: String) -> some View {
		var options = options
		options[0].shortcut = shortcut
		return header(options: options, current: spaces[0].id)
	}

	private static func header(
		options: [PagePictureInPictureSpacePicker.Option],
		current: Space.ID
	) -> some View {
		PagePictureInPictureHeader(
			url: url,
			isLoading: false,
			onReturnToTab: {},
			onBack: {},
			onForward: nil,
			onActivate: {},
			onCopy: {},
			profilePicker: {
				PagePictureInPictureSpacePicker(options: options, currentID: current, onSelect: { _ in })
			},
			dragArea: { Color.clear }
		)
	}

	/// The question as a sheet draws it: on the modal background.
	private static func card(_ content: ProfileMoveConfirmation.Content) -> some View {
		ProfileMoveConfirmation(content, onCancel: {}, onConfirm: {})
			.frame(width: ProfileMoveConfirmation.maximumWidth)
			.background(ArxModalMetrics.background)
			.clipShape(.rect(cornerRadius: 12, style: .continuous))
	}

	/// The header over the page card, as in the window.
	private static func window(
		_ header: some View,
		width: CGFloat
	) -> some View {
		ZStack {
			BrowserChromeBackground(textured: true)
			VStack(spacing: 0) {
				header
				Color.white
					.frame(height: 60)
					.browserPageCard(cornerRadius: BrowserMetrics.LittleArx.pageCornerRadius)
					.padding([.horizontal, .bottom], BrowserMetrics.LittleArx.pageInset)
			}
		}
		.frame(width: width)
		.clipShape(.rect(cornerRadius: BrowserMetrics.LittleArx.cornerRadius, style: .continuous))
	}

	private func write(
		_ view: some View,
		dark: Bool,
		to file: URL
	) throws {
		let host = NSHostingView(rootView: view.fixedSize())
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
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: file)
		window.close()
	}
}

private func expectEqual<Value: Equatable>(
	_ value: Value,
	_ expected: Value,
	sourceLocation: SourceLocation = #_sourceLocation
) {
	#expect(value == expected, sourceLocation: sourceLocation)
}
