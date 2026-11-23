import AppKit
@testable import AppUI
import BrowserCore
import SwiftUI
import Testing

/// DEV-1109: swiping past the last space shows a + bubble and, pulled far enough, opens the
/// Create a Space page after it; a short pull rubber-bands back as before, and Cancel or a swipe
/// back returns to the last space.
@Suite
internal struct SidebarSpaceCreationTrackTests {
	/// Three spaces, on the last one, 300 points wide: a point of finger travel past the last space
	/// moves the track 0.3 / 300 of a unit.
	private func track(
		spaceIndex: Int = 2,
		pageCount: Int = 3,
		hasLibrary: Bool = true,
		offersCreation: Bool = true
	) -> SidebarTrack {
		.init(
			spaceIndex: spaceIndex,
			pageCount: pageCount,
			pageWidth: 300,
			libraryWidth: 400,
			hasLibrary: hasLibrary,
			offersCreation: offersCreation
		)
	}

	/// Lets the spring run out.
	private func settle(_ track: inout SidebarTrack) {
		var time: TimeInterval = 100
		while track.advance(to: time) { time += 1 / 120 }
	}

	@Test
	internal func aShortPullSnapsBackWithNoPage() {
		var track = track()
		let began = track.begin(deltaX: -4, deltaY: 0)
		#expect(began)
		track.move(by: -40, at: 1)

		// 40 points of fingers are 20 of the track, which gives 0.043 of a unit toward the page:
		// a third of the way to opening it.
		#expect(abs(track.creationPull - 0.361) < 0.01)
		// Released after resting, so nothing carries it on.
		let snapsBack = track.release(at: 2) == .space(2)
		#expect(snapsBack)
		settle(&track)
		#expect(track.position == 2)
		#expect(!track.isCreationOpen)
	}

