import AppKit
import Foundation
import SwiftUI
@testable import AppUI
import Testing

/// The soft edge under a bar that content scrolls beneath (DEV-763, DEV-782, DEV-807, DEV-808).
@Suite(.renderTurn)
internal struct ArxScrollEdgeTests {
	/// At rest nothing is faded, so a pane's header icon is drawn whole (DEV-763). The edge grows
	/// in over one fade's height of scrolling and stays at full strength after that.
	@Test
	@MainActor
	internal func scrollFadeShowsOnlyOnceContentScrollsUnderTheBar() {
		let height = ArxScrollEdgeFade.height
		#expect(ArxScrollEdgeFade.opacity(scrolledBy: -20) == 0)
		#expect(ArxScrollEdgeFade.opacity(scrolledBy: 0) == 0)
		#expect(ArxScrollEdgeFade.opacity(scrolledBy: height / 2) == 0.5)
		#expect(ArxScrollEdgeFade.opacity(scrolledBy: height) == 1)
		#expect(ArxScrollEdgeFade.opacity(scrolledBy: 400) == 1)
	}

	/// Content under an `arxScrollBar` gets the system's soft edge with no line (DEV-807): the
	/// scroll view's top pocket is soft, covers the bar, draws its variable blur, and its
	/// separator is off, at rest and scrolled, in a plain window and in one set up as Settings'
	/// (titled, full-size content, transparent title bar). Read from AppKit's view and layer tree
	/// offscreen, as the blur itself isn't drawn there.
	@Test(arguments: [false, true], [false, true])
	@MainActor
	internal func barGetsTheSystemSoftEdgeWithNoSeparator(
		scrolled: Bool,
		settingsWindow: Bool
	) throws {
		let view = ScrollView {
			Self.rows
		}
		.arxScrollBar {
			Text(verbatim: "Bar")
				.frame(maxWidth: .infinity)
				.frame(height: 52)
		}
		let (window, scrollView) = try Self.host(view, scrolled: scrolled, settingsWindow: settingsWindow)
		defer { window.close() }

		// The bar is a safe-area bar: the scroll view runs under it, inset by at least its height.
		#expect(scrollView.contentInsets.top >= 52)
		try Self.expectSoftEdge(on: scrollView, pocketKey: "topPocketStyle", minimumHeight: 52)
	}

