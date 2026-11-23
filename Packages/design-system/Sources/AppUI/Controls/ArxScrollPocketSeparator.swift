import AppKit
import SwiftUI

/// Turns off the separator AppKit's scroll pocket draws under a safe-area bar (DEV-807).
///
/// On macOS 26 and later a scroll view under a safe-area bar gets a pocket on that edge:
/// `NSScrollPocket`. With `.scrollEdgeEffectStyle(.soft, for:)` it draws the soft edge, a
/// variable blur (`ThinFilmContentBlurFill`) over a blurred replay of the background, and a
/// 0.5-point `Separator` layer along its lower edge, white or black at 7 % alpha. That
/// separator is the line DEV-790 saw under Settings' bars; the hard style draws one too. AppKit
/// has no public switch for it, so ``Hider`` sets the pocket's own `allowsSeparator` to false.
/// Where the pocket or that property is missing, as on a future macOS, it does nothing and the
/// system's edge shows as it is.
///
/// It also gives each pocket a backdrop group of its own. AppKit puts every pocket in a window
/// into one group, `TitlebarGroup-<window>`, and backdrop layers in a group share one capture:
/// with two pockets in a window, such as Settings' sidebar and pane, or the browser window's
/// sidebar, chat panel and Library, a pocket blurred another's capture instead of the content
/// under it, so the soft edge showed the plain background and the hard edge a solid color. A
/// sheet has one pocket, which is why its edge looked right. Each pocket now gets
/// `ArxPocket-<id>` (DEV-808).
@MainActor
public enum ArxScrollPocketSeparator {
	private static let pocketClassName: String = "NSScrollPocket"
	private static let allowsSeparatorKey: String = "allowsSeparator"

	/// The pockets on `scrollView`'s edges.
	public static func pockets(of scrollView: NSScrollView) -> [NSView] {
		scrollView.subviews.filter { NSStringFromClass(type(of: $0)) == pocketClassName }
	}

	/// Whether the pocket draws its separator, or nil where it has no such switch.
	public static func allowsSeparator(_ pocket: NSView) -> Bool? {
		guard pocket.responds(to: NSSelectorFromString(allowsSeparatorKey))
		else { return nil }
		return (pocket.value(forKey: allowsSeparatorKey) as? NSNumber)?.boolValue
	}

	/// Turns the separator off on every pocket of `scrollView`, and, when `adaptive` is false,
	/// the pocket's color scheme adaptivity too (a feature flag for DEV-808, see ``ArxScrollEdgeOptions``).
	///
	/// It hides the pockets on `hiddenPockets` themselves. A pocket keeps blurring the bar's whole
	/// height, cut off hard at its lower edge, even with `scrollEdgeEffectHidden(true)`, so a bar
	/// that draws its own edge, as ``ArxVariableBlur``, has to hide it.
	@MainActor
	public static func hide(
		in scrollView: NSScrollView,
		adaptive: Bool = true,
		hiddenPockets: Edge.Set = []
	) {
		for pocket in pockets(of: scrollView) {
			let hides = hiddenPockets.contains(edge(of: pocket, in: scrollView))
			if pocket.isHidden != hides { pocket.isHidden = hides }
			isolateBackdrop(pocket)
			if !adaptive { set(false, forKey: allowsColorSchemeAdaptivityKey, on: pocket) }
			guard allowsSeparator(pocket) == true else { continue }
			set(false, forKey: allowsSeparatorKey, on: pocket)
		}
	}

	/// Which edge of its scroll view a pocket is on, top or bottom, by where it sits.
	internal static func edge(
		of pocket: NSView,
		in scrollView: NSScrollView
	) -> Edge.Set {
		let frame = pocket.convert(pocket.bounds, to: nil)
		let bounds = scrollView.convert(scrollView.bounds, to: nil)

		// Window coordinates grow upward: the top pocket's top is the scroll view's.
		return abs(frame.maxY - bounds.maxY) <= abs(frame.minY - bounds.minY) ? .top : .bottom
	}

	private static let allowsColorSchemeAdaptivityKey: String = "allowsColorSchemeAdaptivity"
	private static let backdropGroupNameKey: String = "backdropGroupName"

