import AppKit
import Foundation

/// Arx's own element picker for Hide Element (DEV-1201), in place of uBlock Origin's: an
/// accent-colored rounded outline with a soft fill on the element under the pointer and a chip
/// on its top-leading corner naming it. ↑ and ↓ widen to the parent or narrow back, a click or
/// Return hides it, Esc leaves. What's picked becomes a `host##selector` line of My filters, as
/// uBlock's picker writes, so it stays hidden and the site menu lists it.
///
/// The picker runs in the page's translation world, the app's own isolated world of the main
/// frame: the page's scripts can't see or drive it, and its content security policy doesn't
/// apply (its styles are constructed sheets in a closed shadow root). Same-origin frames are
/// looked into; a cross-origin frame is picked as a whole. While it's open, the app's own view
/// over the page (``ChromiumElementPickerInput``) takes the pointer and the keys and hands them
/// to the script as commands, so the page's document never gets an event a pick makes, and the
/// wheel still scrolls the page.
public enum ChromiumElementPicker {
	/// How the picker draws: Arx's accent and the text on it, the page's zoom, which the outline
	/// and chip undo so they keep their size on screen, and whether to skip the hide animation.
	public struct Style: Equatable, Sendable {
		/// Gamma-encoded sRGB, `0 ... 1`.
		public var accent: Color
		public var onAccent: Color
		public var zoom: Double
		public var reduceMotion: Bool

		/// Hide Element's mode (DEV-1298): a pick hides the element and the picker stays open for
		/// the next one, until Done. Off, a pick ends the session, as ⇧⌘H's picker did before.
		public var keepsOpen: Bool

		public init(
			accent: Color,
			onAccent: Color,
			zoom: Double = 1,
			reduceMotion: Bool = false,
			keepsOpen: Bool = false
		) {
			self.accent = accent
			self.onAccent = onAccent
			self.zoom = zoom
			self.reduceMotion = reduceMotion
			self.keepsOpen = keepsOpen
		}

		public struct Color: Equatable, Sendable {
			public var red: Double
			public var green: Double
			public var blue: Double

			public init(
				red: Double,
				green: Double,
				blue: Double
			) {
				self.red = red
				self.green = green
				self.blue = blue
			}

			/// `rgb(r, g, b)` in whole channels.
			internal var css: String {
				func channel(_ value: Double) -> Int {
					Int((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded())
				}
				return "rgb(\(channel(red)), \(channel(green)), \(channel(blue)))"
			}
		}

		/// The style as the script reads it, a JSON object.
		internal var json: String {
			let object: [String: Any] = [
				"accentRGB": accent.css,
				"onAccentRGB": onAccent.css,
				"zoom": zoom.isFinite && zoom > 0 ? zoom : 1,
				"reduceMotion": reduceMotion,
				"keepsOpen": keepsOpen,
			]
			guard
				let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
			else { return "{}" }

			return String(decoding: data, as: UTF8.self)
		}
	}

	/// How a picker session ended.
	public enum Outcome: Equatable, Sendable {
		/// The engine can't run the picker on the page.
		case unavailable

		/// Esc, ⇧⌘H again, the page's menu, or the page went away.
		case closed

		/// The element went, and its line is on its way into My filters.
		case hidden(filter: String)

		/// The element went from the page, but the engine wouldn't save its line.
		case refused(filter: String)
	}

	/// What a look at the session says.
	internal struct Event: Decodable, Equatable {
		internal var state: String
		internal var session: Int?
		internal var selector: String?
		internal var label: String?

		/// In the mode that stays open: what was picked since the last look, in order.
		internal var picks: [Pick]?

		/// In the mode that stays open: the outline's box, in the app's view's points from its
		/// top-leading corner, or nil while nothing's outlined.
		internal var target: Box?

		/// What `describe` found, by selector; nil where nothing on the page matches it.
		internal var described: [String: Description?]?

		/// What `unhide` did, by selector: whether the element shows again.
		internal var shown: [String: Bool]?

		internal init(
			state: String,
			session: Int? = nil,
			selector: String? = nil,
			label: String? = nil,
			picks: [Pick]? = nil,
			target: Box? = nil,
			described: [String: Description?]? = nil,
			shown: [String: Bool]? = nil
		) {
			self.state = state
			self.session = session
			self.selector = selector
			self.label = label
			self.picks = picks
			self.target = target
			self.described = described
			self.shown = shown
		}

		internal struct Pick: Decodable, Equatable {
			internal var selector: String
			internal var label: String
			internal var kind: String
		}

		internal struct Box: Decodable, Equatable {
			internal var x: Double
			internal var y: Double
			internal var width: Double
			internal var height: Double

			internal var rect: CGRect { .init(x: x, y: y, width: width, height: height) }
		}
	}

	/// What a hidden element is, for a list of them (DEV-1298): the chip's name for it and its
	/// kind, one of ``ChromiumElementPicker/kinds``.
	public struct Description: Decodable, Equatable, Sendable {
		public var label: String
		public var kind: String

		public init(
			label: String,
			kind: String
		) {
			self.label = label
			self.kind = kind
		}
	}

	/// The kinds the script tells an element apart by: its role, or its tag's, else `element`.
	public static let kinds: Set<String> = [
		"link", "button", "image", "video", "audio", "frame", "list", "listitem", "navigation", "banner",
		"contentinfo", "complementary", "form", "dialog", "region", "article", "textbox", "heading",
		"paragraph", "table", "element",
	]

	/// Opens the picker, or closes it when it's open already, as ⇧⌘H toggles. Its value is an
	/// ``Event``: `active` with the new session, or `closed`. Asked again with the same `request`,
	/// as after a look that timed out, it answers for the session that ask opened instead of
	/// closing it.
	public static func open(
		style: Style,
		request: String = UUID().uuidString
	) -> String {
		let token = (try? JSONSerialization.data(withJSONObject: [request]))
			.map { String(String(decoding: $0, as: UTF8.self).dropFirst().dropLast()) } ?? "\"\""
		return script(style: style.json, request: token)
	}

