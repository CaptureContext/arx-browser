import Foundation

/// Sentences translated whole (DEV-996). A segment is the text of one block, such as a
/// paragraph, heading or list item, up to a line break, split into runs at its text nodes: a
/// link, a bold word or code inside a sentence is a run of its own. Every run is sent, so the
/// sentence keeps its meaning, and each run's translation goes back into its own node, so links
/// stay links. When the translation puts the runs in another order, the block's inline pieces
/// move to that order (Show Original moves them back). Runs in `code`, `kbd`, `samp`, `var` or
/// `translate="no"` are sent for context and kept as they are; editable and hidden text isn't
/// read at all.
extension PageTranslationScripts {
	public struct Run: Codable, Equatable, Sendable {
		public var text: String

		/// False keeps the run's text as it is.
		public var translate: Bool

		/// The run is the block's own text, in no inline element such as a link.
		public var plain: Bool

		public init(
			text: String,
			translate: Bool = true,
			plain: Bool = false
		) {
			self.text = text
			self.translate = translate
			self.plain = plain
		}

		public init(from decoder: any Decoder) throws {
			let values = try decoder.container(keyedBy: CodingKeys.self)
			self.text = try values.decode(String.self, forKey: .text)
			self.translate = try values.decode(Bool.self, forKey: .translate)
			self.plain = try values.decodeIfPresent(Bool.self, forKey: .plain) ?? false
		}
	}

	/// One block's text, waiting for its translation.
	public struct Segment: Codable, Equatable, Sendable {
		public var id: Int
		public var runs: [Run]

		public init(
			id: Int,
			runs: [Run]
		) {
			self.id = id
			self.runs = runs
		}
	}

	/// A stretch of a translation, in the translation's order: a run's words, or (`run` nil)
	/// words that follow a kept run and belong to no run, which go in a node of their own.
	public struct Placement: Codable, Equatable, Sendable {
		public var run: Int?
		public var text: String

		public init(
			run: Int?,
			text: String
		) {
			self.run = run
			self.text = text
		}

		/// `run` is always written, as `null` for the words of no run, so the page script sees it.
		public func encode(to encoder: any Encoder) throws {
			var values = encoder.container(keyedBy: CodingKeys.self)
			try values.encode(run, forKey: .run)
			try values.encode(text, forKey: .text)
		}
	}

	/// A segment's translation: one text per run, nil keeping that run's text, and the order
	/// the runs take when the translation moved them.
	public struct TranslatedSegment: Codable, Equatable, Sendable {
		public var id: Int
		public var texts: [String?]

		/// Nil when the runs keep their order.
		public var order: [Placement]?

		public init(
			id: Int,
			texts: [String?],
			order: [Placement]? = nil
		) {
			self.id = id
			self.texts = texts
			self.order = order
		}
	}

	/// A segment's runs, translated: each run's text and, when it moved, their order.
	public struct Arrangement: Equatable, Sendable {
		public var texts: [String?]
		public var order: [Placement]?

		public init(
			texts: [String?],
			order: [Placement]? = nil
		) {
			self.texts = texts
			self.order = order
		}
	}

	/// Arranges a provider's translation, given as pieces in its own order: a run's pieces join
	/// in its node; words outside every run join the translated run before them, or, after a
	/// kept run, become a piece of their own; words before every run join the segment's first
	/// translated run. Nil when nothing with a letter came back.
	public static func arrange(
		_ chunks: [Placement],
		runs: [Run]
	) -> Arrangement? {
		guard runs.contains(where: \.translate) else { return nil }
		var pieces: [Placement] = []
		var prefix = ""
		var placed: Set<Int> = []
		for chunk in chunks where !chunk.text.isEmpty {
			if let run = chunk.run, runs.indices.contains(run) {
				if pieces.last?.run == run {
					pieces[pieces.count - 1].text += chunk.text
				} else if placed.contains(run) {
					// A run the translation split around another: its later words go in a node of
					// their own where they fall, or join the words of no run before them.
					if let last = pieces.last, last.run == nil {
						pieces[pieces.count - 1].text += chunk.text
					} else {
						pieces.append(.init(run: nil, text: chunk.text))
					}
				} else {
					placed.insert(run)
					pieces.append(.init(run: run, text: chunk.text))
				}
			} else if let last = pieces.last {
				if let run = last.run, !runs[run].translate {
					pieces.append(.init(run: nil, text: chunk.text))
				} else {
					pieces[pieces.count - 1].text += chunk.text
				}
			} else {
				prefix += chunk.text
			}
		}
		if !prefix.isEmpty, let first = runs.firstIndex(where: \.translate) {
			if let at = pieces.firstIndex(where: { $0.run == first }) {
				pieces[at].text = prefix + pieces[at].text
			} else {
				pieces.insert(.init(run: first, text: prefix), at: 0)
			}
		}

		var texts: [String?] = runs.map { $0.translate ? "" : nil }
		for piece in pieces {
			guard let run = piece.run, runs[run].translate else { continue }
			texts[run]? += piece.text
		}
		let words = texts.compactMap(\.self) + pieces.filter { $0.run == nil }.map(\.text)
		guard words.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }

		var sequence: [Int] = []
		for case let run? in pieces.map(\.run) where !sequence.contains(run) {
			sequence.append(run)
		}
		let moved = sequence != sequence.sorted() || pieces.contains { $0.run == nil }

		// The order needs only where each run goes and the words of no run.
		let order = moved ? pieces.map { Placement(run: $0.run, text: $0.run == nil ? $0.text : "") } : nil
		return .init(texts: texts, order: order)
	}

	/// Segments read at a time, nearest the visible area first.
	public static let segmentBatchSize: Int = 40

	/// A segment longer than this is cut, and the rest of its block is read next time.
	public static let maximumSegmentCharacters: Int = 4000

	/// Blocks on screen or within a screen of it that aren't translated yet, at most `limit`
	/// segments.
	public static func collectSegments(limit: Int = segmentBatchSize) -> String {
		"""
		const state = globalThis.__arxTranslation ??= { next: 1, pending: new Map(), originals: new Map(), done: new WeakSet() };
		state.active = true;
		const limit = \(max(1, limit));
		const maximumCharacters = \(maximumSegmentCharacters);
		const margin = innerHeight;
		const skipped = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEXTAREA', 'INPUT', 'SELECT', 'OPTION', 'PRE', 'SVG', 'MATH', 'TEMPLATE', 'CANVAS']);
		const kept = new Set(['CODE', 'KBD', 'SAMP', 'VAR']);
		const inline = new Set(['A', 'ABBR', 'B', 'BDI', 'BDO', 'BIG', 'CITE', 'CODE', 'DATA', 'DEL', 'DFN', 'EM', 'FONT', 'I', 'INS', 'KBD', 'LABEL', 'MARK', 'NOBR', 'Q', 'S', 'SAMP', 'SMALL', 'SPAN', 'STRIKE', 'STRONG', 'SUB', 'SUP', 'TIME', 'TT', 'U', 'VAR']);
		const tag = (element) => element.tagName.toUpperCase();
		const untranslated = (element) => element.getAttribute('translate') === 'no' || element.classList.contains('notranslate');
		const blockOf = (element) => {
		  let node = element;
		  while (node.parentElement && node !== document.body && inline.has(tag(node))) node = node.parentElement;
		  return node;
		};
		// The block, or anything around it, is code, a control, editable or untranslated.
		const excluded = (block) => {
		  for (let node = block; node; node = node.parentElement) {
		    if (skipped.has(tag(node)) || node.isContentEditable || untranslated(node)) return true;
		  }
		  return false;
		};
		// Inside the block: editable text and controls are never read.
		const unusable = (element, block) => {
		  if (element.isContentEditable) return true;
		  for (let node = element; node && node !== block; node = node.parentElement) {
		    if (skipped.has(tag(node))) return true;
		  }
		  return false;
		};
		const keeps = (element, block) => {
		  for (let node = element; node && node !== block; node = node.parentElement) {
		    if (kept.has(tag(node)) || untranslated(node)) return true;
		  }
		  return false;
		};
		const range = document.createRange();
		// Text hidden with `visibility`, on itself or from around it, stays on the Mac (DEV-1120).
		const visible = (element) => getComputedStyle(element).visibility === 'visible';
		const shown = (text) => {
		  range.selectNodeContents(text);
		  const rect = range.getBoundingClientRect();
		  return rect.width > 0 || rect.height > 0;
		};
		const segments = [];
		if (!document.body) return segments;
		const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
		const seen = new Set();
		for (let node = walker.nextNode(); node && segments.length < limit; node = walker.nextNode()) {
		  if (state.done.has(node) || !node.parentElement || !/\\p{L}/u.test(node.nodeValue || '')) continue;
		  const block = blockOf(node.parentElement);
		  if (seen.has(block) || excluded(block) || unusable(node.parentElement, block)) continue;
		  range.selectNodeContents(node);
		  const rect = range.getBoundingClientRect();
		  if (rect.width === 0 && rect.height === 0) continue;
		  if (rect.bottom < -margin || rect.top > innerHeight + margin) continue;
		  if (!visible(node.parentElement)) continue;
		  seen.add(block);
		  let nodes = [], sources = [], runs = [], characters = 0;
		  const finish = () => {
		    if (runs.some((run) => run.translate)) {
		      const id = state.next++;
		      state.pending.set(id, { nodes, sources, block });
		      segments.push({ id, runs });
		    }
		    nodes = []; sources = []; runs = []; characters = 0;
		  };
		  const inner = document.createTreeWalker(block, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
		  for (let item = inner.nextNode(); item; item = inner.nextNode()) {
		    if (item.nodeType === Node.ELEMENT_NODE) {
		      // A line break ends a segment: the lines are read apart. The rest of a block with
		      // more lines than the limit is read next time.
		      if (tag(item) === 'BR' && item.parentElement && blockOf(item.parentElement) === block) {
		        finish();
		        if (segments.length >= limit) break;
		      }
		      continue;
		    }
		    if (state.done.has(item) || !item.parentElement || blockOf(item.parentElement) !== block) continue;
		    // A text longer than a segment is cut at a sentence or a space, and the rest is read
		    // next: the node splits in two, which changes nothing on screen.
		    if ((item.nodeValue || '').length > maximumCharacters) {
		      const head = item.nodeValue.slice(0, maximumCharacters);
		      const cut = Math.max(head.lastIndexOf('. '), head.lastIndexOf('! '), head.lastIndexOf('? '), head.lastIndexOf('\\n')) + 1
		        || head.lastIndexOf(' ') + 1 || maximumCharacters;
		      item.splitText(cut);
		    }
		    const value = item.nodeValue || '';
		    // Spaces between inline elements are kept as runs, so words don't join.
		    if (!value) continue;
		    if (unusable(item.parentElement, block)) continue;
		    const letters = /\\p{L}/u.test(value);
		    // Hidden text is read once it shows.
		    if (!visible(item.parentElement) || letters && !shown(item)) continue;
		    if (characters + value.length > maximumCharacters && nodes.length) break;
		    characters += value.length;
		    state.done.add(item);
		    nodes.push(item);
		    sources.push(value);
		    runs.push({ text: value.replace(/\\s+/g, ' '), translate: letters && !keeps(item.parentElement, block), plain: item.parentElement === block });
		  }
		  finish();
		}
		return segments;
		"""
	}

	/// Puts each run's translation into its own node and, when the translation moved them,
	/// the block's inline pieces into the translation's order. Returns how many segments were
	/// placed.
	public static func applySegments(_ translations: [TranslatedSegment]) -> String {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
		let json = (try? encoder.encode(translations)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
		return """
		const state = globalThis.__arxTranslation;
		if (!state) return 0;
		state.moves ??= [];
		let placed = 0;
		for (const { id, texts, order } of \(json)) {
		  const entry = state.pending.get(id);
		  if (!entry) continue;
		  state.pending.delete(id);
		  const { nodes, sources, block } = entry;
		  // The page changed the text while it was being translated: it's read again later.
		  if (nodes.some((node, index) => node.nodeValue !== sources[index])) {
		    for (const node of nodes) state.done.delete(node);
		    continue;
		  }
		  nodes.forEach((node, index) => {
		    const text = texts[index];
		    if (text === null || text === undefined) return;
		    const original = node.nodeValue || '';
		    // In place, a run that starts or ends the segment keeps the block's own spacing.
		    let value = text, lead = '', trail = '';
		    if (!order && index === 0) {
		      lead = original.match(/^\\s*/)[0];
		      value = value.replace(/^\\s+/, '');
		    }
		    if (!order && index === nodes.length - 1) {
		      trail = original.match(/\\s*$/)[0];
		      value = value.replace(/\\s+$/, '');
		    }
		    node.nodeValue = lead + value + trail;
		    // Show Original restores only text the page hasn't changed since.
		    state.originals.set(node, { original, translated: node.nodeValue });
		  });
		  if (order) {
		    // The runs and the words of no run, in the translation's order; runs it left out
		    // follow.
		    const items = [], listed = new Set();
		    for (const piece of order) {
		      if (piece.run === null || piece.run === undefined) {
		        const extra = document.createTextNode(piece.text);
		        // Already in the target language: never read again.
		        state.done.add(extra);
		        items.push({ extra });
		      } else if (nodes[piece.run] && !listed.has(piece.run)) {
		        listed.add(piece.run);
		        items.push({ node: nodes[piece.run] });
		      }
		    }
		    nodes.forEach((node, index) => { if (!listed.has(index)) items.push({ node }); });
		    // Puts a container's children that hold the items in the items' order, then does the
		    // same inside each child that holds several, so runs that share a link or a span
		    // move too. An empty comment marks where each child was: the children take those
		    // places in order, so anything else, such as an image, stays put, and Show Original
		    // puts each back at its own. Words of no run go after the item before them.
		    const arrange = (container, items) => {
		      const childOf = (node) => {
		        let child = node;
		        while (child.parentNode && child.parentNode !== container) child = child.parentNode;
		        return child.parentNode === container ? child : null;
		      };
		      const children = items.map((item) => item.node ? childOf(item.node) : undefined);
		      if (children.some((child) => child === null)) return;
		      // Words of no run between two items of the same child go inside that child.
		      const home = (index) => {
		        let before, after;
		        for (let i = index - 1; i >= 0 && before === undefined; i--) before = children[i];
		        for (let i = index + 1; i < items.length && after === undefined; i++) after = children[i];
		        return before !== undefined && before === after ? before : undefined;
		      };
		      const groups = new Map(), sequence = [], extras = [];
		      for (const [index, item] of items.entries()) {
		        const child = item.extra ? home(index) : children[index];
		        if (item.extra && child === undefined) {
		          sequence.push(item.extra);
		          extras.push(item.extra);
		          continue;
		        }
		        if (!groups.has(child)) {
		          groups.set(child, []);
		          sequence.push(child);
		        }
		        groups.get(child).push(item);
		      }
		      const pieces = [...groups.keys()].sort((a, b) =>
		        (a.compareDocumentPosition(b) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1);
		      const ordered = sequence.filter((child) => groups.has(child));
		      if (extras.length || ordered.some((child, index) => child !== pieces[index])) {
		        const slots = pieces.map((piece) => {
		          const slot = document.createComment('');
		          container.insertBefore(slot, piece);
		          return slot;
		        });
		        let slot = 0, last = null;
		        for (const child of sequence) {
		          if (extras.includes(child)) {
		            if (last) last.after(child); else container.insertBefore(child, slots[0]);
		          } else {
		            container.insertBefore(child, slots[slot++]);
		          }
		          last = child;
		        }
		        state.moves.push({ block: container, pieces, slots, extras });
		      }
		      for (const [child, group] of groups) {
		        if (group.length > 1 && child.nodeType === Node.ELEMENT_NODE) arrange(child, group);
		      }
		    };
		    arrange(block, items);
		  }
		  placed++;
		}
		return placed;
		"""
	}

	/// Splits translated segments into batches whose apply scripts fit the engine's source limit.
	public static func segmentBatches(
		_ segments: [TranslatedSegment],
		maximumBytes: Int = maximumSourceBytes
	) -> [[TranslatedSegment]] {
		let overhead = applySegments([]).utf8.count
		var batches: [[TranslatedSegment]] = []
		var current: [TranslatedSegment] = []
		var bytes = overhead
		for segment in segments {
			// Escaping can grow a text; twice its size is a safe bound.
			let texts = segment.texts.reduce(32) { $0 + ($1?.utf8.count ?? 0) * 2 + 8 }
			let order = segment.order?.reduce(0) { $0 + $1.text.utf8.count * 2 + 24 } ?? 0
			let size = texts + order
			guard size + overhead <= maximumBytes else { continue }
			if bytes + size > maximumBytes, !current.isEmpty {
				batches.append(current)
				current = []
				bytes = overhead
			}
			current.append(segment)
			bytes += size
		}
		if !current.isEmpty { batches.append(current) }
		return batches
	}
}