	/// Two bars in one window each blur their own content (DEV-808). AppKit puts every pocket in
	/// a window into one backdrop group, and backdrop layers in a group share one capture, so with
	/// a sidebar and a pane side by side, as in Settings, the pane's edge showed no content. Each
	/// pocket gets a group of its own, and its blur draws in it.
	@Test
	@MainActor
	internal func barsSideBySideBlurTheirOwnContent() throws {
		func column() -> some View {
			ScrollView {
				Self.rows
			}
			.arxScrollBar {
				Text(verbatim: "Bar")
					.frame(maxWidth: .infinity)
					.frame(height: 52)
			}
		}
		let view = HStack(spacing: 0) {
			column()
			column()
		}
		let (window, _) = try Self.host(view, scrolled: false, settingsWindow: true)
		defer { window.close() }

		let host = try #require(window.contentView)
		let pockets = Self.scrollViews(in: host).flatMap(ArxScrollPocketSeparator.pockets(of:))
		try #require(pockets.count >= 2)
		let groups = pockets.map(ArxScrollPocketSeparator.backdropGroupName)
		#expect(groups.allSatisfy { $0?.hasPrefix("ArxPocket-") == true })
		#expect(Set(groups).count == pockets.count)
		for pocket in pockets {
			let blur = Self.layers(in: try #require(pocket.layer)).first { $0.name == "ThinFilmContentBlurFill" }
			let group = blur?.value(forKey: "groupName") as? String
			#expect(group == ArxScrollPocketSeparator.backdropGroupName(pocket))
		}
	}

	/// A bar that draws its own edge, as the progressive one, hides AppKit's pocket (DEV-808): the
	/// pocket blurs the bar's whole height, cut off hard at its lower edge, even with the scroll
	/// edge effect hidden.
	@Test
	@MainActor
	internal func barWithItsOwnEdgeHidesThePocket() throws {
		let view = ScrollView {
			Self.rows
		}
		.safeAreaBar(edge: .top, spacing: 0) {
			Text(verbatim: "Bar")
				.frame(maxWidth: .infinity)
				.frame(height: 52)
		}
		.scrollEdgeEffectHidden(true)
		.background { ArxScrollPocketSeparator.Hider(hiddenPockets: .top) }
		let (window, scrollView) = try Self.host(view, scrolled: true, settingsWindow: true)
		defer { window.close() }

		let pockets = ArxScrollPocketSeparator.pockets(of: scrollView)
		try #require(!pockets.isEmpty)
		#expect(pockets.allSatisfy { $0.isHidden })
	}

	/// The progressive edge, the default, replaces only the top edge (DEV-808): the bar's pocket is
	/// hidden and the blur is drawn over the bar, while a modal's footer keeps the system's soft
	/// edge, its separator off.
	@Test
	@MainActor
	internal func progressiveEdgeReplacesOnlyTheTopEdge() throws {
		let view = ArxModalScaffold {
			Text(verbatim: "Bar").frame(maxWidth: .infinity).frame(height: 52)
		} content: {
			Self.rows
		} footer: {
			Text(verbatim: "Footer").frame(height: 40)
		}
		let (window, scrollView) = try Self.host(view, scrolled: true, settingsWindow: true, options: .init())
		defer { window.close() }

		let pockets = ArxScrollPocketSeparator.pockets(of: scrollView).filter { $0.frame.height > 0 }
		let top = pockets.filter { ArxScrollPocketSeparator.edge(of: $0, in: scrollView) == .top }
		let bottom = pockets.filter { ArxScrollPocketSeparator.edge(of: $0, in: scrollView) == .bottom }
		try #require(!top.isEmpty && !bottom.isEmpty)
		#expect(top.allSatisfy { $0.isHidden })
		#expect(bottom.allSatisfy { !$0.isHidden && ArxScrollPocketSeparator.allowsSeparator($0) == false })
		#expect((scrollView.value(forKey: "bottomPocketStyle") as? NSNumber)?.intValue == 1)

		let content = try #require(window.contentView)
		func blurs(in view: NSView) -> [ArxVariableBlur.BlurView] {
			((view as? ArxVariableBlur.BlurView).map { [$0] } ?? []) + view.subviews.flatMap(blurs(in:))
		}
		let blur = try #require(blurs(in: content).first)
		#expect(blur.bounds.height >= 52)
	}

	/// The separator hider does no work while content scrolls (DEV-808): AppKit keeps the pocket
	/// it made, with its separator off, so the hider doesn't look at it on every scroll tick, and
	/// nothing it does lays anything out again. Scrolled by 60 steps, as a trackpad does, it looks
	/// at most twice, the pocket is the same one, and its separator stays off.
	@Test(arguments: [false, true])
	@MainActor
	internal func hiderDoesNoWorkWhileContentScrolls(settingsWindow: Bool) throws {
		let view = ScrollView {
			Self.rows
		}
		.arxScrollBar {
			Text(verbatim: "Bar")
				.frame(maxWidth: .infinity)
				.frame(height: 52)
		}
		let (window, scrollView) = try Self.host(view, scrolled: false, settingsWindow: settingsWindow)
		defer { window.close() }
		let pocket = try #require(
			ArxScrollPocketSeparator.pockets(of: scrollView).first { $0.frame.height >= 52 }
		)
		#expect(ArxScrollPocketSeparator.allowsSeparator(pocket) == false)

		let content = try #require(window.contentView)
		let hider = try #require(Self.hider(in: content))
		let before = hider.hideCount
		var offset: CGFloat = 0
		for _ in 0..<60 {
			offset += 8
			scrollView.contentView.scroll(to: .init(x: 0, y: offset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			RunLoop.main.run(until: .now.addingTimeInterval(1.0 / 120))
		}
		RunLoop.main.run(until: .now.addingTimeInterval(0.2))

		#expect(hider.hideCount - before <= 2)
		let after = try #require(
			ArxScrollPocketSeparator.pockets(of: scrollView).first { $0.frame.height >= 52 }
		)
		#expect(after === pocket)
		#expect(ArxScrollPocketSeparator.allowsSeparator(after) == false)
	}

	/// The feature flags for the scroll edge (DEV-808): unset, the soft edge with its separator
	/// off; each switch changes only its own part.
	@Test
	internal func scrollEdgeOptionsReadTheirFeatureFlags() {
		func options(_ values: [String: String]) -> ArxScrollEdgeOptions {
			ArxScrollEdgeOptions(read: { values[$0] })
		}

		// Unset, the progressive edge replaces the system's on top only.
		let standard = options([:])
		#expect(standard.isProgressive && standard.isHidden && standard.hidesSeparator && standard.isAdaptive)
		#expect(standard.hiddenEdges == .top)
		let progressive = options(["ARX_SCROLL_EDGE": "progressive"])
		#expect(progressive.isProgressive && progressive.isHidden)
		let soft = options(["ARX_SCROLL_EDGE": "soft"])
		#expect("\(soft.style)" == "\(ScrollEdgeEffectStyle.soft)")
		#expect(!soft.isHidden && !soft.isProgressive)
		#expect(
			"\(ArxScrollEdgeOptions.soft.style)" == "\(ScrollEdgeEffectStyle.soft)"
			&& !ArxScrollEdgeOptions.soft.isProgressive
		)
		let hard = options(["ARX_SCROLL_EDGE": "hard"])
		#expect("\(hard.style)" == "\(ScrollEdgeEffectStyle.hard)" && !hard.isHidden && !hard.isProgressive)
		#expect("\(options(["ARX_SCROLL_EDGE": "automatic"]).style)" == "\(ScrollEdgeEffectStyle.automatic)")
		let off = options(["ARX_SCROLL_EDGE": "off"])
		#expect(off.isHidden && !off.isProgressive && off.hiddenEdges == .all)
		#expect(!options(["ARX_SCROLL_POCKET_HIDER": "0"]).hidesSeparator)
		#expect(!options(["ARX_SCROLL_POCKET_ADAPTIVE": "0"]).isAdaptive)
		// The tuner turns the progressive edge on with it.
		let tuner = options(["ARX_SCROLL_EDGE_TUNER": "1"])
		#expect(tuner.showsTuner && tuner.isProgressive && tuner.isHidden)
		#expect(!standard.showsTuner && !progressive.showsTuner)
	}

