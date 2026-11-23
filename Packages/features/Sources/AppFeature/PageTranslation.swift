import BrowserCore
import BrowserEngineClient
import Foundation
import PageTranslationClient

/// A tab's page translation (DEV-904): its languages and how far it got.
public struct TabTranslation: Equatable, Sendable {
	public enum Phase: Equatable, Sendable {
		case detecting
		case translating

		/// Everything read so far is translated; new text is translated as it comes into view.
		case translated
	}

	/// Nil while the page's language is being detected.
	public var source: String?
	public var target: String
	public var phase: Phase

	/// Started by Always translate rather than by the person: it stops quietly.
	public var isAutomatic: Bool

	/// Who translates it and how, as the translation runs now (DEV-996).
	public var options: PageTranslationClient.Options

	public init(
		source: String? = nil,
		target: String,
		phase: Phase = .detecting,
		isAutomatic: Bool = false,
		options: PageTranslationClient.Options = .init()
	) {
		self.source = source
		self.target = target
		self.phase = phase
		self.isAutomatic = isAutomatic
		self.options = options
	}
}

/// A Chromium page's language, read after it loads (DEV-996), and whether it can be translated
/// into `target` with `options`, as they were then.
public struct PageLanguage: Equatable, Sendable {
	public var url: URL

	/// A base code; nil while it's read, or when it couldn't be told.
	public var source: String?
	public var target: String
	public var options: PageTranslationClient.Options
	public var availability: PageTranslationClient.Availability

	public init(
		url: URL,
		source: String? = nil,
		target: String,
		options: PageTranslationClient.Options,
		availability: PageTranslationClient.Availability = .unsupported
	) {
		self.url = url
		self.source = source
		self.target = target
		self.options = options
		self.availability = availability
	}
}

/// The target and options pages are translated with, as last seen: a change reads every
/// loaded page's availability again (DEV-996).
public struct TranslationSettingsSnapshot: Equatable, Sendable {
	public var target: String
	public var options: PageTranslationClient.Options

	public init(
		target: String,
		options: PageTranslationClient.Options
	) {
		self.target = target
		self.options = options
	}
}

/// The languages a provider translates into, for Choose Another Language (DEV-996).
public struct TranslationLanguages: Equatable, Sendable {
	public var provider: TranslationProvider
	public var codes: [String]

	public init(
		provider: TranslationProvider,
		codes: [String]
	) {
		self.provider = provider
		self.codes = codes
	}
}

/// Why a page wasn't translated.
public enum PageTranslationProblem: Equatable, Sendable {
	case unavailable
	case unknownLanguage
	case sameLanguage
	case unsupported(String)
	case needsDownload(String)
	case failed
}