	/// Hands session `session` what the app's view over the page saw since the last look, then
	/// says what it came to, without waiting: `active`, `picked` with the selector and the chip's
	/// label, once, or `closed`. `backing` is the screen's pixels per point, which with the page's
	/// own ratio turns the view's points into the page's.
	public static func poll(
		session: Int,
		commands: [Command] = [],
		backing: Double = 1
	) -> String {
		let list = commands.map(\.json)
		let json = (try? JSONSerialization.data(withJSONObject: list)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
		let scale = backing.isFinite && backing > 0 ? backing : 1
		return """
		const picker = globalThis.__arxElementPicker;
		return picker ? picker.take(\(session), \(json), \(scale)) : { state: 'closed', session: \(session) };
		"""
	}

	/// What the app's view over the page saw, in the view's points from its top-leading corner.
	public enum Command: Equatable, Sendable {
		case pointer(CGPoint)

		/// The pointer left the page.
		case leave

		/// The page scrolled under a pointer that stayed put.
		case refresh
		case click(CGPoint)

		/// `Escape`, `ArrowUp`, `ArrowDown` or `Enter`.
		case key(String)

		/// A secondary click, which leaves.
		case menu

		/// Shows again what this session hid with `selector` (DEV-1298).
		case unhide(String)

		/// Names what each selector finds on the page, for the list of hidden elements (DEV-1298).
		case describe([String])

		/// A key the app answers (DEV-1298), told in its turn after the input before it; never
		/// sent to the script.
		case app(Key)

		internal var isAppKey: Bool {
			if case .app = self { true } else { false }
		}

		internal var json: [String: Any] {
			func finite(_ value: CGFloat) -> Double { value.isFinite ? Double(value) : 0 }
			return switch self {
			case let .pointer(point): ["type": "pointer", "x": finite(point.x), "y": finite(point.y)]
			case .leave: ["type": "leave"]
			case .refresh: ["type": "refresh"]
			case let .click(point): ["type": "click", "x": finite(point.x), "y": finite(point.y)]
			case let .key(key): ["type": "key", "key": key]
			case .menu: ["type": "menu"]
			case let .unhide(selector): ["type": "unhide", "selector": selector]
			case let .describe(selectors): ["type": "describe", "selectors": selectors]
			case .app: ["type": "app"]
			}
		}
	}

	/// The keys Hide Element's mode leaves to the app (DEV-1298).
	public enum Key: Equatable, Sendable {
		/// Done, or closing the open list.
		case escape

		/// Opens or closes the list of hidden elements.
		case `return`

		/// ⌘Z or Edit › Undo: shows the last element hidden again.
		case undo

		/// ↑ and ↓ while the list is open.
		case up
		case down

		/// Delete while the list is open: shows the selected entry's element again.
		case delete
	}

	/// The identifier of the view the picker lays over the page, which the app's Edit › Undo
	/// leaves ⌘Z to (DEV-1298).
	public static let inputIdentifier: String = "dev.capturecontext.arx.elementPicker"

	/// Closes the picker if it's open.
	public static let close: String = """
	const picker = globalThis.__arxElementPicker;
	if (picker && picker.isOpen()) picker.close('closed');
	return true;
	"""

	/// The site a page's `host##selector` lines name, as the browser names it: the URL's ASCII
	/// host, an IPv6 address in brackets. Nil off the web.
	public static func site(of url: URL) -> String? {
		guard
			let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https",
			let host = url.host(percentEncoded: true)?.lowercased(),
			!host.isEmpty
		else { return nil }

		let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
		return bare.contains(":") ? "[\(bare)]" : bare
	}

	/// The My filters line hiding what `selector` finds on `site`: `site##selector`. Nil for a
	/// selector that is more than a plain CSS selector: a scriptlet, an HTML filter, another kind
	/// of cosmetic filter or one of uBlock's action operators, which do more than hide. The
	/// engine checks the same before it saves a line.
	public static func filter(
		site: String,
		selector: String
	) -> String? {
		guard
			!site.isEmpty,
			!site.contains("#"),
			!site.contains(where: \.isNewline),
			isPlain(selector)
		else { return nil }

		return "\(site)##\(selector)"
	}

	/// The selector of a `site##selector` line; nil for any other.
	public static func selector(of filter: String) -> String? {
		guard let range = filter.range(of: "##") else { return nil }

		let selector = String(filter[range.upperBound...])
		return isPlain(selector) ? selector : nil
	}

	/// What Hide Element's mode tells the app as it goes (DEV-1298).
	public enum HidingEvent: Equatable, Sendable {
		/// The picker is open over the page and takes commands.
		case opened

		/// A pick went from the page and its line into My filters.
		case hidden(filter: String, description: Description)

		/// A pick went from the page, but the engine wouldn't save its line.
		case refused(filter: String)

		/// The outline's box in the page's view's points, top-left origin; nil when there's none.
		case target(CGRect?)

		/// What `describe` found for each line, nil where nothing on the page matches it.
		case described([String: Description?])

		/// What `unhide` did: whether the element shows again now, or waits for the page to load
		/// again without uBlock's rule.
		case shown(filter: String, isVisible: Bool)

		/// A key the app answers.
		case key(Key)
	}

	/// What the app asks of Hide Element's mode (DEV-1298).
	public enum HidingCommand: Equatable, Sendable {
		/// Shows the element of a line this session hid again; the line is the app's to remove.
		case unhide(String)

		/// Names what each line hides on the page.
		case describe([String])

		/// The toast's list opened or closed, which takes ↑, ↓ and Delete.
		case listOpen(Bool)

		/// Done: the picker closes.
		case close
	}

	internal static let maximumSelectorBytes: Int = 8 * 1024

	private static func isPlain(_ selector: String) -> Bool {
		guard
			!selector.isEmpty,
			selector.utf8.count <= maximumSelectorBytes,
			!selector.contains(where: \.isNewline),
			!selector.hasPrefix("+js("),
			!selector.hasPrefix("^")
		else { return false }

		let operations = ["#@#", "#?#", "#$#", "##", ":style(", ":remove(", ":remove-attr(", ":remove-class(", ":watch-attr("]
		return !operations.contains { selector.contains($0) }
	}

	// MARK: - Script

	// The body of an async function, as the engine runs it; it returns an ``Event``.
	private static func script(
		style: String,
		request: String
	) -> String {
		#"""
		const style = \#(style);
		const request = \#(request);
		const previous = globalThis.__arxElementPicker;
		if (previous && previous.isOpen()) {
			if (previous.request === request) return { state: 'active', session: previous.session };
			previous.close('toggled');
			return { state: 'closed', session: previous.session };
		}

		const session = (previous ? previous.session : 0) + 1;
		// A pick the last session hasn't told yet; any other is over.
		const earlier = previous && previous.isUntold() ? previous : null;
		const scale = 1 / (style.zoom > 0 ? style.zoom : 1);
		const reduceMotion = style.reduceMotion || matchMedia('(prefers-reduced-motion: reduce)').matches;
		// Hide Element's mode (DEV-1298): a pick hides and the picker stays for the next one.
		const keepsOpen = style.keepsOpen === true;
		// Picks the app hasn't looked at yet, in order.
		const picks = [];
		// What this session hid, by selector, with the inline display each had, to show again.
		const hiddenHere = new Map();
		// Elements on their way out, which the pointer passes through.
		const gone = new WeakSet();
		// The fade each one went with, which Undo stops; the page's own animations go on.
		const fades = new WeakMap();
		let fade = null;
		const listeners = [];
		let host = null;
		let layer = null;
		let box = null;
		let chip = null;
		let open = true;
		let outcome = { state: 'active' };
		let point = null;
		// The pointer in the app's view's points, which a pinch or a zoom maps anew.
		let viewPoint = null;
		let hovered = null;
		let current = null;
		let widened = [];
		let rehit = false;
		let frame = 0;
		// What the last render drew, in the top viewport, for tests.
		let drawn = null;

		const clean = (text) => String(text || '').replace(/\s+/g, ' ').trim();
		const shorten = (text) => (text.length > 40 ? `${text.slice(0, 39).trimEnd()}…` : text);
		const firstLine = (text) => clean(String(text || '').split('\n').find((line) => clean(line) !== '') || '');

		// A class or id a build tool made up, which changes between deploys or loads.
		const isStable = (token) => token.length > 0 && token.length <= 40 &&
			!/\d{3,}/.test(token) &&
			!/^(css|sc|jsx|svelte|emotion|styled|tw)-/i.test(token) &&
			!/^(is|has)-/i.test(token) &&
			!/^(hover|hovered|focus|focused|active|selected|open|opened|visible|hidden|show|shown|current|disabled|checked|expanded|collapsed)$/i.test(token) &&
			!(/[0-9]/.test(token) && /[A-Z]/.test(token) && /[a-z]/.test(token) && !/[-_]/.test(token));

		const roles = {
			nav: 'navigation', header: 'banner', footer: 'contentinfo', aside: 'complementary', main: 'main',
			form: 'form', section: 'region', article: 'article', dialog: 'dialog', img: 'image', ul: 'list',
			ol: 'list', li: 'listitem', table: 'table', button: 'button', a: 'link', iframe: 'frame',
			video: 'video', audio: 'audio', input: 'textbox', select: 'combobox', textarea: 'textbox',
		};

		// What the chip calls it: its accessible name or text, else its role and tag.
		const nameOf = (element) => {
			const tag = element.localName;
			const label = clean(element.getAttribute('aria-label'));
			if (label) return shorten(label);
			const labelledBy = clean(element.getAttribute('aria-labelledby'));
			if (labelledBy) {
				const text = clean(labelledBy.split(' ')
					.map((id) => element.ownerDocument.getElementById(id))
					.filter(Boolean)
					.map((node) => node.textContent)
					.join(' '));
				if (text) return shorten(text);
			}
			const named = clean(element.getAttribute('alt') || element.getAttribute('title'));
			if (named) return shorten(named);
			if (tag === 'iframe') {
				try {
					return shorten(`Frame · ${new URL(element.src).hostname}`);
				} catch {
					return 'Frame';
				}
			}
			if (!['input', 'textarea', 'select'].includes(tag)) {
				const heading = /^h[1-6]$/.test(tag) ? null : element.querySelector('h1, h2, h3, h4, h5, h6, [role="heading"]');
				const text = firstLine(heading ? heading.innerText : element.innerText);
				if (text) return shorten(text);
			}
			const role = clean(element.getAttribute('role')) || roles[tag];
			return role && role !== tag ? `${role} · ${tag}` : tag;
		};

		// What kind of thing it is, for the list of hidden elements: one of the app's kinds.
		const kinds = ['link', 'button', 'image', 'video', 'audio', 'frame', 'list', 'listitem', 'navigation', 'banner',
			'contentinfo', 'complementary', 'form', 'dialog', 'region', 'article', 'textbox', 'heading', 'paragraph', 'table'];
		const kindOf = (element) => {
			const tag = element.localName;
			const role = clean(element.getAttribute('role')).split(' ')[0];
			const named = role === 'img' ? 'image' : role;
			if (kinds.includes(named)) return named;
			const tagged = /^h[1-6]$/.test(tag) ? 'heading'
				: ({ p: 'paragraph', picture: 'image', svg: 'image', canvas: 'image', frame: 'frame', embed: 'frame', object: 'frame' })[tag] || roles[tag];
			return kinds.includes(tagged) ? tagged : 'element';
		};

		const matchesOnly = (document, selector, element) => {
			try {
				const found = document.querySelectorAll(selector);
				return found.length === 1 && found[0] === element;
			} catch {
				return false;
			}
		};

		const idOf = (element) => {
			const id = element.getAttribute('id');
			if (!id || !isStable(id)) return null;
			const selector = `#${CSS.escape(id)}`;
			return matchesOnly(element.ownerDocument, selector, element) ? selector : null;
		};

		// The element as one step of a selector: its tag, a test id or up to two lasting classes,
		// and its place among its siblings when they'd match it too.
		const stepOf = (element) => {
			let step = CSS.escape(element.localName);
			const testID = element.getAttribute('data-testid');
			if (testID && testID.length <= 60) {
				step += `[data-testid="${CSS.escape(testID)}"]`;
			} else {
				const classes = [...element.classList].filter(isStable).slice(0, 2);
				step += classes.map((name) => `.${CSS.escape(name)}`).join('');
			}
			const parent = element.parentElement;
			if (!parent) return step;
			const alike = [...parent.children].filter((sibling) => {
				try {
					return sibling.matches(step);
				} catch {
					return false;
				}
			});
			if (alike.length > 1) {
				const sameTag = [...parent.children].filter((sibling) => sibling.localName === element.localName);
				step += `:nth-of-type(${sameTag.indexOf(element) + 1})`;
			}
			return step;
		};

		// The rule hides on every page of the site, so a selector of tags and places alone, which
		// would find something else on another page, goes on up to an id, a class or an attribute,
		// or else to the body.
		const isAnchored = (selector) => /[#.[]/.test(selector);

		// The shortest anchored selector, going up from the element, that finds only it in its
		// document.
		const selectorOf = (element) => {
			const document = element.ownerDocument;
			const own = idOf(element);
			if (own) return own;
			const steps = [];
			for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
				const id = node === element ? null : idOf(node);
				if (id) {
					steps.unshift(id);
					const selector = steps.join(' > ');
					if (matchesOnly(document, selector, element)) return selector;
					break;
				}
				steps.unshift(node.localName === 'body' ? 'body' : stepOf(node));
				const selector = steps.join(' > ');
				const anchored = isAnchored(selector) || node.localName === 'body';
				if (anchored && matchesOnly(document, selector, element)) return selector;
				if (steps.length >= 12) break;
			}
			const path = [];
			for (let node = element; node && node !== document.documentElement; node = node.parentElement) {
				const parent = node.parentElement;
				const sameTag = parent ? [...parent.children].filter((sibling) => sibling.localName === node.localName) : [node];
				path.unshift(`${CSS.escape(node.localName)}:nth-of-type(${sameTag.indexOf(node) + 1})`);
			}
			const selector = path.join(' > ');
			return matchesOnly(document, selector, element) ? selector : null;
		};

		// A frame's document, when the picker may look into it: same origin only.
		const frameDocument = (element) => {
			if (element.localName !== 'iframe' && element.localName !== 'frame') return null;
			try {
				return element.contentDocument && element.contentDocument.documentElement ? element.contentDocument : null;
			} catch {
				return null;
			}
		};

		// Where a frame's content starts, in its parent's viewport.
		// A frame scaled by a transform, its own or an ancestor's, scales its content too: `scaleX`
		// and `scaleY` are the drawn size over the laid-out one.
		const contentOrigin = (frameElement) => {
			const rect = frameElement.getBoundingClientRect();
			const computed = getComputedStyle(frameElement);
			const scaleX = frameElement.offsetWidth > 0 ? rect.width / frameElement.offsetWidth : 1;
			const scaleY = frameElement.offsetHeight > 0 ? rect.height / frameElement.offsetHeight : 1;
			const paddingLeft = parseFloat(computed.paddingLeft || '0');
			const paddingTop = parseFloat(computed.paddingTop || '0');
			const paddingRight = parseFloat(computed.paddingRight || '0');
			const paddingBottom = parseFloat(computed.paddingBottom || '0');
			return {
				x: rect.left + (frameElement.clientLeft + paddingLeft) * scaleX,
				y: rect.top + (frameElement.clientTop + paddingTop) * scaleY,
				// The frame's viewport, which clips what's in it.
				width: Math.max(0, frameElement.clientWidth - paddingLeft - paddingRight) * scaleX,
				height: Math.max(0, frameElement.clientHeight - paddingTop - paddingBottom) * scaleY,
				scaleX,
				scaleY,
			};
		};

		// The frame element holding an element's document, in the document above.
		const holderOf = (element) => {
			try {
				return element.ownerDocument.defaultView.frameElement;
			} catch {
				return null;
			}
		};

		// Its box in the top viewport, through the frames it's in, each clipping it to what it shows.
		const rectOf = (element) => {
			const rect = element.getBoundingClientRect();
			let left = rect.left;
			let top = rect.top;
			let right = rect.right;
			let bottom = rect.bottom;
			for (let holder = holderOf(element); holder; holder = holderOf(holder)) {
				const origin = contentOrigin(holder);
				left = Math.max(origin.x + left * origin.scaleX, origin.x);
				top = Math.max(origin.y + top * origin.scaleY, origin.y);
				right = Math.min(origin.x + right * origin.scaleX, origin.x + origin.width);
				bottom = Math.min(origin.y + bottom * origin.scaleY, origin.y + origin.height);
			}
			return { left, top, width: Math.max(0, right - left), height: Math.max(0, bottom - top) };
		};

		const pickable = (element) => element && element !== host &&
			element.localName !== 'html' && element.localName !== 'body' && element.localName !== 'head';

		const frames = 'iframe, frame, embed, object';

		// What's drawn under a point, below the picker's own layer, frames included.
		const isGone = (element) => {
			for (let node = element; node; node = node.parentElement) {
				if (gone.has(node)) return true;
			}
			return false;
		};

		const hitAt = (document, x, y) =>
			document.elementsFromPoint(x, y).find((candidate) => candidate !== host && !isGone(candidate)) || null;

		// The element under a point of the top viewport, inside a same-origin frame there.
		const elementAt = (x, y) => {
			let document = globalThis.document;
			let localX = x;
			let localY = y;
			for (let depth = 0; depth < 8; depth += 1) {
				const element = hitAt(document, localX, localY);
				if (!element) return null;
				const inner = frameDocument(element);
				if (!inner) return pickable(element) ? element : null;
				const origin = contentOrigin(element);
				const innerX = (localX - origin.x) / origin.scaleX;
				const innerY = (localY - origin.y) / origin.scaleY;
				const found = hitAt(inner, innerX, innerY);
				if (!pickable(found)) return element;
				document = inner;
				localX = innerX;
				localY = innerY;
			}
			return null;
		};

		const parentOf = (element) => {
			const parent = element.parentElement;
			if (pickable(parent)) return parent;
			const holder = holderOf(element);
			return pickable(holder) ? holder : null;
		};

		const childAt = (element) => {
			if (!point) return null;
			const inner = frameDocument(element);
			const children = inner ? [inner.body].filter(Boolean).flatMap((body) => [...body.children]) : [...element.children];
			return children.find((child) => {
				const rect = rectOf(child);
				return point.x >= rect.left && point.x <= rect.left + rect.width &&
					point.y >= rect.top && point.y <= rect.top + rect.height;
			}) || null;
		};

		const parseColor = (value) => {
			const match = /rgba?\(([^)]+)\)/.exec(value || '');
			if (!match) return null;
			const parts = match[1].split(/[\s,/]+/).filter(Boolean).map(parseFloat);
			return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
		};

		// Whether the page is dark where the element sits.
		const isDarkAt = (element) => {
			for (let node = element; node; node = node.parentElement || holderOf(node)) {
				const color = parseColor(getComputedStyle(node).backgroundColor);
				if (color && color.a >= 0.5) {
					const channel = (value) => {
						const c = value / 255;
						return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
					};
					return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b) < 0.18;
				}
			}
			return matchMedia('(prefers-color-scheme: dark)').matches &&
				/dark/.test(getComputedStyle(globalThis.document.documentElement).colorScheme || '');
		};

