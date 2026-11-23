import WebKit

/// The page's side of the WebKit swipe (DEV-1203): for each sideways wheel, whether something
/// under the pointer scrolls that way (or the page prevented the wheel) and whether its overscroll
/// may leave it, so a carousel or a map keeps its own swipes, as on Chromium pages, where the
/// renderer answers.
///
/// It runs in a content world of its own, where pages can neither see it nor post its messages.
/// It reads the scrollers on the wheel's composed path as the wheel arrives, and whether the page
/// prevented it once its dispatch is over. A scroller in a closed shadow root isn't seen.
/// A wheel in an embedded frame keeps the gesture the page's: the frame can't see the page around it.
internal enum WebKitSwipeScript {
	@MainActor
	internal static let world: WKContentWorld = .world(name: "arx-history-swipe")

	internal static let handlerName = "arxHistorySwipe"

	/// One wheel's answer.
	internal struct Answer: Equatable, Sendable {
		internal var consumed: Bool
		internal var propagatesX: Bool?

		/// When the wheel happened, in milliseconds since 1970.
		internal var time: Double

		internal init(
			consumed: Bool,
			propagatesX: Bool?,
			time: Double
		) {
			self.consumed = consumed
			self.propagatesX = propagatesX
			self.time = time
		}

		internal init?(_ body: Any) {
			guard
				let body = body as? [String: Any],
				let consumed = body["consumed"] as? Bool,
				let time = body["time"] as? Double,
				time.isFinite
			else { return nil }

			self.init(consumed: consumed, propagatesX: body["propagatesX"] as? Bool, time: time)
		}
	}

	@MainActor
	internal static let userScript = WKUserScript(
		source: source,
		injectionTime: .atDocumentStart,
		forMainFrameOnly: false,
		in: world
	)

	internal static let source = #"""
	(() => {
		const handler = window.webkit?.messageHandlers?.arxHistorySwipe;
		if (!handler) return;
		const root = () => document.scrollingElement || document.documentElement;
		// Whether `element` can still scroll toward `direction` (-1 left, 1 right).
		const scrollsToward = (element, style, direction) => {
			const max = element.scrollWidth - element.clientWidth;
			if (max <= 1) return false;
			const offset = style.direction === "rtl" ? max + element.scrollLeft : element.scrollLeft;
			return direction < 0 ? offset > 0.5 : offset < max - 0.5;
		};
		const scrollable = (element, style) => {
			if (element === root()) return style.overflowX !== "hidden" && style.overflowX !== "clip";
			return ["auto", "scroll", "overlay"].includes(style.overflowX);
		};
		// A scroll container, hidden overflow included: its containment holds though wheels can't
		// scroll it.
		const isScrollContainer = (element, style) =>
			element === root() || ["auto", "scroll", "overlay", "hidden"].includes(style.overflowX);
		const contains = (style) => style.overscrollBehaviorX && style.overscrollBehaviorX !== "auto";
		window.addEventListener("wheel", (event) => {
			// A page's own dispatched wheel grants nothing.
			if (!event.isTrusted || !event.deltaX) return;
			const direction = Math.sign(event.deltaX);
			const top = root();
			// The composed path reaches into open shadow roots, where a carousel's scroller may
			// live behind its host.
			const path = event.composedPath().filter((node) => node instanceof Element);
			if (!path.includes(top)) path.push(top);
			let consumed = event.defaultPrevented;
			let propagatesX = true;
			for (const element of path) {
				if (consumed) break;
				const style = getComputedStyle(element);
				if (scrollable(element, style) && scrollsToward(element, style, direction)) {
					consumed = true;
					break;
				}
				// A scroll container's containment holds even when it has nothing to scroll.
				if (isScrollContainer(element, style) && contains(style)) {
					propagatesX = false;
					break;
				}
				if (element === top) {
					if (contains(style)) propagatesX = false;
					break;
				}
			}
			const time = performance.timeOrigin + event.timeStamp;
			// Answered once the event's dispatch is over, so a page listener that runs after this one
			// and prevents the wheel still counts.
			setTimeout(() => {
				try {
					handler.postMessage({ consumed: consumed || event.defaultPrevented, propagatesX, time });
				} catch {}
			}, 0);
		}, { passive: true });
	})();
	"""#
}
