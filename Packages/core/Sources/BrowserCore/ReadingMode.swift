import Foundation

/// Reading mode (DEV-1028): a page's article, laid over the page in a reader rather than loaded
/// in its place, so closing it leaves the page exactly as it was, scrolled where it was and never
/// reloaded. Behind the `ARX_READING_MODE` feature flag, on by default (DEV-1143).
public enum ReadingMode {
	public static let featureFlag: String = FeatureFlag.readingMode.name

	/// Read once, at launch: turning the flag on or off takes a relaunch.
	public static let isOn: Bool = isEnabled()

	/// The environment first, then user defaults, through the `FeatureFlag` registry.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.readingMode.isOn(environment: environment, defaults: defaults)
	}
}

/// A page's article as reading mode shows it: its words and pictures without the page around
/// them. Every string is the page's own, untrusted; `html` keeps only plain text markup, with
/// every address absolute.
public struct ReaderArticle: Equatable, Sendable {
	/// The page the article was read from.
	public var url: URL
	public var title: String
	public var byline: String?
	public var siteName: String?
	public var excerpt: String?

	/// The article's language, such as `en` or `uk`, when the page says.
	public var language: String?
	public var isRightToLeft: Bool
	public var html: String

	public init(
		url: URL,
		title: String,
		byline: String? = nil,
		siteName: String? = nil,
		excerpt: String? = nil,
		language: String? = nil,
		isRightToLeft: Bool = false,
		html: String
	) {
		self.url = url
		self.title = title
		self.byline = byline
		self.siteName = siteName
		self.excerpt = excerpt
		self.language = language
		self.isRightToLeft = isRightToLeft
		self.html = html
	}
}