		const accent = parseColor(style.accentRGB) || { r: 10, g: 132, b: 255 };
		const tint = (alpha) => `rgba(${accent.r}, ${accent.g}, ${accent.b}, ${alpha})`;

		const render = () => {
			frame = 0;
			if (!open || !box) return;
			if (rehit) {
				rehit = false;
				hovered = point ? elementAt(point.x, point.y) : null;
				current = hovered;
				widened = [];
			}
			if (!current || !current.isConnected) {
				box.style.opacity = '0';
				chip.style.opacity = '0';
				drawn = null;
				return;
			}
			if (fade) {
				fade.cancel();
				fade = null;
			}
			const rect = rectOf(current);
			const inset = 2 * scale;
			const left = Math.max(1, rect.left - inset);
			const top = Math.max(1, rect.top - inset);
			const right = Math.min(innerWidth - 1, rect.left + rect.width + inset);
			const bottom = Math.min(innerHeight - 1, rect.top + rect.height + inset);
			const width = Math.max(4 * scale, right - left);
			const height = Math.max(4 * scale, bottom - top);
			const dark = isDarkAt(current);
			box.style.transform = `translate(${left}px, ${top}px)`;
			box.style.width = `${width}px`;
			box.style.height = `${height}px`;
			box.style.background = tint(dark ? 0.2 : 0.1);
			box.style.boxShadow = `0 0 0 ${3 * scale}px ${tint(dark ? 0.28 : 0.18)}`;
			box.style.opacity = '1';

			chip.textContent = nameOf(current);
			chip.style.maxWidth = `${Math.max(40, Math.min(320 * scale, innerWidth - 2))}px`;
			const chipHeight = chip.offsetHeight || 18 * scale;
			const chipWidth = chip.offsetWidth || 0;
			const gap = 3 * scale;
			const rtl = getComputedStyle(current).direction === 'rtl';
			const above = top - chipHeight - gap >= 1;
			const chipTop = above ? top - chipHeight - gap : top + 4 * scale;
			const chipLeft = rtl ? left + width - chipWidth - (above ? 0 : 4 * scale) : left + (above ? 0 : 4 * scale);
			// The chip keeps all of its name on screen, however close to an edge the element is.
			const shownLeft = Math.max(1, Math.min(chipLeft, innerWidth - 1 - chipWidth));
			chip.style.transform = `translate(${shownLeft}px, ${chipTop}px)`;
			chip.style.opacity = '1';
			drawn = {
				box: { left, top, width, height },
				chip: { left: shownLeft, top: chipTop, width: chipWidth, height: chipHeight, text: chip.textContent },
				dark,
				border: getComputedStyle(box).borderTopWidth,
				radius: getComputedStyle(box).borderTopLeftRadius,
			};
		};