	/// The tuner's values start at the built-in ones, list one per line to paste back, and reset
	/// to the built-in ones (DEV-808). The blur takes a new radius and plateau live.
	@Test
	@MainActor
	internal func progressiveEdgeTuningListsAndResetsItsValues() {
		let tuning = ArxProgressiveEdgeTuning()
		#expect(tuning.radius == ArxVariableBlur.radius)
		#expect(tuning.plateau == ArxVariableBlur.plateau)
		tuning.radius = 3
		tuning.veilTop = 0.5
		#expect(tuning.summary.contains("radius: 3.00"))
		#expect(tuning.summary.contains("veilTop: 0.50"))
		#expect(tuning.summary.split(separator: "\n").count == 6)
		tuning.reset()
		#expect(tuning.radius == ArxVariableBlur.radius)
		#expect(tuning.veilTop == 0.7)

		let blur = ArxVariableBlur.BlurView(radius: 6, plateau: 0.35)
		blur.frame = .init(x: 0, y: 0, width: 100, height: 80)
		blur.layoutSubtreeIfNeeded()
		blur.update(radius: 2, plateau: 0.5)
		blur.layoutSubtreeIfNeeded()
		let filter = blur.layer?.filters?.first as? NSObject
		#expect((filter?.value(forKey: "inputRadius") as? NSNumber)?.doubleValue ?? 2 == 2)
	}

