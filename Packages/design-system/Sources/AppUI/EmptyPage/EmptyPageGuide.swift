import BrowserCore
import SwiftUI

// MARK: - Hints

/// Which tip shows: the one picked last and when, after which they roll on by themselves.
internal struct EmptyPageHintCursor: Equatable {
	internal var index: Int = 0
	internal var since: Double = 0

	/// The tip showing at `time`, and how far through its turn it is, 0 to 1.
	internal func position(
		at time: Double,
		count: Int
	) -> (index: Int, phase: Double) {
		guard count > 0 else { return (0, 0) }

		let turns: Double = max(0, time - since) / EmptyPageHints.duration
		let passed: Double = turns.rounded(.down)
		return (Self.wrap(index + Int(passed), count: count), turns - passed)
	}

	/// Moves to the next tip, or the previous one, and gives it a whole turn.
	internal mutating func step(
		by offset: Int,
		at time: Double,
		count: Int
	) {
		guard count > 0 else { return }

		index = Self.wrap(position(at: time, count: count).index + offset, count: count)
		since = time
	}

	private static func wrap(_ index: Int, count: Int) -> Int {
		(index % count + count) % count
	}
}

/// One tip at a time: it fades in, stays its turn, and fades out, with a thin bar showing how
/// long it has left.
internal struct EmptyPageRollingHint: View {
	private static let fade: Double = 0.6

	internal let texts: [String]
	internal let time: Double
	internal let cursor: EmptyPageHintCursor
	internal var alignment: HorizontalAlignment = .center

	@Environment(\.emptyPageIsMoving)
	private var isMoving

	internal var body: some View {
		let position: (index: Int, phase: Double) = cursor.position(at: time, count: texts.count)
		let elapsed: Double = position.phase * EmptyPageHints.duration

		// Held still, a tip shows in full: a frame caught mid-fade would hide it.
		let visibility: Double = isMoving
		? min(min(elapsed / Self.fade, (EmptyPageHints.duration - elapsed) / Self.fade), 1)
		: 1
		let leading: Bool = alignment == .leading
		if !texts.isEmpty {
			VStack(alignment: alignment, spacing: 10) {
				Text(String.localized(.appUI.emptyPage.tipNumber(position.index + 1, texts.count)).uppercased())
					.font(.system(size: 10, weight: .semibold))
					.tracking(1.4)
					.foregroundStyle(BrowserTheme.secondary)
				Text(texts[position.index])
					.font(.system(size: 13))
					.foregroundStyle(BrowserTheme.text.opacity(0.7))
					.multilineTextAlignment(leading ? .leading : .center)
					.frame(width: 340, alignment: leading ? .leading : .center)
					.fixedSize(horizontal: false, vertical: true)
					.opacity(visibility)
					.offset(y: (1 - visibility) * 4)
				Capsule()
					.fill(BrowserTheme.text.opacity(0.08))
					.frame(width: 120, height: 2)
					.overlay(alignment: .leading) {
						Capsule()
							.fill(BrowserTheme.secondary)
							.frame(width: 120 * position.phase, height: 2)
					}
			}
			.frame(height: 96, alignment: leading ? .bottomLeading : .top)
			.accessibilityElement(children: .combine)
		}
	}
}

// MARK: - Shortcuts

/// The commands that open a page, with the person's keys for each.
internal struct EmptyPageShortcuts: View {
	private static let commands: [BrowserCommand] = [.newTab, .address, .commandBar, .toggleSidebar, .reopenLastClosedTab]

	internal let bindings: [ShortcutBinding]

	internal var body: some View {
		VStack(spacing: 10) {
			ForEach(Self.commands, id: \.self) { command in
				if let shortcut = bindings.shortcut(for: command) {
					HStack(spacing: 8) {
						Text(command.title)
							.foregroundStyle(BrowserTheme.secondary)
						Spacer(minLength: 16)
						Text(shortcut.display)
							.font(.system(size: 11, weight: .medium, design: .rounded))
							.foregroundStyle(BrowserTheme.secondary)
							.padding(.horizontal, 6)
							.padding(.vertical, 2)
							.background(BrowserTheme.fill, in: .rect(cornerRadius: 5, style: .continuous))
					}
					.font(.system(size: 12))
				}
			}
		}
		.frame(width: 240)
	}
}