		const schedule = () => {
			if (!frame) frame = requestAnimationFrame(render);
		};

		const listen = (target, type, handler, options) => {
			target.addEventListener(type, handler, options);
			listeners.push(() => target.removeEventListener(type, handler, options));
		};

		const finish = (state) => {
			if (!open) return;
			open = false;
			if (outcome.state === 'active') outcome = state;
			for (const remove of listeners.splice(0)) remove();
			if (frame) cancelAnimationFrame(frame);
		};

		const removeOverlay = () => {
			if (host) host.remove();
			host = null;
			box = null;
			chip = null;
		};

		// The element goes as a puff of grains drifting off up and to the right, as the outline fades.
		const vanish = (element) => {
			const hide = () => {
				// Undone while it faded: the cancelled fade mustn't hide it again.
				if (keepsOpen && !gone.has(element)) return;
				element.style.setProperty('display', 'none', 'important');
			};
			if (reduceMotion || !host) {
				hide();
				if (keepsOpen) {
					if (box) box.style.opacity = '0';
					if (chip) chip.style.opacity = '0';
					drawn = null;
				} else {
					removeOverlay();
				}
				return;
			}
			const rect = rectOf(element);
			const computed = getComputedStyle(element);
			const ink = parseColor(computed.color) || { r: 128, g: 128, b: 128, a: 1 };
			const paper = parseColor(computed.backgroundColor);
			const grains = Math.max(18, Math.min(90, Math.round(Math.sqrt(rect.width * rect.height) / 4)));
			let longest = 0;
			const made = [];
			for (let index = 0; index < grains; index += 1) {
				const grain = globalThis.document.createElement('div');
				made.push(grain);
				const size = (2 + Math.random() * 2.5) * scale;
				const color = paper && paper.a > 0.3 && Math.random() < 0.5 ? paper : (Math.random() < 0.35 ? accent : ink);
				grain.className = 'grain';
				grain.style.width = `${size}px`;
				grain.style.height = `${size}px`;
				grain.style.background = `rgb(${color.r}, ${color.g}, ${color.b})`;
				const x = rect.left + Math.random() * rect.width;
				const y = rect.top + Math.random() * rect.height;
				grain.style.transform = `translate(${x}px, ${y}px)`;
				layer.appendChild(grain);
				const delay = ((x - rect.left) / Math.max(1, rect.width)) * 160 + Math.random() * 80;
				const duration = 520 + Math.random() * 360;
				longest = Math.max(longest, delay + duration);
				const driftX = (24 + Math.random() * 70) * scale;
				const driftY = -(8 + Math.random() * 34) * scale;
				grain.animate([
					{ transform: `translate(${x}px, ${y}px)`, opacity: 0.85 },
					{ transform: `translate(${x + driftX}px, ${y + driftY}px) scale(0.4)`, opacity: 0 },
				], { duration, delay, easing: 'cubic-bezier(.55, 0, .9, .6)', fill: 'both' });
			}
			const leaving = element.animate([
				{ opacity: 1, filter: 'none', translate: '0 0' },
				{ opacity: 0, filter: 'blur(3px)', translate: `${6 * scale}px ${-3 * scale}px` },
			], { duration: 260, easing: 'ease-in', fill: 'forwards' });
			fades.set(element, leaving);
			leaving.finished.then((animation) => {
				hide();
				animation.cancel();
			}, hide);
			if (box) {
				fade = box.animate([
					{ opacity: 1 },
					{ opacity: 0 },
				], { duration: 320, delay: 120, easing: 'ease-out', fill: 'forwards' });
			}
			if (chip) chip.style.opacity = '0';
			drawn = null;
			if (keepsOpen) {
				setTimeout(() => made.forEach((grain) => grain.remove()), longest + 60);
			} else {
				setTimeout(removeOverlay, longest + 60);
			}
		};