	/// The sidebar's edges have their own, denser veil (Max's values, 17 Nov), which hides rows
	/// clipping under the window's toolbar row. Every other bar keeps the standard style, which
	/// the tuner starts from, adjusts and resets to; an edge is standard unless it says otherwise.
	@Test
	@MainActor
	internal func sidebarEdgeHasItsOwnStyleAndTheStandardOneIsUnchanged() {
		#expect(ArxProgressiveEdge.Style.sidebar == .init(
			radius: 2,
			plateau: 0.55,
			veilTop: 0.95,
			veilPlateau: 0.6,
			veilLate: 0.6,
			translucentVeil: 0.1
		))
		#expect(ArxProgressiveEdge.Style.standard == .init(
			radius: 2,
			plateau: 0.55,
			veilTop: 0.7,
			veilPlateau: 0.3,
			veilLate: 0.15,
			translucentVeil: 0.1
		))
		#expect(ArxProgressiveEdge(veil: .chrome).style == .standard)
		#expect(ArxProgressiveEdge(background: nil, edge: .bottom).style == .standard)

		let tuning = ArxProgressiveEdgeTuning()
		#expect(tuning.style == .standard)
		tuning.veilTop = 0.5
		#expect(tuning.style.veilTop == 0.5)
		tuning.reset()
		#expect(tuning.style == .standard)
	}

	/// The progressive blur's mask is opaque (full blur) down to its ramp and eases to clear
	/// (no blur) across it, so the blur melts out below the bar rather than stopping at a line.
	@Test
	@MainActor
	internal func variableBlurMaskEasesOutAcrossItsRamp() throws {
		let height: CGFloat = 124
		let ramp = height * (1 - ArxVariableBlur.plateau)
		let image = try #require(ArxVariableBlur.BlurView.mask(height: height, ramp: ramp))
		let data = try #require(image.dataProvider?.data as Data?)
		func alpha(atRow row: Int) -> UInt8 { data[row * image.bytesPerRow + 1] }
		#expect(image.height == Int(height))
		#expect(alpha(atRow: 0) == 255)
		#expect(alpha(atRow: Int((height - ramp).rounded(.down)) - 1) == 255)
		#expect(alpha(atRow: Int(height) - 1) < 8)
		let middle = alpha(atRow: Int(height - ramp / 2))
		#expect(middle > 64 && middle < 192)
		// It only ever eases out going down.
		for row in 1..<Int(height) {
			#expect(alpha(atRow: row) <= alpha(atRow: row - 1))
		}
	}

	/// The progressive edge is off at rest, so nothing below the bar is blurred or veiled before
	/// content scrolls under it, and comes in over its reveal distance of scrolling, in tenths.
	@Test
	@MainActor
	internal func progressiveEdgeComesInOnlyOnceContentScrollsUnderTheBar() {
		let overhang = ArxVariableBlur.revealDistance
		#expect(ArxProgressiveEdge.reveal(scrolledBy: -30) == 0)
		#expect(ArxProgressiveEdge.reveal(scrolledBy: 0) == 0)
		#expect(ArxProgressiveEdge.reveal(scrolledBy: overhang / 2) == 0.5)
		#expect(ArxProgressiveEdge.reveal(scrolledBy: overhang) == 1)
		#expect(ArxProgressiveEdge.reveal(scrolledBy: 900) == 1)
		// Stepped, so small scrolls don't update the bar every tick.
		#expect(
			ArxProgressiveEdge.reveal(scrolledBy: overhang * 0.52)
			== ArxProgressiveEdge.reveal(scrolledBy: overhang * 0.48)
		)
	}

	/// The separator hider finds its scroll view by how well their frames match (DEV-807): equal
	/// frames match fully, a scroll view running 32 points into the title bar still matches
	/// well, and a sidebar's scroll view beside it doesn't.
	@Test
	internal func scrollViewBehindABarIsTheBestMatchingFrame() {
		let pane = CGRect(x: 0, y: 0, width: 300, height: 400)
		#expect(ArxScrollPocketSeparator.overlap(pane, pane) == 1)
		#expect(ArxScrollPocketSeparator.overlap(pane, CGRect(x: 0, y: 0, width: 300, height: 432)) > 0.9)
		#expect(ArxScrollPocketSeparator.overlap(pane, CGRect(x: 300, y: 0, width: 200, height: 400)) == 0)
		#expect(ArxScrollPocketSeparator.overlap(pane, CGRect(x: 0, y: 0, width: 300, height: 1_000)) < 0.5)
		// A narrower scroll view lies wholly within its background (DEV-826).
		#expect(ArxScrollPocketSeparator.containment(of: CGRect(x: 120, y: 0, width: 60, height: 400), in: pane) == 1)
		#expect(ArxScrollPocketSeparator.containment(of: CGRect(x: 280, y: 0, width: 60, height: 400), in: pane) < 0.5)
	}

	/// A scroll view narrower than the background behind it still gets its pocket hidden
	/// (DEV-826): the hider used to look only for a frame matching its own, so the pocket under
	/// such a bar kept AppKit's blur, with a hard cut and a line, at rest, scrolled, overscrolled
	/// and after the bar redraws.
	@Test
	@MainActor
	internal func barOverANarrowScrollViewHidesItsPocket() throws {
		let view = ScrollView {
			VStack(spacing: 8) {
				ForEach(0..<60) { index in
					Text(verbatim: "Row \(index)").padding(8)
				}
			}
		}
		.arxScrollBar {
			Text(verbatim: "Bar")
				.frame(width: 200, height: 52)
		}
		.frame(maxWidth: .infinity)
		let (window, scrollView) = try Self.host(view, scrolled: false, settingsWindow: true, options: .init())
		defer { window.close() }
		try #require(scrollView.frame.width < 150)

		func expectHidden() throws {
			let pockets = ArxScrollPocketSeparator.pockets(of: scrollView)
				.filter { ArxScrollPocketSeparator.edge(of: $0, in: scrollView) == .top }
			try #require(!pockets.isEmpty)
			#expect(pockets.allSatisfy { $0.isHidden })
		}
		try expectHidden()
		for offset in [200, -scrollView.contentInsets.top - 40, 100] {
			scrollView.contentView.scroll(to: .init(x: 0, y: offset))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			RunLoop.main.run(until: .now.addingTimeInterval(0.1))
			try expectHidden()
		}
	}

	/// A pocket AppKit shows again by itself is hidden again (DEV-826): on screen, hovering the
	/// bar or rubber-banding past the top showed the pocket's blur and line under the chats'
	/// bars, though the hider had hidden it.
	@Test
	@MainActor
	internal func pocketShownAgainIsHiddenAgain() throws {
		let view = ScrollView {
			Self.rows
		}
		.arxScrollBar(background: nil) {
			Text(verbatim: "Bar").frame(maxWidth: .infinity).frame(height: 52)
		}
		let (window, scrollView) = try Self.host(view, scrolled: true, settingsWindow: true, options: .init())
		defer { window.close() }
		let pocket = try #require(
			ArxScrollPocketSeparator.pockets(of: scrollView).first { pocket in
				ArxScrollPocketSeparator.edge(of: pocket, in: scrollView) == .top
			}
		)
		try #require(pocket.isHidden)

		pocket.isHidden = false
		RunLoop.main.run(until: .now.addingTimeInterval(0.1))
		#expect(pocket.isHidden)
	}

	/// A floating footer, as a chat's composer (DEV-826): content scrolls under it, so the scroll
	/// view runs down behind it, and no pocket shows there, so nothing blurs it with a hard cut
	/// or a line; the bar on top keeps the progressive edge.
	@Test
	@MainActor
	internal func floatingFooterHasNoEdgeUnderIt() throws {
		let view = ScrollView {
			Self.rows
		}
		.arxScrollBar(background: nil) {
			Text(verbatim: "Bar").frame(maxWidth: .infinity).frame(height: 52)
		} footer: {
			Text(verbatim: "Composer").frame(maxWidth: .infinity).frame(height: 80)
		}
		let (window, scrollView) = try Self.host(view, scrolled: true, settingsWindow: true, options: .init())
		defer { window.close() }

		#expect(scrollView.contentInsets.bottom >= 80)
		#expect(scrollView.frame.height >= 400 - 1)
		for pocket in ArxScrollPocketSeparator.pockets(of: scrollView) where pocket.frame.height > 0 {
			#expect(pocket.isHidden)
		}
	}

	/// The progressive edge also runs from the bottom, over a footer (DEV-826): its mask is
	/// opaque at the bottom and eases out going up, and a ramp in points becomes the share of the
	/// height at full strength.
	@Test
	@MainActor
	internal func progressiveEdgeRunsFromTheBottomAndTakesARampInPoints() throws {
		let height: CGFloat = 100
		let image = try #require(ArxVariableBlur.BlurView.mask(height: height, ramp: 40, edge: .bottom))
		let data = try #require(image.dataProvider?.data as Data?)
		func alpha(atRow row: Int) -> UInt8 { data[row * image.bytesPerRow + 1] }
		#expect(alpha(atRow: Int(height) - 1) == 255)
		#expect(alpha(atRow: 50) == 255)
		#expect(alpha(atRow: 0) < 8)
		for row in 1..<Int(height) {
			#expect(alpha(atRow: row) >= alpha(atRow: row - 1))
		}

		#expect(ArxProgressiveEdge.plateau(height: 200, ramp: 32) == 0.84)
		#expect(ArxProgressiveEdge.plateau(height: 20, ramp: 32) == 0)
		#expect(ArxProgressiveEdge.plateau(height: 0, ramp: 32) == 0)
	}

	/// A modal's pinned footer gets the same soft edge above it, with no line either (DEV-807).
	@Test
	@MainActor
	internal func modalFooterGetsTheSoftEdgeToo() throws {
		let view = ArxModalScaffold {
			Text(verbatim: "Bar").frame(maxWidth: .infinity).frame(height: 52)
		} content: {
			Self.rows
		} footer: {
			Text(verbatim: "Footer").frame(height: 40)
		}
		let (window, scrollView) = try Self.host(view, scrolled: true, settingsWindow: false)
		defer { window.close() }
		try Self.expectSoftEdge(on: scrollView, pocketKey: "topPocketStyle", minimumHeight: 52)
		#expect((scrollView.value(forKey: "bottomPocketStyle") as? NSNumber)?.intValue == 1)
		for pocket in ArxScrollPocketSeparator.pockets(of: scrollView) where pocket.frame.height > 0 {
			#expect(ArxScrollPocketSeparator.allowsSeparator(pocket) == false)
		}
	}

	private static var rows: some View {
		VStack(spacing: 8) {
			ForEach(0..<60) { index in
				Text(verbatim: "Row \(index)")
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(8)
			}
		}
	}

	@MainActor
	private static func host(
		_ view: some View,
		scrolled: Bool,
		settingsWindow: Bool,
		options: ArxScrollEdgeOptions = .soft
	) throws -> (NSWindow, NSScrollView) {
		let host = NSHostingView(
			rootView: view
				.frame(width: 300, height: 400)
				.environment(\.arxScrollEdgeOptions, options)
		)
		let window = NSWindow(
			contentRect: .init(x: -10_000, y: -10_000, width: 300, height: 400),
			styleMask: settingsWindow ? [.titled, .closable, .fullSizeContentView] : [.borderless],
			backing: .buffered,
			defer: false
		)
		if settingsWindow {
			window.titleVisibility = .hidden
			window.titlebarAppearsTransparent = true
		}
		window.isReleasedWhenClosed = false
		window.contentView = host
		func settle() {
			for _ in 0..<4 {
				host.layoutSubtreeIfNeeded()
				RunLoop.main.run(until: .now.addingTimeInterval(0.05))
			}
		}
		settle()
		let scrollView = try #require(Self.scrollView(in: host))
		if scrolled {
			scrollView.contentView.scroll(to: .init(x: 0, y: 200))
			scrollView.reflectScrolledClipView(scrollView.contentView)
			settle()
		}
		return (window, scrollView)
	}

	@MainActor
	private static func expectSoftEdge(
		on scrollView: NSScrollView,
		pocketKey: String,
		minimumHeight: CGFloat
	) throws {
		// 1 is AppKit's soft style (0 automatic, 2 hard).
		#expect((scrollView.value(forKey: pocketKey) as? NSNumber)?.intValue == 1)

		let pocket = try #require(
			ArxScrollPocketSeparator.pockets(of: scrollView).first { $0.frame.height >= minimumHeight }
		)
		#expect(ArxScrollPocketSeparator.allowsSeparator(pocket) == false)

		let layers = Self.layers(in: try #require(pocket.layer))
		let blur = layers.first { $0.name == "ThinFilmContentBlurFill" }
		#expect(blur?.isHidden == false)
		#expect((blur?.filters ?? []).contains { "\($0)".contains("variableBlur") })
		// Any separator left in the pocket is invisible.
		for separator in layers where separator.name == "Separator" {
			#expect(separator.isHidden || separator.opacity == 0 || separator.frame.width == 0)
		}
	}

	@MainActor
	private static func scrollView(in view: NSView) -> NSScrollView? {
		if let scrollView = view as? NSScrollView { return scrollView }
		return view.subviews.lazy.compactMap(scrollView(in:)).first
	}

	@MainActor
	private static func scrollViews(in view: NSView) -> [NSScrollView] {
		if let scrollView = view as? NSScrollView { return [scrollView] }
		return view.subviews.flatMap(scrollViews(in:))
	}

	@MainActor
	private static func hider(in view: NSView) -> ArxScrollPocketSeparator.HiderView? {
		if let hider = view as? ArxScrollPocketSeparator.HiderView { return hider }
		return view.subviews.lazy.compactMap(hider(in:)).first
	}

	private static func layers(in layer: CALayer) -> [CALayer] {
		[layer] + (layer.sublayers ?? []).flatMap(layers(in:))
	}
}
