#if DEBUG
import Testing

@testable import AppFeature

/// DEV-1191: the app smoke's Shift-click wait settles once the Peek is idle on the target page,
/// and a timeout names the first step from the click to the Peek that's behind.
internal struct ShiftClickCheckTests {
	private let check = ShiftClickCheck(
		hit: .page,
		source: .link,
		request: nil,
		route: nil,
		peek: nil,
		windowsAdded: 0,
		tabsAdded: 0
	)

	@Test
	internal func settlesOnAnIdlePeekShowingTheTarget() {
		var check = check
		check.request = .declined
		check.route = .app
		check.peek = .init(isIdle: true, isLoading: false, page: .target)
		#expect(check.lag == nil)

		// As before DEV-1191, the title settles it while the Peek still reports loading.
		check.peek?.isLoading = true
		#expect(check.lag == nil)
	}

	@Test
	internal func namesTheStepThatIsBehind() {
		var check = check
		#expect(check.lag == .noRequest)

		check.hit = .other("SomeOverlay<NSView<NSThemeFrame")
		#expect(check.lag == .clickCovered)
		check.hit = .page

		check.source = .target
		#expect(check.lag == .shiftLost)
		check.source = .link

		check.request = .refused("pageHidden")
		#expect(check.lag == .engineRefused)

		check.request = .declined
		#expect(check.lag == .appDropped)
		check.route = .chromium
		#expect(check.lag == .appDropped)
		check.route = .app
		#expect(check.lag == .peekRefused)

		check.request = .adopted
		check.route = .chromium
		check.windowsAdded = 1
		#expect(check.lag == .openedElsewhere)
	}

	/// Once a Peek exists, it's what's behind, whatever came before.
	@Test
	internal func aPeekThatIsntThereYetIsLoadingOrHasAnotherTitle() {
		var check = check
		check.request = .declined
		check.route = .app

		check.peek = .init(isIdle: false, isLoading: false, page: .target)
		#expect(check.lag == .peekLoading)
		check.peek = .init(isIdle: true, isLoading: true, page: .other)
		#expect(check.lag == .peekLoading)
		check.peek = .init(isIdle: true, isLoading: false, page: .other)
		#expect(check.lag == .peekTitle)
	}

	/// What the link page saw of the click tells a click Chromium never delivered from a
	/// Shift-click the page saw without asking for a new window, and from one without Shift.
	@Test
	internal func whatThePageSawNamesWhyNoRequestCame() {
		var check = check
		check.pageSaw = .nothing
		#expect(check.lag == .clickNotDelivered)
		check.pageSaw = .click(shift: false)
		#expect(check.lag == .shiftLost)
		check.pageSaw = .click(shift: true)
		#expect(check.lag == .noRequest)

		// Once a request came, what the page saw no longer decides.
		check.pageSaw = .nothing
		check.request = .declined
		check.route = .app
		#expect(check.lag == .peekRefused)
	}

	@Test
	internal func readsTheClicksTheLinkPageCounts() {
		#expect(ShiftClickCheck.PageSaw(title: "Arx Shift link") == .nothing)
		#expect(ShiftClickCheck.PageSaw(title: "Arx Shift link \u{00B7} down=1 shift=1") == .click(shift: true))
		#expect(ShiftClickCheck.PageSaw(title: "Arx Shift link \u{00B7} down=2 shift=0") == .click(shift: false))
		#expect(ShiftClickCheck.PageSaw(title: "Arx Shift link \u{00B7} down=0 shift=0") == .unknown)
		#expect(ShiftClickCheck.PageSaw(title: "Arx Shift target") == .unknown)
		#expect(ShiftClickCheck.PageSaw(title: nil) == .unknown)
		// The page that counted a click is still the link page.
		#expect(ShiftClickCheck.Page(title: "Arx Shift link \u{00B7} down=1 shift=1") == .link)
	}

	@Test
	internal func readsOnlyTheFixtureTitles() {
		#expect(ShiftClickCheck.Page(title: "Arx Shift link") == .link)
		#expect(ShiftClickCheck.Page(title: "Arx Shift target") == .target)
		#expect(ShiftClickCheck.Page(title: "Shift link loading") == .other)
		#expect(ShiftClickCheck.Page(title: nil) == .other)
	}

	@Test
	internal func describesEachStepWithoutPageText() {
		var check = check
		check.request = .refused("staleDocument")
		check.route = .chromium
		check.peek = .init(isIdle: false, isLoading: true, page: .other)
		check.windowsAdded = 1
		#expect(check.description == "hit=page source=link pageSaw=unknown request=refused(staleDocument) route=chromium "
			+ "peek=busy,loading,other windowsAdded=1 tabsAdded=0")
		#expect(self.check.description == "hit=page source=link pageSaw=unknown request=none route=none peek=none "
			+ "windowsAdded=0 tabsAdded=0")
	}
}
#endif
