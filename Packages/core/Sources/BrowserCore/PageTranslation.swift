import Foundation

/// A profile's page translation choices (DEV-904): sites never translated and languages always
/// translated, remembered per profile. Private windows remember nothing.
public struct ProfileTranslationPreferences: Codable, Equatable, Sendable {
	/// Hosts whose pages Translate Page never offers or translates on its own.
	public var neverSites: [String]

	/// Base language codes (`fr`, `zh-Hant`) whose pages are translated as soon as they load.
	public var alwaysLanguages: [String]

	public init(
		neverSites: [String] = [],
		alwaysLanguages: [String] = []
	) {
		self.neverSites = neverSites
		self.alwaysLanguages = alwaysLanguages
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.neverSites = (try? values.decodeIfPresent([String].self, forKey: .neverSites)) ?? []
		self.alwaysLanguages = (try? values.decodeIfPresent([String].self, forKey: .alwaysLanguages)) ?? []
	}

	public var isEmpty: Bool { neverSites.isEmpty && alwaysLanguages.isEmpty }

	/// These choices with `other`'s added: a private window's own, on top of its opener's
	/// (DEV-996).
	public func adding(_ other: Self) -> Self {
		var merged = self
		merged.neverSites += other.neverSites.filter { !merged.neverSites.contains($0) }
		merged.alwaysLanguages += other.alwaysLanguages.filter { !merged.alwaysLanguages.contains($0) }
		return merged
	}

	/// Whether `url`'s host or a parent domain of it is never translated.
	public func neverTranslates(_ url: URL) -> Bool {
		guard let host = Self.host(of: url) else { return false }
		return neverSites.contains { host == $0 || host.hasSuffix("." + $0) }
	}

	public func alwaysTranslates(_ language: String) -> Bool {
		alwaysLanguages.contains(language)
	}

	public mutating func setNeverTranslates(
		_ isOn: Bool,
		for url: URL
	) {
		guard let host = Self.host(of: url) else { return }
		neverSites.removeAll { host == $0 || host.hasSuffix("." + $0) }
		if isOn { neverSites.append(host) }
	}

	public mutating func setAlwaysTranslates(
		_ isOn: Bool,
		language: String
	) {
		alwaysLanguages.removeAll { $0 == language }
		if isOn { alwaysLanguages.append(language) }
	}

	private static func host(of url: URL) -> String? {
		guard
			url.hasWebScheme,
			let host = url.host()?.lowercased(),
			!host.isEmpty
		else { return nil }
		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}
}

/// Every profile's translation choices, kept in the workspace file (DEV-904), and how pages
/// are translated: by whom, how, and into what (DEV-996).
public struct TranslationPreferences: Codable, Equatable, Sendable {
	public var profiles: [Profile.ID: ProfileTranslationPreferences]

	/// Who translates. Apple's on-device translation unless the person picks Google, which
	/// sends the page's text to Google (DEV-996).
	public var provider: TranslationProvider

	/// Apple's translation: Auto follows what macOS prefers (DEV-996).
	public var quality: TranslationQuality

	/// The language pages are translated into, as a base code (`en`, `zh-Hant`); nil is the
	/// person's first preferred language (DEV-996).
	public var targetLanguage: String?

	public init(
		profiles: [Profile.ID: ProfileTranslationPreferences] = [:],
		provider: TranslationProvider = .apple,
		quality: TranslationQuality = .automatic,
		targetLanguage: String? = nil
	) {
		self.profiles = profiles
		self.provider = provider
		self.quality = quality
		self.targetLanguage = targetLanguage
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.profiles = (try? values.decodeIfPresent([Profile.ID: ProfileTranslationPreferences].self, forKey: .profiles)) ?? [:]
		self.provider = (try? values.decodeIfPresent(TranslationProvider.self, forKey: .provider)) ?? .apple
		self.quality = (try? values.decodeIfPresent(TranslationQuality.self, forKey: .quality)) ?? .automatic
		self.targetLanguage = try? values.decodeIfPresent(String.self, forKey: .targetLanguage)
	}

	public subscript(profile: Profile.ID) -> ProfileTranslationPreferences {
		get { profiles[profile] ?? .init() }
		set { profiles[profile] = newValue.isEmpty ? nil : newValue }
	}
}

/// Who translates pages (DEV-996).
public enum TranslationProvider: String, Codable, CaseIterable, Sendable {
	/// Apple's Translation, on this Mac: the page's text stays here.
	case apple

	/// Google Translate: the page's text is sent to Google.
	case google

	public init(from decoder: any Decoder) throws {
		self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .apple
	}
}

extension TranslationProvider {
	/// The languages pages can be translated into, as base codes: Apple's as macOS 27 lists
	/// them (the app asks the Mac for its own list where it can), and Google's widely used ones.
	public var targetLanguages: [String] {
		switch self {
		case .apple:
			[
				"ar", "da", "de", "en", "es", "fi", "fr", "he", "hi", "id", "it", "ja", "ko", "ms", "nb",
				"nl", "pl", "pt", "ru", "sv", "th", "tr", "uk", "vi", "zh-Hans", "zh-Hant",
			]
		case .google:
			[
				"af", "am", "ar", "az", "be", "bg", "bn", "bs", "ca", "cs", "cy", "da", "de", "el", "en",
				"eo", "es", "et", "eu", "fa", "fi", "fil", "fr", "ga", "gl", "gu", "ha", "he", "hi", "hr",
				"hu", "hy", "id", "ig", "is", "it", "ja", "ka", "kk", "km", "kn", "ko", "ky", "lo", "lt",
				"lv", "mk", "ml", "mn", "mr", "ms", "mt", "my", "nb", "ne", "nl", "pa", "pl", "ps", "pt",
				"ro", "ru", "si", "sk", "sl", "sq", "sr", "sv", "sw", "ta", "te", "th", "tr", "uk", "ur",
				"uz", "vi", "yo", "zh-Hans", "zh-Hant", "zu",
			]
		}
	}
}

/// Apple's translation models (DEV-996).
public enum TranslationQuality: String, Codable, CaseIterable, Sendable {
	/// What macOS prefers on this Mac.
	case automatic

	/// Apple Intelligence's models where the Mac has them: better, slower.
	case quality

	/// The smaller models: faster.
	case faster

	public init(from decoder: any Decoder) throws {
		self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .automatic
	}
}

/// The `ARX_TRANSLATE` feature flag (DEV-996): Translation Available in the address bar, its
/// popover and Settings, the language read after every load, private windows, sentences
/// translated whole and Google as a choice. Off, page translation is DEV-904's. On by default
/// (DEV-1143).
public enum PageTranslationFeatureFlag {
	public static let name: String = FeatureFlag.translate.name

	/// Read through the `FeatureFlag` registry: the environment first, then user defaults.
	public static func isEnabled(
		environment: [String: String] = ProcessInfo.processInfo.environment,
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.translate.isOn(environment: environment, defaults: defaults)
	}
}
