import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// Writes offscreen PNGs of the identity card with and without a member number, with Member since
/// (DEV-1323), and of the Member number section in each state (DEV-701), light and dark, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory.
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil)
)
internal struct MemberNumberSnapshotTests {
	private static let number: MemberNumber = .init(index: 42, registeredOn: "2026-11-18", provider: .apple)
	private static let stats: ArxIdentityCard.Stats = .init(profiles: 2, spaces: 5, tabs: 38)
	/// 11 November 2026, noon UTC: the same month in every time zone.
	private static let installed: Date = .init(timeIntervalSince1970: 1_794_398_400)

	/// No member number: the corner is empty.
	@Test(arguments: [false, true])
	internal func cardsWithoutANumber(dark: Bool) throws {
		try write(cards(member: nil), name: "identity-cards-no-number", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func cardsWithANumber(dark: Bool) throws {
		try write(cards(member: Self.number), name: "identity-cards-number", dark: dark)
	}

	/// Every style with a number, to check the corner against each face's mark.
	@Test(arguments: [false, true])
	internal func everyStyleWithANumber(dark: Bool) throws {
		let view = LazyVGrid(columns: Array(repeating: GridItem(.fixed(ArxIdentityCard.size.width), spacing: 16), count: 6), spacing: 16) {
			ForEach(IdentityCardStyle.allCases, id: \.self) { style in
				ArxIdentityCard(style: style, stats: Self.stats, member: Self.number, memberSince: Self.installed, cycle: {})
			}
		}
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
		try write(view, name: "identity-cards-every-style", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func sectionStates(dark: Bool) throws {
		let states: [(MemberNumberSection.Status, [MemberSignInProvider])] = [
			(.notClaimed, [.apple]),
			(.notClaimed, []),
			(.signingIn(.apple), [.apple]),
			(.claimed(Self.number), [.apple]),
			(.failed(.offline), [.apple]),
			(.failed(.cancelled), [.apple]),
			(.failed(.refused), [.apple]),
		]
		let view = VStack(alignment: .leading, spacing: 18) {
			ForEach(Array(states.enumerated()), id: \.offset) { _, state in
				MemberNumberSection(status: state.0, providers: state.1, claim: { _ in })
			}
		}

		// The column beside the identity card in Settings › Arx.
		.frame(width: 345)
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
		try write(view, name: "member-section", dark: dark)
	}

	private func cards(member: MemberNumber?) -> some View {
		HStack(alignment: .top, spacing: 16) {
			ForEach([IdentityCardStyle.memberPass, .holographicFoil, .graphite, .sunsetGrain], id: \.self) { style in
				ArxIdentityCard(style: style, stats: Self.stats, member: member, memberSince: Self.installed, cycle: {})
			}
		}
		.padding(20)
		.background(Color(nsColor: .windowBackgroundColor))
	}

	private func write(
		_ view: some View,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let host = NSHostingView(rootView: view.fixedSize().environment(\.locale, Locale(identifier: "en_US")))
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
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
