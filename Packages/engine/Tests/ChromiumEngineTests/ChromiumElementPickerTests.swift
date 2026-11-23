import AppKit
import Foundation
import Testing
import WebKit

@testable import ChromiumEngine

/// DEV-1201: Arx's own element picker. Its script runs here in WebKit's client world, an
/// isolated world as the engine's translation world is, on pages loaded offscreen.
@MainActor
@Suite
internal struct ChromiumElementPickerTests {
	// MARK: - The rule each pick makes

	private static let rules: String = """
	<!doctype html>
	<html><body>
	<div id="promo">Spring sale</div>
	<div id="ember1234" class="newsletter">Sign up</div>
	<ul class="feed"><li class="post">First</li><li class="post">Second</li></ul>
	<section id="sidebar"><div class="card">One</div><div class="card">Two</div></section>
	<main><div class="card">Elsewhere</div></main>
	<div data-testid="cookie-banner" class="x">We use cookies</div>
	<div class="css-1q2w3e sc-AbC12x banner is-open">Hashed</div>
	<p><span>a</span><span>b</span></p>
	<iframe id="frame" srcdoc="<aside class='ad'>Ad</aside>"></iframe>
	</body></html>
	"""

	@Test(arguments: [
		("#promo", "#promo"),
		// A made-up id is passed over for a lasting class.
		("#ember1234", "div.newsletter"),
		("ul.feed > li:nth-of-type(2)", "li.post:nth-of-type(2)"),
		// Alike siblings elsewhere too: up to the nearest id.
		("#sidebar > div:nth-of-type(1)", "#sidebar > div.card:nth-of-type(1)"),
		("[data-testid]", "div[data-testid=\"cookie-banner\"]"),
		// Hashed and state classes are left out.
		(".banner", "div.banner"),
		// Tags and places alone would hide something else on another page of the site.
		("p > span:nth-of-type(2)", "body > p > span:nth-of-type(2)"),
	])
	internal func aPickNamesOnlyItsElement(query: String, selector: String) async throws {
		let page = try await Page(html: Self.rules)
		let described: Described = try await page.run("""
		return globalThis.__arxElementPicker.describe(document.querySelector(\(Self.literal(query))));
		""")
		#expect(described.selector == selector)
		let count: Int = try await page.run("return document.querySelectorAll(\(Self.literal(selector))).length;")
		#expect(count == 1)
	}

	@Test
	internal func aPickInASameOriginFrameNamesItInItsOwnDocument() async throws {
		let page = try await Page(html: Self.rules)
		try await page.waitFor("return document.getElementById('frame').contentDocument.querySelector('.ad') !== null;")
		let described: Described = try await page.run("""
		const inner = document.getElementById('frame').contentDocument.querySelector('.ad');
		return globalThis.__arxElementPicker.describe(inner);
		""")
		#expect(described.selector == "aside.ad")
		#expect(described.label == "Ad")

		// ↑ from the frame's only element widens to the frame itself, in the page.
		let widened: String = try await page.run("""
		const picker = globalThis.__arxElementPicker;
		picker.hoverForTesting(document.getElementById('frame').contentDocument.querySelector('.ad'));
		picker.widenForTesting();
		return picker.currentForTesting().id;
		""")
		#expect(widened == "frame")
	}

