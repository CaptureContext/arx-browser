import Foundation

/// The scripts reading mode runs in the engine's developer world (DEV-1028), which the page can't
/// see. Each is the body of an async function and returns JSON.
///
/// The article is read with Mozilla's Readability from a copy of the page, so the page itself is
/// never touched. Its markup is cut down to plain text markup, with every address absolute, and
/// kept on the developer world's global, from where it's read in slices that fit the engine's
/// result limit.
public enum PageReaderScripts {
	/// What the extraction found: the article's details and its markup's first slice.
	public struct Extraction: Decodable, Equatable, Sendable {
		public var url: String
		public var title: String
		public var byline: String?
		public var siteName: String?
		public var excerpt: String?
		public var lang: String?
		public var dir: String?

		/// The whole markup's length, in UTF-16 code units, as JavaScript counts.
		public var length: Int
		public var chunk: String

		/// Where the next slice starts.
		public var next: Int
	}

	/// One later slice of the markup.
	public struct Slice: Decodable, Equatable, Sendable {
		public var chunk: String
		public var next: Int
	}

	/// The engine runs at most 64 KB of source at a time.
	public static let maximumSourceBytes: Int = 65_536

	/// The engine returns at most 256 KB; a slice of this many UTF-16 code units stays well under
	/// it, even in a script that takes four bytes a character with every quote escaped.
	public static let sliceLength: Int = 30_000

	/// The result size asked of the engine for each read.
	public static let maximumResultBytes: Int = 262_144

	/// Longer articles aren't shown: a page that big isn't one to read this way.
	public static let maximumArticleLength: Int = 4_000_000

	/// Mozilla Readability 0.6.0, Apache-2.0, without its comments and indentation.
	public static let readability: String = resource("Readability")

	/// Readability's `isProbablyReaderable`, which looks at the page without parsing it.
	public static let readerable: String = resource("Readability-readerable")

	/// Whether the page looks like it has an article: enough long paragraphs that aren't hidden.
	public static let probe: String = readerable + "\nreturn isProbablyReaderable(document);\n"

	/// Reads the article from a copy of the page and returns its details and first slice, or
	/// `null` when there's none.
	public static let extract: String = readability + "\n" + extraction

	/// The markup's slice from `offset`. The last slice lets the markup go.
	public static func slice(from offset: Int) -> String {
		"""
		const state = globalThis.__arxReader;
		if (!state || state.url !== location.href) return null;
		const offset = \(max(0, offset));
		\(cut)
		const next = cut(state.html, offset);
		const chunk = state.html.slice(offset, next);
		if (next >= state.html.length) delete globalThis.__arxReader;
		return { chunk, next };
		"""
	}