	/// The backdrop group a pocket draws its blur in, or nil where it has no such property.
	public static func backdropGroupName(_ pocket: NSView) -> String? {
		guard pocket.responds(to: NSSelectorFromString(backdropGroupNameKey))
		else { return nil }
		return pocket.value(forKey: backdropGroupNameKey) as? String
	}

	/// Gives `pocket` a backdrop group of its own, so its blur captures the content under it
	/// rather than sharing another pocket's capture.
	private static func isolateBackdrop(_ pocket: NSView) {
		let name = "ArxPocket-\(UInt(bitPattern: ObjectIdentifier(pocket).hashValue))"
		guard
			pocket.responds(to: NSSelectorFromString("setBackdropGroupName:")),
			backdropGroupName(pocket) != name
		else { return }
		pocket.setValue(name, forKey: backdropGroupNameKey)
	}

	/// Writes a Boolean switch on a pocket, only when it has one and it's set otherwise.
	private static func set(
		_ value: Bool,
		forKey key: String,
		on pocket: NSView
	) {
		let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
		guard
			pocket.responds(to: NSSelectorFromString(key)),
			pocket.responds(to: NSSelectorFromString(setter)),
			(pocket.value(forKey: key) as? NSNumber)?.boolValue != value
		else { return }
		pocket.setValue(value, forKey: key)
	}

	/// The scroll view a view drawn behind it covers. It looks among the scroll views next to
	/// `view`, then one container up at a time to the window's content view, not looking into
	/// scroll views' own content, for the one whose frame matches `view`'s best, by the share of
	/// their combined area they have in common: the nearest level with a match wins. A scroll view
	/// runs into the title bar where its background doesn't, so the frames needn't be equal.
	///
	/// Failing that, it takes the largest scroll view lying almost wholly within `view`'s frame,
	/// nearest first, as one narrower than the background behind it (DEV-826).
	internal static func scrollView(behind view: NSView) -> NSScrollView? {
		guard let window = view.window else { return nil }
		let area: CGRect = view.convert(view.bounds, to: nil)
		var levels: [NSView] = []
		var level: NSView? = view.superview
		while let current = level {
			levels.append(current)
			if current === window.contentView { break }
			level = current.superview
		}
		let match: (CGRect) -> CGFloat = { frame in
			let overlap = Self.overlap(area, frame)
			return overlap > 0.5 ? overlap : 0
		}
		let contained: (CGRect) -> CGFloat = { frame in
			Self.containment(of: frame, in: area) >= 0.9 ? frame.width * frame.height : 0
		}
		for score in [match, contained] {
			for level in levels {
				if let found = scrollView(under: level, in: window, score: score) { return found }
			}
		}
		return nil
	}

	/// The scroll view under `root` with the highest `score` above zero.
	private static func scrollView(
		under root: NSView,
		in window: NSWindow,
		score: (CGRect) -> CGFloat
	) -> NSScrollView? {
		var best: NSScrollView?
		var bestScore: CGFloat = 0
		func visit(_ candidate: NSView) {
			if let scrollView = candidate as? NSScrollView {
				let value = score(scrollView.convert(scrollView.bounds, to: nil))
				if scrollView.window === window, value > bestScore {
					best = scrollView
					bestScore = value
				}
				return
			}
			candidate.subviews.forEach(visit)
		}
		visit(root)
		return best
	}

	/// The share of `frame`'s area that lies within `area`.
	internal nonisolated static func containment(
		of frame: CGRect,
		in area: CGRect
	) -> CGFloat {
		let common = frame.intersection(area)
		let size = frame.width * frame.height
		guard !common.isNull, size > 0 else { return 0 }
		return common.width * common.height / size
	}