	/// A frame drawn over something else is what's under the point, though frames take no
	/// pointer events while the picker is open.
	@Test
	internal func aFrameOverAnotherElementIsWhatsUnderThePoint() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div id="behind" style="position: absolute; left: 0; top: 0; width: 300px; height: 200px">Behind</div>
		<iframe id="over" src="https://ads.example/frame" style="position: absolute; left: 20px; top: 20px; width: 200px; height: 120px; border: 0"></iframe>
		</body></html>
		""")
		let id: String = try await page.run("return globalThis.__arxElementPicker.elementAtForTesting(60, 60).id;")
		#expect(id == "over")
		let outside: String = try await page.run("return globalThis.__arxElementPicker.elementAtForTesting(260, 170).id;")
		#expect(outside == "behind")
		// The outline never takes the pointer from the page itself.
		let under: String = try await page.run("return document.elementFromPoint(60, 60).id;")
		#expect(under == "over")
	}

	/// Over a modal dialog, which makes the rest of the page inert, the picker still takes the
	/// pointer.
	@Test
	internal func thePickerTakesThePointerOverAModalDialog() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body><p>Behind</p><dialog id="consent"><p>We use cookies</p></dialog></body></html>
		""")
		let _: Bool = try await page.run(ChromiumElementPicker.close)
		try await page.runInPage("document.getElementById('consent').showModal(); return true;")
		let _: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style()))
		let layer: String = try await page.run("""
		const host = document.querySelector('arx-element-picker');
		return host && host.parentElement ? host.parentElement.id : '';
		""")
		#expect(layer == "consent")
	}

	/// What's in a frame is outlined only as far as the frame shows it.
	@Test
	internal func aFramesContentIsOutlinedOnlyWhereTheFrameShowsIt() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div style="height: 50px"></div>
		<iframe id="frame" style="border: 0; width: 200px; height: 100px"
		  srcdoc="<body style='margin: 0'><div id='tall' style='height: 400px'>Tall</div></body>"></iframe>
		</body></html>
		""")
		try await page.waitFor("return document.getElementById('frame').contentDocument.getElementById('tall') !== null;")
		let drawn: Drawn = try await page.run("""
		return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('frame').contentDocument.getElementById('tall'));
		""")

		// The frame shows 50 to 150 px down the page, plus the outline's 2 px each side.
		#expect(abs(drawn.box.top - 48) < 1)
		#expect(abs(drawn.box.height - 104) < 1)
	}

	/// A same-origin frame scaled by a transform: the point is scaled into it, and the outline
	/// out of it.
	@Test
	internal func aScaledFrameIsLookedIntoAtItsScale() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<iframe id="frame" style="border: 0; width: 200px; height: 200px; transform: scale(2); transform-origin: 0 0"
		  srcdoc="<body style='margin: 0'><div id='top' style='height: 50px'>Top</div><div id='bottom' style='height: 50px'>Bottom</div></body>"></iframe>
		</body></html>
		""")
		try await page.waitFor("return document.getElementById('frame').contentDocument.getElementById('bottom') !== null;")

		// 75 px down the page is 37.5 px down the frame's own page: still the top element.
		let id: String = try await page.run("return globalThis.__arxElementPicker.elementAtForTesting(20, 75).id;")
		#expect(id == "top")
		let drawn: Drawn = try await page.run("""
		return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('frame').contentDocument.getElementById('bottom'));
		""")

		// The bottom element is 50 to 100 px down the frame: 100 to 200 on the page, plus the outline's 2 px.
		#expect(abs(drawn.box.top - 98) < 1)
		#expect(abs(drawn.box.height - 104) < 1)
	}

	@Test
	internal func filtersNameThePagesSiteAndOnlyAPlainSelector() {
		#expect(ChromiumElementPicker.site(of: URL(string: "https://News.Example/a")!) == "news.example")
		#expect(ChromiumElementPicker.site(of: URL(string: "http://[::1]:8080/")!) == "[::1]")
		#expect(ChromiumElementPicker.site(of: URL(string: "https://xn--bcher-kva.example/")!) == "xn--bcher-kva.example")
		#expect(ChromiumElementPicker.site(of: URL(string: "file:///tmp/a.html")!) == nil)
		#expect(ChromiumElementPicker.site(of: URL(string: "chrome-extension://abc/options.html")!) == nil)

		#expect(ChromiumElementPicker.filter(site: "news.example", selector: "#promo") == "news.example###promo")
		#expect(ChromiumElementPicker.filter(site: "[::1]", selector: "aside.ad") == "[::1]##aside.ad")
		for selector in [
			"", "+js(noop)", "^script", "div\nexample.com##body", "a##b", "div#@#x", "div:style(color: red)",
			"div:remove()", "div:remove-attr(href)", "div:remove-class(x)", "div:watch-attr(x)",
			String(repeating: "a", count: 8 * 1024 + 1),
		] {
			#expect(ChromiumElementPicker.filter(site: "news.example", selector: selector) == nil, "\(selector.prefix(40))")
		}
		#expect(ChromiumElementPicker.filter(site: "a#b", selector: "div") == nil)
	}

	// MARK: - Labels

	@Test(arguments: [
		("<div id='t' aria-label='Close dialog'>×</div>", "Close dialog"),
		("<section id='t'><h2>Needs your teams' review</h2><p>One pull request</p></section>", "Needs your teams' review"),
		("<p id='t'>  Plain   words<br>on two lines</p>", "Plain words"),
		("<nav id='t' style='height: 20px'></nav>", "navigation · nav"),
		("<div id='t' style='height: 20px'></div>", "div"),
		("<p id='t'>\(String(repeating: "word ", count: 20))</p>", "word word word word word word word word…"),
		("<img id='t' alt='Company logo' width='10' height='10'>", "Company logo"),
		("<iframe id='t' src='https://ads.example/frame'></iframe>", "Frame · ads.example"),
	])
	internal func theChipNamesTheElement(html: String, label: String) async throws {
		let page = try await Page(html: "<!doctype html><html><body>\(html)</body></html>")
		let described: Described = try await page.run(
			"return globalThis.__arxElementPicker.describe(document.getElementById('t'));"
		)
		#expect(described.label == label)
	}

	// MARK: - Drawing

	@Test
	internal func theOutlineAndChipDrawOnAPageThatAllowsNoStylesOrScripts() async throws {
		let page = try await Page(html: """
		<!doctype html>
		<html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'none'; script-src 'none'"></head>
		<body><p>One</p><p>Two</p><p>Three</p><section id="t"><h2>Pick me</h2></section></body></html>
		""")
		let drawn: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'));"
		)
		#expect(drawn.box.width > 100)
		#expect(drawn.border == "2px")
		#expect(drawn.radius == "6px")
		#expect(drawn.chip.text == "Pick me")
		// The chip sits on the outline's top-leading corner, just above it.
		#expect(drawn.chip.left == drawn.box.left)
		#expect(drawn.chip.top + drawn.chip.height <= drawn.box.top)
		#expect(!drawn.dark)
	}

	@Test
	internal func theOutlineAndChipKeepTheirSizeOnScreenWhenThePageIsZoomed() async throws {
		let page = try await Page(html: "<!doctype html><html><body><div style='height: 80px'></div><p id='t'>Zoomed</p></body></html>", zoom: 2)
		let drawn: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'));"
		)
		#expect(drawn.border == "1px")
		#expect(drawn.radius == "3px")
	}

	/// A narrow element at the page's right edge keeps all of its chip on screen.
	@Test
	internal func theChipStaysOnScreenAtThePagesEdge() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div id="t" aria-label="Notifications and messages from your team" style="position: absolute; right: 0; top: 100px; width: 20px; height: 20px"></div>
		</body></html>
		""")
		let drawn: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'));"
		)
		let width: Double = try await page.run("return innerWidth;")
		#expect(drawn.chip.width > 100)
		#expect(drawn.chip.left + drawn.chip.width <= width - 1)
		#expect(drawn.chip.left >= 1)
	}

	@Test
	internal func aDarkPageGetsAStrongerFill() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="background: #0d1117; color: #e6edf3">
		<div style="height: 80px"></div><section id="t">Dark</section></body></html>
		""")
		let drawn: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'));"
		)
		#expect(drawn.dark)
	}

	@Test
	internal func atTheTopOfThePageTheChipGoesInsideTheOutline() async throws {
		let page = try await Page(html: "<!doctype html><html><body style='margin: 0'><header id='t' style='height: 60px'>Top</header></body></html>")
		let drawn: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'));"
		)
		#expect(drawn.chip.top > drawn.box.top)
		#expect(drawn.chip.left > drawn.box.left)
	}

	// MARK: - A session

	@Test
	internal func aPickIsToldOnceAndTheElementGoes() async throws {
		let page = try await Page(html: Self.rules)
		let session = try #require(page.session)
		let picked: String = try await page.run(
			"return globalThis.__arxElementPicker.pickForTesting(document.getElementById('promo')).state;"
		)
		#expect(picked == "picked")

		let first: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(first.state == "picked")
		#expect(first.selector == "#promo")
		#expect(first.label == "Spring sale")
		let second: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(second.state == "closed")

		let display: String = try await page.run("return getComputedStyle(document.getElementById('promo')).display;")
		#expect(display == "none")
		try await page.waitFor("return document.querySelector('arx-element-picker') === null;")
	}

	// MARK: - Hide Element's mode (DEV-1298)

	/// A pick hides the element and is told with its name and kind; the picker stays for the next.
	@Test
	internal func inTheModeAPickHidesAndThePickerStaysOpen() async throws {
		let page = try await Page(html: Self.rules, keepsOpen: true)
		let session = try #require(page.session)
		let _: Drawn? = try await page.run(
			"return globalThis.__arxElementPicker.pickForTesting(document.getElementById('promo')) && null;"
		)
		let polled: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(polled.state == "active")
		#expect(polled.picks == [.init(selector: "#promo", label: "Spring sale", kind: "element")])
		let display: String = try await page.run("return getComputedStyle(document.getElementById('promo')).display;")
		#expect(display == "none")
		let open: Bool = try await page.run("return document.querySelector('arx-element-picker') !== null;")
		#expect(open)

		// A pick is told once; a second one comes in its own look.
		let _: Drawn? = try await page.run(
			"return globalThis.__arxElementPicker.pickForTesting(document.querySelector('ul.feed')) && null;"
		)
		let next: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(next.picks == [.init(selector: "ul.feed", label: "First", kind: "list")])

		// Escape, which the app sends for Done, closes it.
		let closed: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.key("Escape")])
		)
		#expect(closed.state == "closed")
	}

	/// Undo and an entry's Delete show again what this session hid; what uBlock's rule hid before
	/// it stays hidden until the page loads again.
	@Test
	internal func unhideShowsWhatTheSessionHid() async throws {
		let page = try await Page(html: """
		<!doctype html><html><head><style>#earlier { display: none !important }</style></head><body>
		<div id="promo" style="display: flex">Spring sale</div><div id="earlier">Earlier</div>
		</body></html>
		""", keepsOpen: true)
		let session = try #require(page.session)
		let _: Drawn? = try await page.run(
			"return globalThis.__arxElementPicker.pickForTesting(document.getElementById('promo')) && null;"
		)
		let _: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))

		let shown: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.unhide("#promo"), .unhide("#earlier")])
		)
		#expect(shown.shown == ["#promo": true, "#earlier": false])
		// Its own inline display comes back.
		let display: String = try await page.run("return getComputedStyle(document.getElementById('promo')).display;")
		#expect(display == "flex")
	}

	/// Undo while the element is still fading away keeps it shown (Codex, round 1).
	@Test
	internal func undoDuringTheFadeKeepsTheElementShown() async throws {
		let page = try await Page(html: Self.rules, keepsOpen: true, reduceMotion: false)
		let session = try #require(page.session)
		let _: Drawn? = try await page.run(
			"return globalThis.__arxElementPicker.pickForTesting(document.getElementById('promo')) && null;"
		)
		let shown: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.unhide("#promo")])
		)
		#expect(shown.shown == ["#promo": true])
		try await Task.sleep(for: .milliseconds(500))
		let display: String = try await page.run("return getComputedStyle(document.getElementById('promo')).display;")
		#expect(display == "block")
	}

	/// The list names each hidden element by what it finds on the page, even hidden.
	@Test
	internal func describeNamesWhatEachLineHides() async throws {
		let page = try await Page(html: """
		<!doctype html><html><head><style>nav, .ad { display: none !important }</style></head><body>
		<nav aria-label="Main menu"><a href="/">Home</a></nav><img class="ad" alt="Sponsored">
		</body></html>
		""", keepsOpen: true)
		let session = try #require(page.session)
		let described: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.describe(["nav", "img.ad", "#missing"])])
		)
		#expect(described.described == [
			"nav": .init(label: "Main menu", kind: "navigation"),
			"img.ad": .init(label: "Sponsored", kind: "image"),
			"#missing": nil,
		])
	}

	/// The outline's box comes back in the app's view's points, so the toast can keep clear of it.
	@Test
	internal func theTargetComesBackInTheViewsPoints() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div id="t" style="position: absolute; left: 100px; top: 120px; width: 200px; height: 80px">T</div>
		</body></html>
		""", keepsOpen: true)
		let session = try #require(page.session)
		let _: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'), true);"
		)
		let backing = Double(page.window.backingScaleFactor)
		let polled: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, backing: backing)
		)
		let target = try #require(polled.target)

		// The outline sits 2 points outside the element.
		#expect(abs(target.x - 98) < 0.5)
		#expect(abs(target.y - 118) < 0.5)
		#expect(abs(target.width - 204) < 0.5)
		#expect(abs(target.height - 84) < 0.5)
	}

	@Test
	internal func selectorsComeBackFromTheirLines() {
		#expect(ChromiumElementPicker.selector(of: "news.example##div.banner") == "div.banner")
		#expect(ChromiumElementPicker.selector(of: "news.example##+js(set)") == nil)
		#expect(ChromiumElementPicker.selector(of: "news.example") == nil)
	}

	@Test
	internal func openingAgainClosesThePickerAndLeavesNothingBehind() async throws {
		let page = try await Page(html: Self.rules)
		let session = try #require(page.session)
		let again: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style()))
		#expect(again.state == "closed")
		let polled: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(polled.state == "closed")
		let left: Bool = try await page.run("""
		return document.querySelector('arx-element-picker') === null && document.adoptedStyleSheets.length === 0;
		""")
		#expect(left)

		// A third time opens a new session.
		let reopened: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style()))
		#expect(reopened.state == "active")
		#expect(reopened.session == session + 1)
	}

	@Test
	internal func aPickNotYetToldSurvivesTheNextOpen() async throws {
		let page = try await Page(html: Self.rules)
		let session = try #require(page.session)
		let _: String = try await page.run(
			"return globalThis.__arxElementPicker.pickForTesting(document.getElementById('promo')).state;"
		)
		let reopened: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style()))
		#expect(reopened.state == "active")
		let told: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(told.state == "picked")
		#expect(told.selector == "#promo")
	}

	/// DEV-1206: a pick comes from the app's view over the page, as commands, so the page's own
	/// listeners, capture-phase ones on its window and document included, never see it.
	@Test
	internal func aPickNeverReachesThePagesOwnListeners() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div style="height: 40px"></div><aside id="t" style="height: 60px">Promo</aside>
		</body></html>
		""")
		let session = try #require(page.session)
		try await page.runInPage("""
		for (const target of [window, document]) {
		  for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click', 'keydown']) {
		    target.addEventListener(type, (event) => {
		      document.body.dataset.seen = (document.body.dataset.seen || '') + type + ' ';
		      if (type === 'click') location.hash = 'navigated';
		    }, true);
		  }
		}
		return true;
		""")
		let ratio: Double = try await page.run("return devicePixelRatio;")
		let moved: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.pointer(.init(x: 30, y: 60))], backing: ratio)
		)
		#expect(moved.state == "active")
		let picked: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.click(.init(x: 30, y: 60))], backing: ratio)
		)
		#expect(picked.state == "picked")
		#expect(picked.selector == "#t")

		let state: PageState = try await page.run("""
		return { hash: location.hash, seen: document.body.dataset.seen || '' };
		""")
		#expect(state.hash == "")
		#expect(state.seen == "")
	}

	/// The keys the app's view sees widen, narrow, pick and leave; a secondary click leaves.
	@Test
	internal func keysFromTheAppsViewDriveThePicker() async throws {
		let page = try await Page(html: Self.rules)
		let session = try #require(page.session)
		let _: Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.querySelector('#sidebar > div'));"
		)
		let _: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.key("ArrowUp")])
		)
		let widened: String = try await page.run("return globalThis.__arxElementPicker.currentForTesting().id;")
		#expect(widened == "sidebar")
		let _: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.key("ArrowDown")])
		)
		let narrowed: String = try await page.run("return globalThis.__arxElementPicker.currentForTesting().className;")
		#expect(narrowed == "card")
		let picked: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.key("Enter")])
		)
		#expect(picked.state == "picked")
		#expect(picked.selector == "#sidebar > div.card:nth-of-type(1)")

		for command in [ChromiumElementPicker.Command.key("Escape"), .menu] {
			let reopened: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style()))
			let next = try #require(reopened.session)
			let closed: ChromiumElementPicker.Event = try await page.run(
				ChromiumElementPicker.poll(session: next, commands: [command])
			)
			#expect(closed.state == "closed")
			let gone: Bool = try await page.run("return document.querySelector('arx-element-picker') === null;")
			#expect(gone)
		}
	}

	/// A move and a key that arrive together act on what's under the moved pointer.
	@Test
	internal func aKeyActsOnAMoveThatCameWithIt() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div id="a" style="height: 100px">A</div><div id="b" style="height: 100px">B</div>
		</body></html>
		""")
		let session = try #require(page.session)
		let ratio: Double = try await page.run("return devicePixelRatio;")
		let _: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.pointer(.init(x: 10, y: 50))], backing: ratio)
		)
		let _: Drawn = try await page.run("return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('a'));")
		let picked: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.pointer(.init(x: 10, y: 150)), .key("Enter")], backing: ratio)
		)
		#expect(picked.selector == "#b")
	}

	/// The same ask again, as after a look that timed out, answers for the session it opened
	/// instead of closing it; another ask toggles it closed.
	@Test
	internal func theSameOpenAskTwiceKeepsItsSession() async throws {
		let page = try await Page(html: Self.rules)
		let _: Bool = try await page.run(ChromiumElementPicker.close)
		let first: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style(), request: "ask"))
		#expect(first.state == "active")
		let again: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style(), request: "ask"))
		#expect(again.state == "active")
		#expect(again.session == first.session)
		let other: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.open(style: Self.style(), request: "another"))
		#expect(other.state == "closed")
	}

	/// The view's points become the page's: a page drawn at twice the screen's pixels per point
	/// takes a point at half the place.
	@Test
	internal func theViewsPointsBecomeThePagesAtItsZoom() async throws {
		let page = try await Page(html: """
		<!doctype html><html><body style="margin: 0">
		<div id="a" style="height: 100px">A</div><div id="b" style="height: 100px">B</div>
		</body></html>
		""")
		let session = try #require(page.session)
		let ratio: Double = try await page.run("return devicePixelRatio;")

		// As if the screen had twice the pixels per point the page does: point 75 is page 150.
		let _: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.pointer(.init(x: 10, y: 75))], backing: ratio * 2)
		)
		let picked: ChromiumElementPicker.Event = try await page.run(
			ChromiumElementPicker.poll(session: session, commands: [.click(.init(x: 10, y: 75))], backing: ratio * 2)
		)
		#expect(picked.selector == "#b")
	}

	@Test
	internal func thePagesOwnEventsCantPickOrClose() async throws {
		let page = try await Page(html: Self.rules)
		let session = try #require(page.session)
		try await page.runInPage("""
		document.getElementById('promo').click();
		document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
		return true;
		""")
		let polled: ChromiumElementPicker.Event = try await page.run(ChromiumElementPicker.poll(session: session))
		#expect(polled.state == "active")
	}

	@Test
	internal func theStyleReachesTheScriptAsJSON() {
		let style = ChromiumElementPicker.Style(
			accent: .init(red: 1, green: 0.5, blue: -2),
			onAccent: .init(red: 1, green: 1, blue: .nan),
			zoom: 0,
			reduceMotion: true
		)
		#expect(style.json == #"{"accentRGB":"rgb(255, 128, 0)","keepsOpen":false,"onAccentRGB":"rgb(255, 255, 0)","reduceMotion":true,"zoom":1}"#)
	}

	// MARK: - Fixtures

	internal struct PageState: Decodable {
		var hash: String
		var seen: String
	}

	internal struct Described: Decodable {
		var selector: String?
		var label: String
	}

	internal struct Drawn: Decodable {
		struct Box: Decodable {
			var left: Double
			var top: Double
			var width: Double
			var height: Double
		}

		struct Chip: Decodable {
			var left: Double
			var top: Double
			var width: Double
			var height: Double
			var text: String
		}

		var box: Box
		var chip: Chip
		var dark: Bool
		var border: String
		var radius: String
	}

	internal static func style(
		zoom: Double = 1,
		keepsOpen: Bool = false,
		reduceMotion: Bool = true
	) -> ChromiumElementPicker.Style {
		.init(
			accent: keepsOpen ? hidingRed : .init(red: 0.04, green: 0.52, blue: 1),
			onAccent: .init(red: 1, green: 1, blue: 1),
			zoom: zoom,
			reduceMotion: reduceMotion,
			keepsOpen: keepsOpen
		)
	}

	/// Hide Element's red (DEV-1298): the design system's red accent preset.
	internal static let hidingRed: ChromiumElementPicker.Style.Color = .init(red: 0.913725, green: 0.258824, blue: 0.247059)

	private static func literal(_ string: String) -> String {
		let data = try! JSONSerialization.data(withJSONObject: [string])
		return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
	}

	/// A page loaded offscreen with the picker open on it.
	@MainActor
	internal final class Page {
		let view: WKWebView
		let window: NSWindow
		private(set) var session: Int?

		init(
			html: String,
			zoom: Double = 1,
			size: CGSize = .init(width: 720, height: 480),
			dark: Bool = false,
			keepsOpen: Bool = false,
			reduceMotion: Bool = true
		) async throws {
			let configuration = WKWebViewConfiguration()
			configuration.websiteDataStore = .nonPersistent()
			view = WKWebView(frame: .init(origin: .zero, size: size), configuration: configuration)
			view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
			view.pageZoom = zoom
			window = NSWindow(
				contentRect: .init(x: -10_000, y: -10_000, width: size.width, height: size.height),
				styleMask: [.borderless],
				backing: .buffered,
				defer: false
			)
			window.isReleasedWhenClosed = false
			window.contentView = view
			view.loadHTMLString(html, baseURL: URL(string: "https://news.example/"))
			for _ in 0 ..< 100 where view.isLoading {
				try await Task.sleep(for: .milliseconds(50))
			}
			let opened: ChromiumElementPicker.Event = try await run(
				ChromiumElementPicker.open(
					style: ChromiumElementPickerTests.style(zoom: zoom, keepsOpen: keepsOpen, reduceMotion: reduceMotion)
				)
			)
			session = opened.session
		}

		/// Runs a function body in the client world, as the engine runs the picker's scripts.
		func run<Value: Decodable>(_ script: String) async throws -> Value {
			let wrapped = "const value = await (async () => {\n\(script)\n})();\nreturn JSON.stringify(value);"
			let result = try await view.callAsyncJavaScript(wrapped, contentWorld: .defaultClient)
			let json = try #require(result as? String)
			return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
		}

		/// Runs a function body as the page's own script would.
		func runInPage(_ script: String) async throws {
			_ = try await view.callAsyncJavaScript(script, contentWorld: .page)
		}

		func waitFor(_ script: String) async throws {
			for _ in 0 ..< 60 {
				let done: Bool = try await run(script)
				if done { return }
				try await Task.sleep(for: .milliseconds(50))
			}
			Issue.record("never: \(script)")
		}
	}
}

/// Offscreen PNGs of the picker's outline and chip (DEV-1201), in Hide Element's red (DEV-1298), for visual self-review, when
/// `ARX_DESIGN_SNAPSHOTS` names a directory: a light and a dark page.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct ChromiumElementPickerSnapshotTests {
	@Test(arguments: [false, true])
	internal func outlineAndChip(dark: Bool) async throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))
		let background = dark ? "#0d1117" : "#ffffff"
		let text = dark ? "#e6edf3" : "#1f2328"
		let border = dark ? "#30363d" : "#d1d9e0"
		let html = """
		<!doctype html>
		<html><body style="margin: 0; padding: 32px; background: \(background); color: \(text); font: 14px -apple-system, sans-serif">
		<div style="border: 1px solid \(border); border-radius: 6px; padding: 12px 16px; margin-bottom: 24px">
		  <div style="font-weight: 600">Arx/arx-browser#1201</div><div style="opacity: .7">Updated an hour ago</div>
		</div>
		<section id="t" style="border: 1px solid \(border); border-radius: 6px">
		  <h2 style="margin: 0; padding: 12px 16px; font-size: 18px">Needs your teams' review</h2>
		  <div style="border-top: 1px solid \(border); padding: 12px 16px">DEV-1201: Arx's own element picker</div>
		</section>
		</body></html>
		"""
		let page = try await ChromiumElementPickerTests.Page(
			html: html,
			size: .init(width: 760, height: 320),
			dark: dark,
			keepsOpen: true
		)
		let _: ChromiumElementPickerTests.Drawn = try await page.run(
			"return globalThis.__arxElementPicker.hoverForTesting(document.getElementById('t'), true);"
		)
		try await Task.sleep(for: .milliseconds(200))

		let image = try await page.view.takeSnapshot(configuration: nil)
		let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
		let png = try #require(bitmap.representation(using: .png, properties: [:]))
		try png.write(to: directory.appending(path: "hide-element-highlight-\(dark ? "dark" : "light").png"))
	}
}