	@Test
	internal func aPullPastTheThresholdOpensThePage() {
		var track = track()
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -150, at: 1)
		#expect(track.creationPull >= 1)
		let stop = track.release(at: 2)
		#expect(stop == .creation)
		#expect(track.isCreationOpen)
		settle(&track)
		#expect(track.position == track.creationPosition)
		#expect(track.isCreationOpen)
		// Open, the page is the last stop: swiping on only rubber-bands.
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -1_000, at: 3)
		#expect(track.position <= track.creationPosition + 0.25)
		#expect(track.creationPull == 0)
	}

	/// A quick pull that lets go short of the threshold, still heading past it, opens the page; the
	/// same distance let go after resting doesn't.
	@Test
	internal func aQuickPullCarriesPastTheThreshold() {
		var quick = track()
		_ = quick.begin(deltaX: -4, deltaY: 0)
		quick.move(by: -30, at: 1)
		quick.move(by: -30, at: 1.01)
		#expect(quick.creationPull < 1)
		let quickStop = quick.release(at: 1.02)
		#expect(quickStop == .creation)

		var slow = track()
		_ = slow.begin(deltaX: -4, deltaY: 0)
		slow.move(by: -30, at: 1)
		slow.move(by: -30, at: 1.01)
		let slowSnapsBack = slow.release(at: 2) == .space(2)
		#expect(slowSnapsBack)
	}

	/// Armed, as the bubble shows, a pull opens the page even if the fingers eased back a little
	/// before lifting.
	@Test
	internal func anArmedPullOpensWhateverTheLastMovement() {
		var track = track()
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -200, at: 1)
		track.move(by: 10, at: 1.01)
		#expect(track.creationPull >= 1)
		let stop = track.release(at: 1.015)
		#expect(stop == .creation)
	}

	@Test
	internal func cancelAndASwipeBackReturnToTheLastSpace() {
		var cancelled = track()
		_ = cancelled.begin(deltaX: -4, deltaY: 0)
		cancelled.move(by: -150, at: 1)
		_ = cancelled.release(at: 2)
		settle(&cancelled)
		cancelled.closeCreation(at: 200)

		// The page stays a stop while the track leaves it, so it slides away whole.
		#expect(cancelled.isCreationOpen)
		settle(&cancelled)
		#expect(cancelled.position == 2)
		#expect(!cancelled.isCreationOpen)

		var swiped = track()
		_ = swiped.begin(deltaX: -4, deltaY: 0)
		swiped.move(by: -150, at: 1)
		_ = swiped.release(at: 2)
		settle(&swiped)
		let beganBack = swiped.begin(deltaX: 4, deltaY: 0)
		#expect(beganBack)
		// Still moving back as the fingers lift, which is enough, however short the swipe.
		swiped.move(by: 100, at: 300)
		swiped.move(by: 100, at: 300.008)
		let returns = swiped.release(at: 300.01) == .space(2)
		#expect(returns)
		settle(&swiped)
		#expect(!swiped.isCreationOpen)
	}

	/// The space made from the page takes its place, so nothing moves; one added elsewhere
	/// meanwhile, as from another window, leaves the page on screen after it.
	@Test
	internal func aNewSpaceTakesThePagesPlace() {
		var track = track()
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -150, at: 1)
		_ = track.release(at: 2)
		settle(&track)
		track.setPageCount(4, submittedCreation: true)
		#expect(!track.isCreationOpen)
		#expect(track.position == 3)
		#expect(track.creationPull == 0)

		var elsewhere = self.track()
		_ = elsewhere.begin(deltaX: -4, deltaY: 0)
		elsewhere.move(by: -150, at: 1)
		_ = elsewhere.release(at: 2)
		settle(&elsewhere)
		elsewhere.setPageCount(4)
		#expect(elsewhere.isCreationOpen)
		#expect(elsewhere.position == elsewhere.creationPosition)
		#expect(elsewhere.position == 4)
	}

	/// Spaces reordered elsewhere while the page is open leave it where it is, after them all.
	@Test
	internal func aReorderLeavesThePageInPlace() {
		var track = track()
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -150, at: 1)
		_ = track.release(at: 2)
		settle(&track)
		track.shift(by: -1)
		#expect(track.position == track.creationPosition)
		#expect(track.isCreationOpen)
	}

	@Test
	internal func aWheelPastTheLastSpaceStepsOntoThePage() {
		var track = track()
		let stop = track.wheel(by: -40, at: 1)
		#expect(stop == .creation)
		#expect(track.isCreationOpen)
	}

	/// Not offered, as in a private window, the last space rubber-bands as before; before the
	/// first space nothing changes either way.
	@Test
	internal func withoutTheOfferOrBeforeTheFirstSpaceOnlyRubberBands() {
		var plain = track(offersCreation: false)
		_ = plain.begin(deltaX: -4, deltaY: 0)
		plain.move(by: -150, at: 1)
		#expect(plain.creationPull == 0)
		let snapsBack = plain.release(at: 2) == .space(2)
		#expect(snapsBack)
		let wheelStop = plain.wheel(by: -40, at: 10)
		#expect(wheelStop != .creation)
		#expect(!plain.isCreationOpen)

		// One space and nothing offered: no rubber band at all, as before.
		var single = track(spaceIndex: 0, pageCount: 1, offersCreation: false)
		let singleBegan = single.begin(deltaX: -4, deltaY: 0)
		#expect(!singleBegan)
		// One space with the page offered: the pull works there too.
		var offered = track(spaceIndex: 0, pageCount: 1)
		let offeredBegan = offered.begin(deltaX: -4, deltaY: 0)
		#expect(offeredBegan)
		offered.move(by: -150, at: 1)
		let offeredStop = offered.release(at: 2)
		#expect(offeredStop == .creation)

		var first = track(spaceIndex: 0, hasLibrary: false)
		let firstBegan = first.begin(deltaX: 4, deltaY: 0)
		#expect(!firstBegan)
		#expect(first.creationPull == 0)
	}

	@Test
	internal func theFeatureFlagIsOnUnlessTurnedOff() {
		#expect(SidebarSpaceCreation.isOn(read: { _ in nil }))
		#expect(SidebarSpaceCreation.isOn(read: { _ in "1" }))
		for off in ["0", "false", "NO", "off"] {
			#expect(!SidebarSpaceCreation.isOn(read: { _ in off }))
		}
	}
}