	/// The share of two rects' combined area they have in common: 1 for equal rects, 0 for
	/// rects that don't meet.
	internal nonisolated static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
		let common = a.intersection(b)
		guard !common.isNull else { return 0 }
		let shared = common.width * common.height
		let combined = a.width * a.height + b.width * b.height - shared
		return combined > 0 ? shared / combined : 0
	}

	/// Drawn behind a scroll view, it finds that scroll view and turns its pockets' separators
	/// off.
	///
	/// AppKit makes a pocket when the scroll view lays out with a bar over it and keeps it, with
	/// its separator off, while content scrolls (DEV-808), so the hider looks again only when the
	/// scroll view or the hider itself is laid out at a new size, and once on the next turn of the
	/// run loop after it finds the scroll view. It doesn't watch scrolling and doesn't mark
	/// anything for layout.
	internal struct Hider: NSViewRepresentable {
		internal var adaptive: Bool
		internal var hiddenPockets: Edge.Set

		internal init(
			adaptive: Bool = true,
			hiddenPockets: Edge.Set = []
		) {
			self.adaptive = adaptive
			self.hiddenPockets = hiddenPockets
		}

		internal func makeNSView(context: Context) -> HiderView {
			let view = HiderView()
			view.adaptive = adaptive
			view.hiddenPockets = hiddenPockets
			return view
		}

		internal func updateNSView(
			_ view: HiderView,
			context: Context
		) {
			view.adaptive = adaptive
			view.hiddenPockets = hiddenPockets
		}

		internal static func dismantleNSView(
			_ view: HiderView,
			coordinator: ()
		) {
			view.stopObserving()
		}
	}

	internal final class HiderView: NSView {
		private weak var scrollView: NSScrollView?
		internal var adaptive: Bool = true
		internal var hiddenPockets: Edge.Set = []

		/// How many times it has looked at its scroll view's pockets, for tests that bound its
		/// work while content scrolls (DEV-808).
		private(set) var hideCount: Int = 0

		/// Each pocket's visibility, watched (DEV-826): AppKit shows a pocket again by itself, as
		/// on hovering the bar or rubber-banding past the top in a window on screen, and its blur
		/// and line came back with it. The watch costs nothing while content scrolls.
		private var pocketWatches: [ObjectIdentifier: NSKeyValueObservation] = [:]

		internal override func hitTest(_ point: NSPoint) -> NSView? { nil }

		internal override func isAccessibilityElement() -> Bool { false }

		internal override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			if window == nil { stopObserving() } else { attach() }
		}

		internal override func layout() {
			super.layout()
			attach()
			hide()
		}

		internal func stopObserving() {
			NotificationCenter.default.removeObserver(self)
			pocketWatches.values.forEach { $0.invalidate() }
			pocketWatches = [:]
			scrollView = nil
		}

		@objc
		private func hide() {
			hideCount += 1
			guard let scrollView else { return }
			ArxScrollPocketSeparator.hide(in: scrollView, adaptive: adaptive, hiddenPockets: hiddenPockets)
			watchPockets(of: scrollView)
		}

		/// Hides a pocket again once AppKit shows it, on the next turn of the run loop. Hiding
		/// writes only what differs, so its own write settles at once.
		private func watchPockets(of scrollView: NSScrollView) {
			guard !hiddenPockets.isEmpty else { return }
			for pocket in ArxScrollPocketSeparator.pockets(of: scrollView) {
				let id = ObjectIdentifier(pocket)
				guard pocketWatches[id] == nil else { continue }
				pocketWatches[id] = pocket.observe(\.isHidden, options: [.new]) { [weak self] _, change in
					guard change.newValue == false else { return }

					// After AppKit's own change has finished, on the main run loop.
					RunLoop.main.perform { [weak self] in
						MainActor.assumeIsolated { self?.hide() }
					}
				}
			}
		}

		private func attach() {
			guard
				scrollView?.window == nil || scrollView?.window !== window,
				let found = ArxScrollPocketSeparator.scrollView(behind: self),
				found !== scrollView
			else { return }
			stopObserving()
			scrollView = found

			// A new size can bring a pocket, such as a footer's; scrolling doesn't.
			found.postsFrameChangedNotifications = true
			NotificationCenter.default.addObserver(
				self,
				selector: #selector(hide),
				name: NSView.frameDidChangeNotification,
				object: found
			)

			// AppKit makes the pocket when the scroll view next lays out with its bar.
			Task { @MainActor [weak self] in self?.hide() }
		}
	}
}
