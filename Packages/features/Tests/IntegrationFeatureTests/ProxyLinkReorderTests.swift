import CoreGraphics
import CustomDump
import Foundation
import SwiftUI
import Testing

@testable import SettingsFeature

/// DEV-1113: a Proxy Links rule dragged by its handle drops past every other row whose middle the
/// pointer passed.
internal struct ProxyLinkReorderTests {
	private let ids: [UUID] = [UUID(), UUID(), UUID()]

	/// Three rows of 40 points, one under another.
	private let frames: [CGRect] = (0..<3).map { CGRect(x: 0, y: CGFloat($0) * 40, width: 300, height: 40) }

	@Test
	internal func theSlotFollowsThePointerPastRowMiddles() async throws {
		var drag = try #require(RuleDrag(id: ids[0], in: ids, frames: frames))
		expectNoDifference(drag.slot, 0)
		drag.track(y: 59)
		expectNoDifference(drag.slot, 0)
		drag.track(y: 61)
		expectNoDifference(drag.slot, 1)
		drag.track(y: 500)
		expectNoDifference(drag.slot, 2)
		drag.track(y: -20)
		expectNoDifference(drag.slot, 0)
	}

	@Test
	internal func aRowMovesUpPastTheMiddleOfTheRowAbove() async throws {
		var drag = try #require(RuleDrag(id: ids[2], in: ids, frames: frames))
		expectNoDifference(drag.slot, 2)
		drag.track(y: 61)
		expectNoDifference(drag.slot, 2)
		drag.track(y: 59)
		expectNoDifference(drag.slot, 1)
		drag.track(y: 19)
		expectNoDifference(drag.slot, 0)
	}

	/// Codex: another Mac removed the middle rule while the first was dragged to the end. The drop
	/// still lands last, where the preview showed it.
	@Test
	internal func aDropAfterSyncShortenedTheListLandsWhereItShowed() async throws {
		var drag = try #require(RuleDrag(id: ids[0], in: ids, frames: frames))
		drag.track(y: 500)
		expectNoDifference(drag.destination(in: ids), 2)
		expectNoDifference(drag.destination(in: [ids[0], ids[2]]), 1)
		expectNoDifference(drag.destination(in: [ids[2], ids[0]]), nil)
		expectNoDifference(drag.destination(in: [ids[1], ids[2]]), nil)
		drag.track(y: -20)
		expectNoDifference(drag.destination(in: ids), nil)
	}

	@Test
	internal func anUnknownRuleOrMissingFramesStartNoDrag() async throws {
		#expect(RuleDrag(id: UUID(), in: ids, frames: frames) == nil)
		#expect(RuleDrag(id: ids[0], in: ids, frames: []) == nil)
	}
}

/// DEV-1163: a focused rule moves one place with ⌥⌘↑ or ⌥⌘↓, and its menu and VoiceOver offer
/// Move Up and Move Down only where it can go.
internal struct ProxyLinkKeyboardMoveTests {
	@Test
	internal func optionCommandArrowsMoveTheRule() async throws {
		#expect(RuleMove(key: .upArrow, modifiers: [.option, .command]) == .up)
		#expect(RuleMove(key: .downArrow, modifiers: [.option, .command]) == .down)
		// An arrow key also carries the numeric pad and function flags.
		#expect(RuleMove(key: .downArrow, modifiers: [.option, .command, .numericPad, .function]) == .down)
		// Plain arrows and other combinations leave the focus moving as it does.
		#expect(RuleMove(key: .upArrow, modifiers: []) == nil)
		#expect(RuleMove(key: .upArrow, modifiers: [.command]) == nil)
		#expect(RuleMove(key: .upArrow, modifiers: [.option, .command, .shift]) == nil)
		#expect(RuleMove(key: .leftArrow, modifiers: [.option, .command]) == nil)
	}

	@Test
	internal func aRuleMovesOnePlaceAndNotPastEitherEnd() async throws {
		expectNoDifference(RuleMove.up.destination(from: 1, among: 3), 0)
		expectNoDifference(RuleMove.down.destination(from: 1, among: 3), 2)
		expectNoDifference(RuleMove.up.destination(from: 0, among: 3), nil)
		expectNoDifference(RuleMove.down.destination(from: 2, among: 3), nil)
		expectNoDifference(RuleMove.down.destination(from: 0, among: 1), nil)

		// A row whose rule sync took away moves nowhere.
		expectNoDifference(RuleMove.up.destination(from: 3, among: 3), nil)
	}
}