/// What the window hears as the page opens and closes. With no window to draw in, each spring
/// lands at once.
@MainActor
@Suite
internal struct SidebarSpaceCreationDriverTests {
	/// A swipe from the last space to the page: the last space is committed, with the Library
	/// shut, and showing it doesn't take the page away. Cancel commits the last space again as it
	/// lands. One swipe goes one stop (DEV-1310), so the page is reached from the last space.
	@Test
	internal func reachingThePageCommitsTheLastSpaceAndCancelReturnsToIt() {
		var commits: [String] = []
		let driver = SidebarTrackDriver(track: .init(
			spaceIndex: 2,
			pageCount: 3,
			pageWidth: 300,
			libraryWidth: 400,
			offersCreation: true
		))
		driver.handlers = .init(
			isEnabled: true,
			reduceMotion: false,
			progressChanged: { _ in },
			committed: { isLibraryOpen, index in commits.append("\(isLibraryOpen ? "library" : "space") \(index)") },
			creationLanded: { last in
				commits.append("space \(last)")
				return true
			}
		)
		let began = driver.begin(deltaX: -4, deltaY: 0)
		#expect(began)
		driver.move(by: -150, at: 1)
		driver.release(at: 2)
		#expect(driver.isCreationOpen)
		#expect(commits == ["space 2"])

		driver.present(spaceIndex: 2, isLibraryOpen: false)
		#expect(driver.isCreationOpen)

		driver.closeCreation()
		#expect(!driver.isCreationOpen)
		#expect(driver.track.position == 2)
		#expect(commits == ["space 2", "space 2"])
	}

	/// Only the window presenting what landing selected leaves the page; a space chosen after
	/// that, such as one New Space just made at the end, is shown.
	@Test
	internal func aSpaceChosenWhileThePageIsOpenIsShown() {
		let driver = SidebarTrackDriver(track: .init(
			spaceIndex: 2,
			pageCount: 3,
			pageWidth: 300,
			libraryWidth: 400,
			offersCreation: true
		))
		driver.handlers = .init(
			isEnabled: true,
			reduceMotion: false,
			progressChanged: { _ in },
			committed: { _, _ in },
			creationLanded: { _ in false }
		)
		_ = driver.begin(deltaX: -4, deltaY: 0)
		driver.move(by: -150, at: 1)
		driver.release(at: 2)
		#expect(driver.isCreationOpen)

		// New Space adds a space after the others and selects it.
		driver.configure(pageCount: 4, libraryWidth: 400, hasLibrary: true, offersCreation: true)
		driver.present(spaceIndex: 3, isLibraryOpen: false)
		#expect(!driver.isCreationOpen)
		#expect(driver.track.position == 3)
	}
}

/// Writes offscreen PNGs of the + bubble as a pull gathers and once letting go would open the
/// page, and of the Create a Space page, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a
/// directory (DEV-1109).
@MainActor
@Suite(
	.renderTurn,
	.enabled(if: SidebarChromeSnapshot.directory != nil)
)
internal struct SidebarSpaceCreationSnapshotTests {
	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func bubble(_ appearance: NSAppearance.Name) throws {
		let view = HStack(spacing: 12) {
			ForEach([40, 90, 150], id: \.self) { (points: Int) in
				SidebarSpaceCreationBubble(driver: Self.pulled(by: CGFloat(points)))
					.frame(width: 120, height: 160)
					.background(BrowserChromeBackground(textured: true))
			}
		}
		.padding(16)
		try SidebarChromeSnapshot.write(
			view.frame(maxWidth: .infinity, maxHeight: .infinity).background(BrowserChromeBackground(textured: true)),
			size: .init(width: 416, height: 192),
			appearance: appearance,
			name: "space-creation-bubble"
		)
	}

	@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
	internal func page(_ appearance: NSAppearance.Name) throws {
		let creation = SidebarSpaceCreation(
			profiles: [
				.init(id: Self.id(1), name: "Personal"),
				.init(id: Self.id(2), name: "Work", appearance: .init(tintHue: 210, tintIntensity: 0.8)),
			],
			global: .init(),
			create: { _, _, _ in }
		)
		let view = SidebarSpaceCreationPage(creation: creation, profileID: Self.id(1), onCancel: {})
			.frame(width: 260, height: 520)
			.background(BrowserChromeBackground(textured: true))
		try SidebarChromeSnapshot.write(
			view,
			size: .init(width: 260, height: 520),
			appearance: appearance,
			name: "space-creation-page"
		)
	}

	/// A driver pulled this many points past the last of three spaces.
	private static func pulled(by points: CGFloat) -> SidebarTrackDriver {
		var track = SidebarTrack(
			spaceIndex: 2,
			pageCount: 3,
			pageWidth: 300,
			libraryWidth: 400,
			offersCreation: true
		)
		_ = track.begin(deltaX: -4, deltaY: 0)
		track.move(by: -points, at: 1)
		return .init(track: track)
	}

	private static func id(_ value: Int) -> UUID {
		UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", value))!
	}
}
