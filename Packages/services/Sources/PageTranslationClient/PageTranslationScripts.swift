import Foundation

/// The scripts that read a page's text and put translations in its place (DEV-904). Each is
/// the body of an async function, as the engine's developer world runs it, and returns JSON.
///
/// They keep their state on the developer world's own global, which the page can't see: the
/// text nodes waiting for a translation, and each translated node's original text for Show
/// Original. A node is translated once; new or scrolled-in text is found by the next read.
public enum PageTranslationScripts {
	/// One piece of the page's text, waiting for its translation.
	public struct Piece: Codable, Equatable, Sendable {
		public var id: Int
		public var text: String

		public init(
			id: Int,
			text: String
		) {
			self.id = id
			self.text = text
		}
	}

	/// What the page says it's in and a sample of its text, for detecting its language.
	public struct Sample: Codable, Equatable, Sendable {
		/// The document's `lang`, often empty or wrong.
		public var lang: String
		public var text: String

		public init(
			lang: String,
			text: String
		) {
			self.lang = lang
			self.text = text
		}
	}

	/// The engine runs at most this much source at a time; batches are cut to fit.
	public static let maximumSourceBytes: Int = 60_000

	/// Pieces read at a time, nearest the visible area first.
	public static let batchSize: Int = 80

	public static let sample: String = """
	const text = (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').trim();
	return { lang: document.documentElement.lang || '', text: text.slice(0, 2000) };
	"""

	/// Text nodes on screen or within a screen of it that aren't translated yet, at most
	/// `limit`. Code, inputs, editable text and `translate="no"` stay as they are.
	public static func collect(limit: Int = batchSize) -> String {
		"""
		const state = globalThis.__arxTranslation ??= { next: 1, pending: new Map(), originals: new Map(), done: new WeakSet() };
		state.active = true;
		const limit = \(max(1, limit));
		const margin = innerHeight;
		const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'CODE', 'PRE', 'KBD', 'SAMP', 'VAR', 'SVG', 'MATH', 'TEMPLATE', 'CANVAS']);
		const excluded = (element) => {
		  for (let node = element; node; node = node.parentElement) {
		    if (skipped.has(node.tagName.toUpperCase()) || node.isContentEditable) return true;
		    if (node.getAttribute('translate') === 'no' || node.classList.contains('notranslate')) return true;
		  }
		  return false;
		};
		const pieces = [];
		if (!document.body) return pieces;
		const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
		const range = document.createRange();
		for (let node = walker.nextNode(); node && pieces.length < limit; node = walker.nextNode()) {
		  if (state.done.has(node) || !/\\p{L}/u.test(node.nodeValue || '')) continue;
		  if (!node.parentElement || excluded(node.parentElement)) continue;
		  range.selectNodeContents(node);
		  const rect = range.getBoundingClientRect();
		  if (rect.width === 0 && rect.height === 0) continue;
		  if (rect.bottom < -margin || rect.top > innerHeight + margin) continue;
		  // Text hidden with `visibility` is read once it shows (DEV-1120).
		  if (getComputedStyle(node.parentElement).visibility !== 'visible') continue;
		  const id = state.next++;
		  const text = node.nodeValue.trim();
		  state.done.add(node);
		  state.pending.set(id, { node, text });
		  pieces.push({ id, text });
		}
		return pieces;
		"""
	}

	/// Puts translations in place of their pieces, keeping each node's surrounding spaces.
	/// Returns how many were placed.
	public static func apply(_ translations: [Piece]) -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let json = (try? encoder.encode(translations)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
		return """
		const state = globalThis.__arxTranslation;
		if (!state) return 0;
		let placed = 0;
		for (const { id, text } of \(json)) {
		  const entry = state.pending.get(id);
		  if (!entry) continue;
		  state.pending.delete(id);
		  const { node, text: source } = entry;
		  const original = node.nodeValue || '';
		  // The page changed the text while it was being translated: it's read again later.
		  if (original.trim() !== source) {
		    state.done.delete(node);
		    continue;
		  }
		  const lead = original.match(/^\\s*/)[0];
		  const trail = original.match(/\\s*$/)[0];
		  node.nodeValue = lead + text + trail;
		  // Show Original restores only text the page hasn't changed since.
		  state.originals.set(node, { original, translated: node.nodeValue });
		  placed++;
		}
		return placed;
		"""
	}

	/// Show Original: every translated node gets its text back, and the next Translate starts
	/// over. Returns how many were restored.
	public static let restore: String = """
	const state = globalThis.__arxTranslation;
	if (!state) return 0;
	let restored = 0;
	// DEV-996: inline pieces a translation moved go back to the places their comments mark,
	// and the words of no run go.
	for (const { block, pieces, slots, extras } of (state.moves || []).slice().reverse()) {
	  for (const extra of extras) extra.remove();
	  if (pieces.every((piece) => piece.parentNode === block) && slots.every((slot) => slot.parentNode === block)) {
	    pieces.forEach((piece, index) => block.insertBefore(piece, slots[index]));
	  }
	  for (const slot of slots) slot.remove();
	}
	for (const [node, { original, translated }] of state.originals) {
	  if (node.nodeValue !== translated) continue;
	  node.nodeValue = original;
	  restored++;
	}
	globalThis.__arxTranslation = undefined;
	return restored;
	"""

	/// Splits pieces into batches whose apply scripts fit the engine's source limit.
	public static func batches(
		_ pieces: [Piece],
		maximumBytes: Int = maximumSourceBytes
	) -> [[Piece]] {
		var batches: [[Piece]] = []
		var current: [Piece] = []
		var bytes = apply([]).utf8.count
		for piece in pieces {
			// Escaping can grow a piece; twice its size is a safe bound.
			let size = piece.text.utf8.count * 2 + 32
			guard size + apply([]).utf8.count <= maximumBytes else { continue }
			if bytes + size > maximumBytes, !current.isEmpty {
				batches.append(current)
				current = []
				bytes = apply([]).utf8.count
			}
			current.append(piece)
			bytes += size
		}
		if !current.isEmpty { batches.append(current) }
		return batches
	}
}
