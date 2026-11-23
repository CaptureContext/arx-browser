#if DEBUG
import AppKit
@testable import AppFeature
import Foundation
import Testing

/// The judgements `make hand-check-smoke` makes, without a window: which phases run, what
/// counts as a refocused find field, a full-screen inset moving in step, a caret in view and a
/// remembered folder.
@MainActor
@Suite
internal struct HandCheckSmokeTests {
	@Test
	func phasesComeFromTheEnvironmentInCatalogOrder() {
		#expect(HandCheckSmoke.phases(environment: [:]) == nil)
		#expect(HandCheckSmoke.phases(environment: ["ARX_HAND_CHECK_SMOKE": ""]) == nil)
		#expect(HandCheckSmoke.phases(environment: ["ARX_HAND_CHECK_SMOKE": "1"]) == HandCheckSmoke.Phase.allCases)
		#expect(HandCheckSmoke.phases(environment: ["ARX_HAND_CHECK_SMOKE": "all"]) == HandCheckSmoke.Phase.allCases)
		#expect(
			HandCheckSmoke.phases(environment: ["ARX_HAND_CHECK_SMOKE": "private-save, find,find"])
			== [.find, .privateSave]
		)
		#expect(HandCheckSmoke.phases(environment: ["ARX_HAND_CHECK_SMOKE": "find,everything"]) == nil)
	}

	@Test
	func successMarkersMatchTheRunner() {
		// `phase_marker` in Scripts/hand_check_smoke.py.
		#expect(HandCheckSmoke.Phase.allCases.map(\.successMarker) == [
			"ARX_HAND_CHECK_FIND_SUCCESS",
			"ARX_HAND_CHECK_FULL_SCREEN_SUCCESS",
			"ARX_HAND_CHECK_ADDRESS_SUCCESS",
			"ARX_HAND_CHECK_PRIVATE_SAVE_SUCCESS",
			"ARX_HAND_CHECK_HIDE_ELEMENT_TOAST_SUCCESS",
		])
	}

	@Test
	func findCountsOnlyTheWholeQuerySelected() {
		let query = FindFocusSmoke.query
		#expect(FindFocusSmoke.selectsWholeQuery(text: query, selection: NSRange(location: 0, length: 3), query: query))
		// A caret after the query: focused, but the next key wouldn't replace it.
		#expect(!FindFocusSmoke.selectsWholeQuery(text: query, selection: NSRange(location: 3, length: 0), query: query))
		#expect(!FindFocusSmoke.selectsWholeQuery(text: query + "x", selection: NSRange(location: 0, length: 4), query: query))
	}

	@Test
	func fullScreenInsetsAreTheToolbarsMetrics() {
		#expect(WindowFullScreenSmoke.Inset.windowed == 78)
		#expect(WindowFullScreenSmoke.Inset.fullScreen == 12)
	}

	@Test
	func anInsetMovingDuringTheTransitionIsInStep() {
		let samples: [WindowFullScreenSmoke.Sample] = [
			.init(time: 0.00, inset: 78),
			.init(time: 0.05, inset: 70),
			.init(time: 0.20, inset: 40),
			.init(time: 0.45, inset: 13),
			.init(time: 0.70, inset: 12),
		]
		let motion = WindowFullScreenSmoke.Motion(samples: samples, from: 78, to: 12)
		#expect(motion.started == 0.05)
		// 13 is within the tolerance of its resting place.
		#expect(motion.steps == 2)
		#expect(motion.isInStep(began: 0, finished: 0.6, end: 12))
		// The transition ended before the inset moved: it caught up afterwards, out of step.
		#expect(!motion.isInStep(began: 0, finished: 0.04, end: 12))
		// Moving before the transition began isn't following it either.
		#expect(!motion.isInStep(began: 0.1, finished: 0.6, end: 12))
	}

	@Test
	func anInsetThatNeverMovesOrStopsShortIsNotInStep() {
		let still = WindowFullScreenSmoke.Motion(
			samples: [.init(time: 0, inset: 78), .init(time: 0.5, inset: 78)],
			from: 78,
			to: 12
		)
		#expect(still.started == nil)
		#expect(!still.isInStep(began: 0, finished: 0.6, end: 12))

		let short = WindowFullScreenSmoke.Motion(
			samples: [.init(time: 0, inset: 78), .init(time: 0.2, inset: 40)],
			from: 78,
			to: 12
		)
		#expect(!short.isInStep(began: 0, finished: 0.6, end: 12))
	}

	@Test
	func theCaretCountsWhenItsInsideTheField() {
		let field = NSRect(x: 100, y: 0, width: 400, height: 30)
		#expect(AddressFieldSmoke.caretIsVisible(caret: NSRect(x: 499, y: 4, width: 1, height: 20), visible: field))
		#expect(AddressFieldSmoke.caretIsVisible(caret: NSRect(x: 100, y: 4, width: 1, height: 20), visible: field))
		// At the text's end, in the field's inset: as AppKit draws it.
		#expect(AddressFieldSmoke.caretIsVisible(caret: NSRect(x: 502, y: 4, width: 0, height: 20), visible: field))
		// Scrolled past the field's end, as an unscrolled field editor leaves it.
		#expect(!AddressFieldSmoke.caretIsVisible(caret: NSRect(x: 1_400, y: 4, width: 1, height: 20), visible: field))
	}

	@Test
	func theLongAddressIsOnTheFixtureAndLong() throws {
		let base = try #require(URL(string: "http://127.0.0.1:8123/index.html"))
		let address = AddressFieldSmoke.longAddress(baseURL: base)
		#expect(address.host() == "127.0.0.1")
		#expect(address.port == 8123)
		#expect(address.path().hasPrefix("/address/"))
		#expect(address.absoluteString.count > 300)
	}

	@Test
	func theAddressIsTypedInTwoPartsAndOnlyAnUntypedRestIsACompletion() throws {
		let base = try #require(URL(string: "http://127.0.0.1:8123/index.html"))
		let typed = AddressFieldSmoke.longAddress(baseURL: base).absoluteString
		let prefix = AddressFieldSmoke.completionPrefix(of: typed)
		#expect(typed.hasPrefix(prefix))
		#expect(prefix.count < typed.count)
		#expect(prefix.hasSuffix("long-address-segment-6/"))
		let remainder = String(typed.dropFirst(prefix.count))

		// The rest drawn after the field's text, or in the field.
		#expect(AddressFieldSmoke.showsCompletion(remainder, remainder: remainder))
		#expect(AddressFieldSmoke.showsCompletion(prefix + remainder.prefix(30), remainder: remainder) == false)
		#expect(AddressFieldSmoke.showsCompletion(String(remainder.prefix(30)), remainder: remainder))
		// A suggestion row shows the whole address.
		#expect(!AddressFieldSmoke.showsCompletion(typed, remainder: remainder))
		#expect(!AddressFieldSmoke.showsCompletion("Arx long address", remainder: remainder))
	}

	@Test
	func thePDFDigestIsTheRunnersFormat() {
		// hashlib.sha256(b"abc").hexdigest() in the runner.
		#expect(PrivateSaveSmoke.digest(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	}

	@Test
	func aBookmarkOfThePrivateFolderOrInsideItIsRemembered() throws {
		let root = FileManager.default.temporaryDirectory.appending(path: "hand-check-\(UUID().uuidString)")
		let folder = root.appending(path: "arx-private-save-test", directoryHint: .isDirectory)
		let inside = folder.appending(path: "nested", directoryHint: .isDirectory)
		let elsewhere = root.appending(path: "elsewhere", directoryHint: .isDirectory)
		for directory in [inside, elsewhere] {
			try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		}
		defer { try? FileManager.default.removeItem(at: root) }

		#expect(PrivateSaveSmoke.remembers(folder, bookmark: try folder.bookmarkData()))
		#expect(PrivateSaveSmoke.remembers(folder, bookmark: try inside.bookmarkData()))
		#expect(!PrivateSaveSmoke.remembers(folder, bookmark: try elsewhere.bookmarkData()))
		#expect(!PrivateSaveSmoke.remembers(folder, bookmark: nil))
	}
}
#endif