		const pick = () => {
			if (!open || !current) return;
			const element = current;
			const selector = selectorOf(element);
			if (!selector) return;
			if (keepsOpen) {
				picks.push({ selector, label: nameOf(element), kind: kindOf(element) });
				const hidden = hiddenHere.get(selector) || [];
				hidden.push({
					element,
					display: element.style.getPropertyValue('display'),
					priority: element.style.getPropertyPriority('display'),
				});
				hiddenHere.set(selector, hidden);
				gone.add(element);
				hovered = null;
				current = null;
				widened = [];
				vanish(element);
				// What's under the pointer once it's gone is the next to outline.
				setTimeout(moved, reduceMotion ? 0 : 280);
				return;
			}
			finish({ state: 'picked', selector, label: nameOf(element), inFrame: holderOf(element) !== null });
			vanish(element);
		};

		// What `selector` finds in the page and the same-origin frames in it.
		const find = (selector) => {
			const found = [];
			const visit = (document, depth) => {
				try {
					found.push(...document.querySelectorAll(selector));
				} catch {}
				if (depth >= 4) return;
				for (const frameElement of document.querySelectorAll('iframe, frame')) {
					const inner = frameDocument(frameElement);
					if (inner) visit(inner, depth + 1);
				}
			};
			visit(globalThis.document, 0);
			return found.filter((element) => element !== host);
		};

