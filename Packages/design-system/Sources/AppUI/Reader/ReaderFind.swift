import BrowserCore
import Foundation

/// A search of reading mode's article for the Find bar (DEV-1066): ⌘F, ⌘G and ⇧⌘G search the
/// article, not the page under it. Each request has its own `serial`, so finding the next match
/// again is a new request; an empty query clears the matches.
public struct ReaderFind: Equatable, Sendable {
	public var query: String
	public var forward: Bool

	/// A new search, from the first match after the article's scroll position (or before it,
	/// backward), rather than the match after the current one.
	public var newSession: Bool
	public var serial: UInt64

	public init(
		query: String = "",
		forward: Bool = true,
		newSession: Bool = true,
		serial: UInt64 = 0
	) {
		self.query = query
		self.forward = forward
		self.newSession = newSession
		self.serial = serial
	}

	/// The request after this one.
	public func next(
		_ query: String,
		forward: Bool,
		newSession: Bool
	) -> Self {
		.init(query: query, forward: forward, newSession: newSession, serial: serial &+ 1)
	}

	/// The script that runs this request in the article. It marks every match in the article's
	/// text, case-insensitively, in a `mark` the reader's style colors, opens the collapsed
	/// sections around the current one and scrolls it to the middle, and returns the matches and
	/// the current one's number, or clears the marks.
	/// A match that spans elements, such as one word half in a link, isn't found.
	internal var script: String {
		"""
		(() => {
		const query = \(Self.literal(query));
		const forward = \(forward);
		const newSession = \(newSession);
		// Kept under a symbol: an article element with a matching id can't stand in for it, as it
		// could for a named window property.
		const key = Symbol.for('arxReaderFind');
		const find = window[key] || (window[key] = { query: '', marks: [], active: -1 });
		const clear = () => {
			const parents = new Set();
			for (const mark of find.marks) {
				const parent = mark.parentNode;
				if (!parent) continue;
				parent.replaceChild(document.createTextNode(mark.textContent), mark);
				parents.add(parent);
			}
			for (const parent of parents) parent.normalize();
			find.query = '';
			find.marks = [];
			find.active = -1;
		};
		// Where a match shows: in a collapsed section, the section's summary.
		const top = (mark) => {
			let shown = mark;
			for (let element = mark.parentElement; element; element = element.parentElement) {
				if (element.tagName === 'DETAILS' && !element.open) shown = element;
			}
			return shown.getBoundingClientRect().top;
		};
		if (!query) { clear(); return null; }
		if (newSession || query !== find.query) {
			clear();
			find.query = query;
			const pattern = new RegExp(query.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'giu');
			const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
				acceptNode: (node) => node.parentElement && node.parentElement.closest('style, script, noscript, title')
					? NodeFilter.FILTER_REJECT
					: NodeFilter.FILTER_ACCEPT
			});
			const nodes = [];
			while (walker.nextNode()) nodes.push(walker.currentNode);
			for (const node of nodes) {
				const text = node.nodeValue;
				const found = [...text.matchAll(pattern)].filter((match) => match[0].length > 0);
				if (found.length === 0) continue;
				const fragment = document.createDocumentFragment();
				let at = 0;
				for (const match of found) {
					fragment.append(text.slice(at, match.index));
					const mark = document.createElement('mark');
					mark.className = 'arx-reader-match';
					mark.textContent = match[0];
					fragment.append(mark);
					find.marks.push(mark);
					at = match.index + match[0].length;
				}
				fragment.append(text.slice(at));
				node.replaceWith(fragment);
			}
			const count = find.marks.length;
			if (count === 0) {
				find.active = -1;
			} else if (forward) {
				const below = find.marks.findIndex((mark) => top(mark) >= 0);
				find.active = below < 0 ? 0 : below;
			} else {
				let above = -1;
				find.marks.forEach((mark, index) => { if (top(mark) < window.innerHeight) above = index; });
				find.active = above < 0 ? count - 1 : above;
			}
		} else if (find.marks.length > 0) {
			const count = find.marks.length;
			find.marks[find.active]?.classList.remove('arx-reader-match-current');
			find.active = (find.active + (forward ? 1 : -1) + count) % count;
		}
		const current = find.marks[find.active];
		if (current) {
			current.classList.add('arx-reader-match-current');
			for (let element = current.parentElement; element; element = element.parentElement) {
				if (element.tagName === 'DETAILS' && !element.open) element.open = true;
			}
			current.scrollIntoView({ block: 'center', inline: 'nearest' });
		}
		return { matches: find.marks.length, active: current ? find.active + 1 : 0 };
		})()
		"""
	}

	/// The Find bar's matches from what `script` returned: nil when it cleared them.
	internal static func result(_ value: Any?) -> BrowserNavigation.FindResult? {
		guard
			let value = value as? [String: Any],
			let matches = (value["matches"] as? NSNumber)?.intValue,
			let active = (value["active"] as? NSNumber)?.intValue
		else { return nil }

		return .init(matches: matches, active: active)
	}

	/// `text` as a JavaScript string literal.
	private static func literal(_ text: String) -> String {
		let json = (try? JSONEncoder().encode(text)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""

		// JSON's string literals are JavaScript's, but for these two separators.
		return json
			.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
			.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
	}
}
