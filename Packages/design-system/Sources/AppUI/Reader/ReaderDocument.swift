import BrowserCore
import Foundation

/// The page reading mode shows (DEV-1028): the article's site, title and byline over its text,
/// in a column of the chosen width, in the chosen theme. It runs no script and loads nothing but
/// images; the article's markup is the page's own, already cut down to text markup.
public enum ReaderDocument {
	/// Images may load from the web; nothing else does, and no script runs.
	public static let contentSecurityPolicy: String =
		"default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'"

	public static func html(
		_ article: ReaderArticle,
		appearance: ReaderAppearance
	) -> String {
		let language = article.language.map { #" lang="\#(escaped($0))""# } ?? ""
		let direction = article.isRightToLeft ? "rtl" : "ltr"
		let site = article.siteName ?? article.url.host(percentEncoded: false) ?? ""
		return """
		<!doctype html>
		<html\(language) dir="\(direction)" data-theme="\(appearance.theme.rawValue)" style="\(variables(appearance))">
		<head>
		<meta charset="utf-8">
		<meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
		<title>\(escaped(article.title))</title>
		<style>\(style)</style>
		</head>
		<body>
		<main>
		<header>
		\(site.isEmpty ? "" : #"<p class="arx-reader-site">\#(escaped(site))</p>"#)
		<h1 class="arx-reader-title">\(escaped(article.title))</h1>
		\(article.byline.map { #"<p class="arx-reader-byline">\#(escaped($0))</p>"# } ?? "")
		</header>
		<article>
		\(article.html)
		</article>
		</main>
		</body>
		</html>
		"""
	}

	/// The script that restyles a shown article, so its scroll position stays.
	public static func restyle(_ appearance: ReaderAppearance) -> String {
		"""
		document.documentElement.dataset.theme = '\(appearance.theme.rawValue)';
		document.documentElement.setAttribute('style', '\(variables(appearance))');
		"""
	}

	internal static func variables(_ appearance: ReaderAppearance) -> String {
		let theme = appearance.theme
		return [
			"--reader-background: \(theme.background)",
			"--reader-text: \(theme.text)",
			"--reader-secondary: \(theme.secondary)",
			"--reader-link: \(theme.link)",
			"--reader-size: \(appearance.textSize)px",
			"--reader-width: \(appearance.width)px",
			"color-scheme: \(theme.isDark ? "dark" : "light")",
		].joined(separator: "; ")
	}

	internal static func escaped(_ text: String) -> String {
		text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "'", with: "&#39;")
	}

	private static let style: String = """
	html { background: var(--reader-background); color: var(--reader-text); }
	body { margin: 0; padding: 72px 32px 96px; font: var(--reader-size)/1.6 ui-serif, "New York", Georgia, serif; -webkit-font-smoothing: antialiased; transition: background-color 0.2s, color 0.2s; }
	main { max-width: var(--reader-width); margin: 0 auto; }
	header { margin-bottom: 2em; }
	.arx-reader-site, .arx-reader-byline { font: 600 0.75em/1.4 -apple-system, system-ui, sans-serif; color: var(--reader-secondary); margin: 0 0 0.6em; letter-spacing: 0.01em; }
	.arx-reader-byline { font-weight: 400; margin-top: 0.8em; }
	h1, h2, h3, h4, h5, h6 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.25; margin: 1.6em 0 0.6em; }
	.arx-reader-title { font-size: 1.9em; margin: 0; }
	p, ul, ol, dl, blockquote, pre, table, figure { margin: 0 0 1.1em; }
	a { color: var(--reader-link); text-decoration: none; }
	a:hover { text-decoration: underline; }
	img, picture, video { max-width: 100%; height: auto; border-radius: 6px; }
	figure { margin-left: 0; margin-right: 0; }
	figcaption { font: 0.8em/1.45 -apple-system, system-ui, sans-serif; color: var(--reader-secondary); margin-top: 0.5em; }
	blockquote { border-inline-start: 3px solid var(--reader-secondary); padding-inline-start: 1em; margin-inline: 0; color: var(--reader-secondary); }
	pre, code, kbd, samp { font: 0.85em/1.5 ui-monospace, "SF Mono", Menlo, monospace; }
	pre { overflow-x: auto; padding: 0.9em 1em; border-radius: 8px; background: color-mix(in srgb, var(--reader-text) 7%, transparent); }
	table { border-collapse: collapse; display: block; overflow-x: auto; font-size: 0.85em; }
	th, td { border: 1px solid color-mix(in srgb, var(--reader-text) 18%, transparent); padding: 0.35em 0.6em; text-align: start; vertical-align: top; }
	hr { border: 0; border-top: 1px solid color-mix(in srgb, var(--reader-text) 18%, transparent); margin: 2em 0; }
	sup, sub { line-height: 0; }
	::selection { background: color-mix(in srgb, var(--reader-link) 30%, transparent); }
	mark.arx-reader-match { background: rgba(255, 214, 10, 0.4); color: inherit; border-radius: 2px; }
	mark.arx-reader-match.arx-reader-match-current { background: #ff9f0a; color: #1d1d1f; }
	"""
}