		// Shows again what this session hid with `selector`: whether it shows now. uBlock's rule,
		// once it's reloaded, keeps an element hidden until the page loads again; what this session
		// didn't hide was hidden by that rule from the start.
		const unhide = (selector) => {
			const hidden = hiddenHere.get(selector) || [];
			hiddenHere.delete(selector);
			for (const entry of hidden) {
				gone.delete(entry.element);
				const fade = fades.get(entry.element);
				if (fade) fade.cancel();
				fades.delete(entry.element);
				if (entry.display) {
					entry.element.style.setProperty('display', entry.display, entry.priority);
				} else {
					entry.element.style.removeProperty('display');
				}
				if (!reduceMotion && entry.element.isConnected) {
					entry.element.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 220, easing: 'ease-out' });
				}
			}
			const elements = hidden.length > 0 ? hidden.map((entry) => entry.element) : find(selector);
			moved();
			return elements.every((element) => !element.isConnected || getComputedStyle(element).display !== 'none');
		};

		// What each selector finds, named as the chip names it, for the list of hidden elements.
		const describeAll = (selectors) => {
			const described = {};
			for (const selector of Array.isArray(selectors) ? selectors.slice(0, 200) : []) {
				const element = find(String(selector))[0];
				described[selector] = element ? { label: nameOf(element), kind: kindOf(element) } : null;
			}
			return described;
		};

		const widen = () => {
			if (!current) return;
			const parent = parentOf(current);
			if (!parent) return;
			widened.push(current);
			current = parent;
			schedule();
		};

		const narrow = () => {
			if (!current) return;
			const next = widened.length > 0 ? widened.pop() : childAt(current);
			if (!next) return;
			current = next;
			schedule();
		};

		// Something moved under the pointer, or the pointer did: look again on the next frame.
		const moved = () => {
			rehit = true;
			schedule();
		};

		const build = () => {
			const document = globalThis.document;
			host = document.createElement('arx-element-picker');
			const root = host.attachShadow({ mode: 'closed' });
			layer = root;
			const sheet = new CSSStyleSheet();
			sheet.replaceSync(`
				:host { all: initial; }
				.box, .chip, .grain { position: absolute; left: 0; top: 0; box-sizing: border-box; pointer-events: none; }
				.box {
					border: ${2 * scale}px solid rgb(${accent.r}, ${accent.g}, ${accent.b});
					border-radius: ${6 * scale}px;
					opacity: 0;
					transition: transform .12s cubic-bezier(.2, .8, .2, 1), width .12s cubic-bezier(.2, .8, .2, 1),
						height .12s cubic-bezier(.2, .8, .2, 1), opacity .1s linear;
				}
				.chip {
					max-width: ${320 * scale}px;
					padding: ${2 * scale}px ${6 * scale}px;
					border-radius: ${4 * scale}px;
					background: rgb(${accent.r}, ${accent.g}, ${accent.b});
					color: ${style.onAccentRGB};
					font: 600 ${12 * scale}px/1.35 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
					letter-spacing: 0;
					white-space: nowrap;
					overflow: hidden;
					text-overflow: ellipsis;
					box-shadow: 0 ${1 * scale}px ${3 * scale}px rgba(0, 0, 0, .22);
					opacity: 0;
					transition: transform .12s cubic-bezier(.2, .8, .2, 1), opacity .1s linear;
				}
				.grain { border-radius: 1px; }
			`);
			root.adoptedStyleSheets = [sheet];
			box = document.createElement('div');
			box.className = 'box';
			chip = document.createElement('div');
			chip.className = 'chip';
			root.append(box, chip);
			for (const [property, value] of [
				['position', 'fixed'], ['inset', '0'], ['width', '100%'], ['height', '100%'], ['margin', '0'],
				['padding', '0'], ['border', '0'], ['background', 'transparent'], ['overflow', 'visible'],
				['pointer-events', 'none'], ['z-index', '2147483647'], ['display', 'block'], ['max-width', 'none'],
				['max-height', 'none'], ['color-scheme', 'normal'],
			]) host.style.setProperty(property, value, 'important');
			host.setAttribute('popover', 'manual');
			// Drawn inside the top modal dialog, if there's one, so nothing of the page comes between.
			let modals = [];
			try {
				modals = [...document.querySelectorAll('dialog:modal')];
			} catch {}
			(modals.length > 0 ? modals[modals.length - 1] : document.documentElement).appendChild(host);
			try {
				host.showPopover();
			} catch {}

			// The pointer and the keys come from the app's own view over the page, as commands (see
			// `apply`): the page's document never gets an event while the picker is open, so none of
			// its listeners can act on a pick. Its scrolling still moves what's under the pointer.
			listen(globalThis, 'scroll', moved, { capture: true, passive: true });
			listen(globalThis, 'resize', moved, { passive: true });
			listen(globalThis, 'pagehide', () => {
				finish({ state: 'closed', reason: 'navigation' });
				removeOverlay();
			});
		};

		// A point of the page's view, in the view's own points, as a point of the page's layout
		// viewport: the page's zoom and a pinch's are undone.
		const clientPoint = (x, y, backing) => {
			const ratio = devicePixelRatio > 0 ? (backing > 0 ? backing : 1) / devicePixelRatio : 1;
			const viewport = globalThis.visualViewport;
			const pinch = viewport && viewport.scale > 0 ? viewport.scale : 1;
			return {
				x: (viewport ? viewport.offsetLeft : 0) + (x * ratio) / pinch,
				y: (viewport ? viewport.offsetTop : 0) + (y * ratio) / pinch,
			};
		};

		// What the app's view over the page saw since the last look, in order.
		const apply = (commands, backing) => {
			for (const command of Array.isArray(commands) ? commands : []) {
				if (!open || !command) return;
				switch (command.type) {
				case 'pointer': {
					viewPoint = { x: command.x, y: command.y, backing };
					const next = clientPoint(command.x, command.y, backing);
					if (point && Math.abs(point.x - next.x) + Math.abs(point.y - next.y) <= 2) break;
					point = next;
					moved();
					break;
				}
				case 'leave':
					point = null;
					viewPoint = null;
					moved();
					break;
				case 'refresh':
					if (viewPoint) point = clientPoint(viewPoint.x, viewPoint.y, viewPoint.backing);
					moved();
					break;
				case 'click': {
					// A move the next frame hasn't drawn yet still decides what's under the click; a
					// selection widened or narrowed in place stays.
					viewPoint = { x: command.x, y: command.y, backing };
					const at = clientPoint(command.x, command.y, backing);
					if (!point || Math.abs(point.x - at.x) + Math.abs(point.y - at.y) > 2) {
						point = at;
						rehit = true;
					}
					if (rehit || !current) {
						rehit = true;
						render();
					}
					pick();
					break;
				}
				case 'key':
					// A move not yet looked at decides what the key acts on.
					if (rehit && command.key !== 'Escape') render();
					if (command.key === 'Escape') {
						finish({ state: 'closed', reason: 'escape' });
						removeOverlay();
					} else if (command.key === 'ArrowUp') {
						widen();
					} else if (command.key === 'ArrowDown') {
						narrow();
					} else if (command.key === 'Enter') {
						pick();
					}
					break;
				case 'menu':
					finish({ state: 'closed', reason: 'menu' });
					removeOverlay();
					break;
				case 'unhide':
					shown[command.selector] = unhide(String(command.selector || ''));
					break;
				case 'describe':
					Object.assign(described, describeAll(command.selectors));
					break;
				}
			}
		};

		// What `unhide` and `describe` came to since the last look.
		let shown = {};
		let described = {};

		// The outline's box in the app's view's points, as `clientPoint` reads them back.
		const viewBox = (box, backing) => {
			const ratio = devicePixelRatio > 0 ? (backing > 0 ? backing : 1) / devicePixelRatio : 1;
			const viewport = globalThis.visualViewport;
			const pinch = viewport && viewport.scale > 0 ? viewport.scale : 1;
			const offsetX = viewport ? viewport.offsetLeft : 0;
			const offsetY = viewport ? viewport.offsetTop : 0;
			return {
				x: ((box.left - offsetX) * pinch) / ratio,
				y: ((box.top - offsetY) * pinch) / ratio,
				width: (box.width * pinch) / ratio,
				height: (box.height * pinch) / ratio,
			};
		};

		const api = {
			session,
			request,
			isOpen: () => open,
			isUntold: () => outcome.state === 'picked',
			close: (reason) => {
				finish({ state: 'closed', reason });
				removeOverlay();
			},
			// What the session came to; a pick is told once, then the picker is closed. An earlier
			// session's is still told after a new one opened.
			take: (asked, commands, backing) => {
				if (asked !== session) return earlier ? earlier.take(asked) : { state: 'closed', session: asked };
				apply(commands, backing);
				const told = { ...outcome, session };
				if (keepsOpen) {
					told.picks = picks.splice(0);
					told.target = drawn && open ? viewBox(drawn.box, backing) : null;
					told.shown = shown;
					told.described = described;
					shown = {};
					described = {};
				}
				if (outcome.state !== 'active') outcome = { state: 'closed', reason: 'told' };
				return told;
			},
			describe: (element) => ({ selector: selectorOf(element), label: nameOf(element), kind: kindOf(element) }),
			// An offscreen test window may never run the outline's transitions, so it can skip them.
			hoverForTesting: (element, still) => {
				if (still && box) {
					box.style.transition = 'none';
					chip.style.transition = 'none';
				}
				hovered = element;
				current = element;
				widened = [];
				rehit = false;
				render();
				return drawn;
			},
			currentForTesting: () => current,
			elementAtForTesting: (x, y) => elementAt(x, y),
			pickForTesting: (element) => {
				hovered = element;
				current = element;
				widened = [];
				pick();
				return outcome;
			},
			widenForTesting: widen,
			narrowForTesting: narrow,
		};
		globalThis.__arxElementPicker = api;
		build();
		return { state: 'active', session };
		"""#
	}
}

extension ChromiumRuntime {
	/// Whether this engine runs Arx's own element picker (DEV-1201): it runs the app's scripts in
	/// a page's translation world and saves a picked line to My filters.
	public var supportsElementPicker: Bool {
		supportsTranslationScripts && optionalExports.elementHiding?.hide != nil
	}

	/// Runs Arx's own element picker on `page` until it ends, then saves what was picked to My
	/// filters in the page's profile. ⇧⌘H again closes a picker that's open, which ends this
	/// session as `closed`; so does cancelling the task. `unavailable`, without opening, where
	/// the site wouldn't take what's picked.
	public func pickElement(
		on page: ChromiumPage,
		style: ChromiumElementPicker.Style
	) async -> ChromiumElementPicker.Outcome {
		guard supportsElementPicker, !page.isPrivate, canHideElements(on: page)
		else { return .unavailable }

		let opening = ChromiumElementPicker.open(style: style, request: UUID().uuidString)
		guard let opened = await pickerEvent(on: page, source: opening) else {
			// Cancelled while it opened: it may be on the page with nothing left to save a pick.
			if Task.isCancelled { closePicker(on: page) }
			return .closed
		}
		guard opened.state == "active", let session = opened.session
		else { return .closed }

		// The app's view over the page takes the pointer and the keys while it's open (DEV-1206).
		let input = ChromiumElementPickerInput.install(over: page.view)
		defer { input.remove() }

		let start = ContinuousClock.now
		while ContinuousClock.now - start < Self.longestPickerSession {
			// Looks at once when there's input, else every 100 ms.
			do {
				var waited: Duration = .zero
				repeat {
					try await Task.sleep(for: .milliseconds(16))
					waited += .milliseconds(16)
				} while !input.hasPending && waited < .milliseconds(100)
			} catch {
				closePicker(on: page)
				return .closed
			}

			let commands = input.drain()
			let backing = Double(page.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
			do {
				let source = ChromiumElementPicker.poll(session: session, commands: commands, backing: backing)
				let event: ChromiumElementPicker.Event
				switch try await pickerReply(on: page, source: source) {
				case let .event(reply):
					event = reply

				case .busy:
					// Refused before it ran: the commands go with the next look.
					input.restore(commands)
					continue

				case .timedOut:
					// It may have run, so its commands aren't sent again: a second ↑ would widen twice.
					continue
				}

				switch event.state {
				case "active":
					continue

				case "picked":
					guard
						let selector = event.selector,
						let url = page.navigation.url,
						let site = ChromiumElementPicker.site(of: url),
						let filter = ChromiumElementPicker.filter(site: site, selector: selector)
					else { return .closed }

					return hideElement(filter, on: page) ? .hidden(filter: filter) : .refused(filter: filter)

				default:
					return .closed
				}
			} catch {
				if Task.isCancelled { closePicker(on: page) }
				return .closed
			}
		}

		closePicker(on: page)
		return .closed
	}

	/// Hide Element's mode (DEV-1298): the picker stays open over `page`, each pick saved to My
	/// filters as it's made, until Done, ⇧⌘H again, the page going away or the task being
	/// cancelled. `events` hears each pick, the outline's box, what the app's commands came to
	/// and the keys it answers. `cursor` is the pointer over the page. False, without opening,
	/// where the site wouldn't take what's picked; true once it ends.
	public func hideElements(
		on page: ChromiumPage,
		style: ChromiumElementPicker.Style,
		cursor: NSCursor? = nil,
		events: @escaping @MainActor (ChromiumElementPicker.HidingEvent) -> Void
	) async -> Bool {
		guard supportsElementPicker, !page.isPrivate, canHideElements(on: page)
		else { return false }

		var style = style
		style.keepsOpen = true
		let opening = ChromiumElementPicker.open(style: style, request: UUID().uuidString)
		guard let opened = await pickerEvent(on: page, source: opening) else {
			if Task.isCancelled { closePicker(on: page) }
			return true
		}
		guard opened.state == "active", let session = opened.session
		else { return true }

		let input = ChromiumElementPickerInput.install(over: page.view)
		if let cursor { input.cursor = cursor }
		input.takesAppKeys = true
		defer { input.remove() }
		events(.opened)

		var target: CGRect?
		let start = ContinuousClock.now
		session: while ContinuousClock.now - start < Self.longestPickerSession {
			do {
				var waited: Duration = .zero
				repeat {
					try await Task.sleep(for: .milliseconds(16))
					waited += .milliseconds(16)
				} while !input.hasPending && waited < .milliseconds(100)
			} catch {
				closePicker(on: page)
				return true
			}

			// The input may have been retired by a newer session on the page.
			guard input.superview != nil else { return true }

			// A key the app answers waits for the input before it, so ⌘Z right after a click
			// takes back that click's pick, not the one before.
			var commands = input.drain()
			while true {
				let split = commands.firstIndex(where: \.isAppKey) ?? commands.endIndex
				let scriptCommands = Array(commands[..<split])
				let backing = Double(page.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
				let event: ChromiumElementPicker.Event
				do {
					let source = ChromiumElementPicker.poll(session: session, commands: scriptCommands, backing: backing)
					switch try await pickerReply(on: page, source: source, maximumBytes: 65_536) {
					case let .event(reply):
						event = reply

					case .busy:
						input.restore(commands)
						continue session

					case .timedOut:
						// The script's part may have run; the keys still wait their turn.
						input.restore(Array(commands[split...]))
						continue session
					}
				} catch {
					if Task.isCancelled { closePicker(on: page) }
					return true
				}

				// A look that ends the session still tells what came with it, such as a click or
				// an element shown again in the same batch as Done.
				report(event, input: input, page: page, events: events)
				guard event.state == "active" else { return true }

				let box = event.target?.rect
				if box != target {
					target = box
					events(.target(box))
				}

				var rest = commands[split...]
				while let first = rest.first, case let .app(key) = first {
					events(.key(key))
					rest.removeFirst()
				}
				guard !rest.isEmpty else { break }
				commands = Array(rest)
			}
		}

		closePicker(on: page)
		return true
	}

	/// Tells what a look at Hide Element's mode came to: its picks, saved to My filters, and what
	/// the app's commands did, named by the very lines the app asked about, which may be a parent
	/// domain's.
	private func report(
		_ event: ChromiumElementPicker.Event,
		input: ChromiumElementPickerInput,
		page: ChromiumPage,
		events: @MainActor (ChromiumElementPicker.HidingEvent) -> Void
	) {
		let site = page.navigation.url.flatMap(ChromiumElementPicker.site(of:))
		for pick in event.picks ?? [] {
			guard
				let site,
				let filter = ChromiumElementPicker.filter(site: site, selector: pick.selector)
			else { continue }

			let saved = hideElement(filter, on: page)
			events(saved
			? .hidden(filter: filter, description: .init(label: pick.label, kind: pick.kind))
			: .refused(filter: filter))
		}
		for (selector, isVisible) in (event.shown ?? [:]).sorted(by: { $0.key < $1.key }) {
			let asked = input.unhiddenLines.removeValue(forKey: selector) ?? []
			let fallback = site.flatMap { ChromiumElementPicker.filter(site: $0, selector: selector) }
			for filter in asked.isEmpty ? fallback.map { [$0] } ?? [] : asked {
				events(.shown(filter: filter, isVisible: isVisible))
			}
		}
		var described: [String: ChromiumElementPicker.Description?] = [:]
		for (selector, description) in event.described ?? [:] {
			for filter in input.describedLines.removeValue(forKey: selector) ?? [] {
				described[filter] = description
			}
		}
		if !described.isEmpty { events(.described(described)) }
	}

	/// Hands Hide Element's mode on `page` what the app asks of it (DEV-1298). False when no
	/// mode is open there.
	@discardableResult
	public func sendHidingCommand(
		_ command: ChromiumElementPicker.HidingCommand,
		on page: ChromiumPage
	) -> Bool {
		guard
			let input = ChromiumElementPickerInput.current(over: page.view),
			input.takesAppKeys
		else { return false }

		switch command {
		case let .unhide(filter):
			guard let selector = ChromiumElementPicker.selector(of: filter) else { return false }
			input.unhiddenLines[selector, default: []].append(filter)
			input.enqueue(.unhide(selector))

		case let .describe(filters):
			var selectors: [String] = []
			for filter in filters {
				guard let selector = ChromiumElementPicker.selector(of: filter) else { continue }
				if input.describedLines[selector] == nil { selectors.append(selector) }
				input.describedLines[selector, default: []].insert(filter)
			}
			guard !selectors.isEmpty else { return !input.describedLines.isEmpty }
			input.enqueue(.describe(selectors))

		case let .listOpen(isOpen):
			input.listIsOpen = isOpen

		case .close:
			input.takesAppKeys = false
			input.enqueue(.key("Escape"))
		}
		return true
	}

	/// Closes the picker from a task of its own, which a cancelled session's can't do: the
	/// engine's script requests check for cancellation first.
	private func closePicker(on page: ChromiumPage) {
		Task { @MainActor [weak self] in
			_ = await self?.pickerEvent(on: page, source: ChromiumElementPicker.close)
		}
	}

	/// Whether `page`'s site would take a picked line: an ordinary http(s) page whose profile has
	/// content blocking on, on a site the person didn't turn blocking off for. The engine is
	/// asked without a line.
	public func canHideElements(on page: ChromiumPage) -> Bool {
		guard let hide = optionalExports.elementHiding?.hide
		else { return false }

		return performIfOpen(on: page) { _, id in hide(id, nil) } ?? false
	}

	/// Adds `filter`, `site##selector` for `page`'s own site, to My filters in its profile
	/// (DEV-1201). The engine refuses a trusted site, another site or more than a plain selector.
	public func hideElement(
		_ filter: String,
		on page: ChromiumPage
	) -> Bool {
		guard let hide = optionalExports.elementHiding?.hide
		else { return false }

		return performIfOpen(on: page) { _, id in
			filter.withCString { hide(id, $0) }
		} ?? false
	}

	/// A picker that stays open this long, forgotten in a background tab, closes.
	private static let longestPickerSession: Duration = .seconds(15 * 60)

	private func pickerEvent(
		on page: ChromiumPage,
		source: String
	) async -> ChromiumElementPicker.Event? {
		for _ in 0..<20 {
			do {
				if let event = try await pickerEventOrBusy(on: page, source: source) { return event }
				try await Task.sleep(for: .milliseconds(50))
			} catch {
				return nil
			}
		}
		return nil
	}

	/// The script's event; nil while another of the app's scripts holds the page, or when it
	/// didn't answer in time. Throws when the page went away or the script failed.
	private func pickerEventOrBusy(
		on page: ChromiumPage,
		source: String
	) async throws -> ChromiumElementPicker.Event? {
		switch try await pickerReply(on: page, source: source) {
		case let .event(event): event
		case .busy, .timedOut: nil
		}
	}

	private enum PickerReply {
		case event(ChromiumElementPicker.Event)

		/// Another of the app's scripts held the page: this one never ran.
		case busy

		/// No answer in time: it may have run.
		case timedOut
	}

	private func pickerReply(
		on page: ChromiumPage,
		source: String,
		maximumBytes: Int = 16_384
	) async throws -> PickerReply {
		let value: ChromiumScriptValue
		do {
			value = try await evaluateTranslationScript(page, source: source, maximumBytes: maximumBytes, timeoutMilliseconds: 2_000)
		} catch ChromiumDeveloperFailure.busy {
			return .busy
		} catch ChromiumDeveloperFailure.timedOut {
			return .timedOut
		}

		guard
			case let .json(text) = value,
			let event = try? JSONDecoder().decode(ChromiumElementPicker.Event.self, from: Data(text.utf8))
		else { return .event(.init(state: "closed")) }

		return .event(event)
	}
}