	private static let extraction: String = """
	const parsed = new Readability(document.cloneNode(true), { charThreshold: 500 }).parse();
	if (!parsed || !parsed.content) return null;
	const kept = new Set(['A', 'ABBR', 'ARTICLE', 'ASIDE', 'B', 'BDI', 'BDO', 'BLOCKQUOTE', 'BR', 'CAPTION', 'CITE', 'CODE', 'COL', 'COLGROUP', 'DATA', 'DD', 'DEL', 'DETAILS', 'DFN', 'DIV', 'DL', 'DT', 'EM', 'FIGCAPTION', 'FIGURE', 'FOOTER', 'H1', 'H2', 'H3', 'H4', 'H5', 'H6', 'HEADER', 'HR', 'I', 'IMG', 'INS', 'KBD', 'LI', 'MAIN', 'MARK', 'NAV', 'OL', 'P', 'PICTURE', 'PRE', 'Q', 'RP', 'RT', 'RUBY', 'S', 'SAMP', 'SECTION', 'SMALL', 'SOURCE', 'SPAN', 'STRONG', 'SUB', 'SUMMARY', 'SUP', 'TABLE', 'TBODY', 'TD', 'TFOOT', 'TH', 'THEAD', 'TIME', 'TR', 'U', 'UL', 'VAR', 'WBR']);
	const removed = new Set(['APPLET', 'AREA', 'AUDIO', 'BASE', 'BUTTON', 'CANVAS', 'DIALOG', 'EMBED', 'FORM', 'FRAME', 'FRAMESET', 'IFRAME', 'INPUT', 'LINK', 'MAP', 'MATH', 'META', 'NOSCRIPT', 'OBJECT', 'OPTION', 'PORTAL', 'SCRIPT', 'SELECT', 'SLOT', 'STYLE', 'SVG', 'TEMPLATE', 'TEXTAREA', 'TRACK', 'VIDEO']);
	const attributes = {
	  '*': ['dir', 'id', 'lang', 'title'],
	  A: ['href'], BLOCKQUOTE: ['cite'], COL: ['span'], COLGROUP: ['span'], DATA: ['value'], DEL: ['datetime'],
	  DETAILS: ['open'], IMG: ['alt', 'height', 'sizes', 'src', 'srcset', 'width'], INS: ['datetime'], LI: ['value'],
	  OL: ['reversed', 'start', 'type'], Q: ['cite'], SOURCE: ['media', 'sizes', 'srcset', 'type'],
	  TD: ['colspan', 'headers', 'rowspan'], TH: ['colspan', 'headers', 'rowspan', 'scope'], TIME: ['datetime']
	};
	const address = (value, isImage) => {
	  try {
	    const url = new URL(value, document.baseURI);
	    if (url.protocol === 'https:' || url.protocol === 'http:') return url.href;
	    if (!isImage && url.protocol === 'mailto:') return url.href;
	    if (isImage && /^data:image\\/(png|gif|jpe?g|webp|avif)[;,]/i.test(value)) return value;
	  } catch (_) {}
	  return null;
	};
	// As browsers read srcset: a candidate's address runs to the next space, so a comma inside
	// it, as in an image service's `w_800,q_auto`, stays part of it.
	const sources = (value) => {
	  const kept = [];
	  let i = 0;
	  while (i < value.length) {
	    while (i < value.length && /[\\s,]/.test(value[i])) i++;
	    let start = i;
	    while (i < value.length && !/\\s/.test(value[i])) i++;
	    let url = value.slice(start, i);
	    let descriptor = '';
	    if (/,$/.test(url)) {
	      url = url.replace(/,+$/, '');
	    } else {
	      start = i;
	      let depth = 0;
	      while (i < value.length && (value[i] !== ',' || depth > 0)) {
	        if (value[i] === '(') depth++;
	        else if (value[i] === ')') depth--;
	        i++;
	      }
	      descriptor = value.slice(start, i).trim();
	      i++;
	    }
	    const safe = url ? address(url, true) : null;
	    if (safe) kept.push(descriptor ? safe + ' ' + descriptor : safe);
	  }
	  return kept.join(', ');
	};
	const clean = (parent) => {
	  for (const node of Array.from(parent.childNodes)) {
	    if (node.nodeType === Node.COMMENT_NODE) { node.remove(); continue; }
	    if (node.nodeType !== Node.ELEMENT_NODE) continue;
	    const tag = node.tagName.toUpperCase();
	    if (removed.has(tag)) { node.remove(); continue; }
	    clean(node);
	    if (!kept.has(tag)) { node.replaceWith(...node.childNodes); continue; }
	    const allowed = attributes[tag] || [];
	    for (const attribute of Array.from(node.attributes)) {
	      const name = attribute.name.toLowerCase();
	      const value = attribute.value.trim();
	      if (!attributes['*'].includes(name) && !allowed.includes(name)) { node.removeAttribute(attribute.name); continue; }
	      let safe = value;
	      if (name === 'href') safe = value.startsWith('#') ? value : address(value, false);
	      else if (name === 'src') safe = address(value, true);
	      else if (name === 'srcset') safe = sources(value);
	      else if (name === 'cite') safe = address(value, false);
	      if (safe) node.setAttribute(attribute.name, safe); else node.removeAttribute(attribute.name);
	    }
	    if (tag === 'IMG' && !node.getAttribute('src') && !node.getAttribute('srcset')) node.remove();
	  }
	};
	const template = document.createElement('template');
	template.innerHTML = parsed.content;
	clean(template.content);
	const html = template.innerHTML;
	if (!html.trim() || html.length > \(maximumArticleLength)) return null;
	globalThis.__arxReader = { url: location.href, html };
	\(cut)
	const next = cut(html, 0);
	if (next >= html.length) delete globalThis.__arxReader;
	const text = (value) => typeof value === 'string' && value.trim() ? value.trim().slice(0, 1000) : null;
	return {
	  url: location.href,
	  title: text(parsed.title) || text(document.title) || '',
	  byline: text(parsed.byline),
	  siteName: text(parsed.siteName),
	  excerpt: text(parsed.excerpt),
	  lang: text(parsed.lang) || text(document.documentElement.lang),
	  dir: text(parsed.dir) || text(document.dir),
	  length: html.length,
	  chunk: html.slice(0, next),
	  next
	};
	"""

	/// Where a slice from `start` ends: `sliceLength` code units on, or one sooner so a character
	/// written as a surrogate pair, such as an emoji, isn't cut in two, which JSON can't carry.
	private static let cut: String = """
	const cut = (text, start) => {
	  let end = Math.min(start + \(sliceLength), text.length);
	  const last = text.charCodeAt(end - 1);
	  if (end < text.length && end - 1 > start && last >= 0xD800 && last <= 0xDBFF) end -= 1;
	  return end;
	};
	"""

	private static func resource(_ name: String) -> String {
		guard
			let url = Bundle.module.url(forResource: name, withExtension: "js"),
			let text = try? String(contentsOf: url, encoding: .utf8)
		else { return "" }

		return text
	}
}
