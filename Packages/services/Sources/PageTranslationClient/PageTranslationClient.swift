import BrowserCore
import Foundation
import NaturalLanguage
import Translation
import _Dependencies

/// Translating a page's text on this Mac with Apple's Translation framework (DEV-904). Nothing
/// leaves the Mac: the language models are the ones macOS keeps in System Settings › General ›
/// Language & Region › Translation Languages.
public struct PageTranslationClient: Sendable {
	/// Whether this Mac can translate between two languages now.
	public enum Availability: Equatable, Sendable {
		/// Both languages are installed.
		case ready

		/// The pair is supported, but its languages need downloading first.
		case needsDownload
		case unsupported
	}

	public enum Failure: Error, Equatable, Sendable {
		case unsupported
		case needsDownload
		case failed
	}

	/// The language a text is most likely in, as a BCP 47 code such as `fr`, or nil when it
	/// can't tell.
	public var detectLanguage: @Sendable (String) -> String?
	public var availability: @Sendable (_ source: String, _ target: String) async -> Availability

	/// The texts translated, in order.
	public var translate: @Sendable (
		_ texts: [String],
		_ source: String,
		_ target: String
	) async throws(Failure) -> [String]

	/// The language pages are translated into: the person's first preferred language.
	public var targetLanguage: @Sendable () -> String

	/// Who translates and how (DEV-996).
	public struct Options: Equatable, Sendable {
		public var provider: TranslationProvider
		public var quality: TranslationQuality

		public init(
			provider: TranslationProvider = .apple,
			quality: TranslationQuality = .automatic
		) {
			self.provider = provider
			self.quality = quality
		}
	}

	/// Whether a pair can be translated now, by the provider and with the quality given
	/// (DEV-996). Google translates any pair it lists, online.
	public var pairAvailability: @Sendable (
		_ source: String,
		_ target: String,
		_ options: Options
	) async -> Availability

	/// Each segment's runs translated and arranged, nil for a segment that couldn't be
	/// (DEV-996).
	public var translateSegments: @Sendable (
		_ segments: [[PageTranslationScripts.Run]],
		_ source: String,
		_ target: String,
		_ options: Options
	) async throws(Failure) -> [PageTranslationScripts.Arrangement?]

	/// The languages a provider translates into, as base codes (DEV-996).
	public var targetLanguages: @Sendable (TranslationProvider) async -> [String]

	public init(
		detectLanguage: @escaping @Sendable (String) -> String? = { _ in nil },
		availability: @escaping @Sendable (String, String) async -> Availability = { _, _ in .unsupported },
		translate: @escaping @Sendable ([String], String, String) async throws(Failure) -> [String] = {
			_, _, _ throws(Failure) in throw .unsupported
		},
		targetLanguage: @escaping @Sendable () -> String = { "en" },
		pairAvailability: @escaping @Sendable (String, String, Options) async -> Availability = { _, _, _ in .unsupported },
		translateSegments: @escaping @Sendable ([[PageTranslationScripts.Run]], String, String, Options) async throws(Failure) -> [PageTranslationScripts.Arrangement?] = {
			_, _, _, _ throws(Failure) in throw .unsupported
		},
		targetLanguages: @escaping @Sendable (TranslationProvider) async -> [String] = { _ in [] }
	) {
		self.detectLanguage = detectLanguage
		self.availability = availability
		self.translate = translate
		self.targetLanguage = targetLanguage
		self.pairAvailability = pairAvailability
		self.translateSegments = translateSegments
		self.targetLanguages = targetLanguages
	}

	/// The base language of a BCP 47 code: `fr-CA` and `fr` are both `fr`. Chinese keeps its
	/// script, since Simplified and Traditional are different languages to translate.
	public static func baseLanguage(_ code: String) -> String {
		let language = Locale.Language(identifier: code)
		guard let base = language.languageCode?.identifier else { return code.lowercased() }
		if base == "zh", let script = language.script?.identifier { return "zh-\(script)" }
		return base
	}
}

extension PageTranslationClient: DependencyKey {
	public static var liveValue: Self {
		.init(
			detectLanguage: { text in
				let recognizer = NLLanguageRecognizer()
				recognizer.processString(text)
				guard
					let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
					confidence >= 0.5,
					language != .undetermined
				else { return nil }

				return language.rawValue
			},
			availability: { source, target in
				let status = await LanguageAvailability().status(
					from: Locale.Language(identifier: source),
					to: Locale.Language(identifier: target)
				)
				switch status {
				case .installed: return .ready
				case .supported: return .needsDownload
				default: return .unsupported
				}
			},
			translate: { texts, source, target throws(Failure) in
				guard !texts.isEmpty else { return [] }
				let session = TranslationSession(
					installedSource: Locale.Language(identifier: source),
					target: Locale.Language(identifier: target)
				)
				let requests = texts.enumerated().map { index, text in
					TranslationSession.Request(sourceText: text, clientIdentifier: String(index))
				}
				do {
					let responses = try await session.translations(from: requests)
					var translated = texts
					for response in responses {
						guard
							let identifier = response.clientIdentifier,
							let index = Int(identifier),
							translated.indices.contains(index)
						else { continue }

						translated[index] = response.targetText
					}
					return translated
				} catch {
					throw .failed
				}
			},
			targetLanguage: {
				Self.baseLanguage(Locale.preferredLanguages.first ?? "en")
			},
			pairAvailability: { source, target, options in
				switch options.provider {
				case .google:
					let languages = Set(GoogleTranslation.languages)
					return languages.contains(target) && languages.contains(source) ? .ready : .unsupported
				case .apple:
					let status = await Self.availability(options.quality).status(
						from: Locale.Language(identifier: source),
						to: Locale.Language(identifier: target)
					)
					switch status {
					case .installed: return .ready
					case .supported: return .needsDownload
					default: return .unsupported
					}
				}
			},
			translateSegments: { segments, source, target, options throws(Failure) in
				guard !segments.isEmpty else { return [] }
				switch options.provider {
				case .apple: return try await Self.appleSegments(segments, source: source, target: target, quality: options.quality)
				case .google: return try await Self.googleSegments(segments, source: source, target: target)
				}
			},
			targetLanguages: { provider in
				switch provider {
				case .google: return GoogleTranslation.languages
				case .apple:
					var seen: Set<String> = []
					return await LanguageAvailability().supportedLanguages
						.map { Self.baseLanguage($0.maximalIdentifier) }
						.filter { seen.insert($0).inserted }
				}
			}
		)
	}

	/// Apple's availability for the chosen quality: Auto asks what macOS prefers.
	private static func availability(_ quality: TranslationQuality) -> LanguageAvailability {
		switch quality {
		case .automatic: LanguageAvailability()
		case .quality: LanguageAvailability(preferredStrategy: .highFidelity)
		case .faster: LanguageAvailability(preferredStrategy: .lowLatency)
		}
	}

	private static func appleSegments(
		_ segments: [[PageTranslationScripts.Run]],
		source: String,
		target: String,
		quality: TranslationQuality
	) async throws(Failure) -> [PageTranslationScripts.Arrangement?] {
		let from = Locale.Language(identifier: source)
		let to = Locale.Language(identifier: target)
		let session = switch quality {
		case .automatic: TranslationSession(installedSource: from, target: to)
		case .quality: TranslationSession(installedSource: from, target: to, preferredStrategy: .highFidelity)
		case .faster: TranslationSession(installedSource: from, target: to, preferredStrategy: .lowLatency)
		}

		// A segment of one run goes in a plain batch. One with several runs is translated on
		// its own: only `translate(_:)` with an attributed string answers with the attributed
		// translation the runs are found in; a batch drops it.
		let plain = segments.indices.filter { segments[$0].count == 1 && segments[$0][0].translate }
		var translated: [PageTranslationScripts.Arrangement?] = Array(repeating: nil, count: segments.count)
		do {
			if !plain.isEmpty {
				let requests = plain.map { TranslationSession.Request(sourceText: segments[$0][0].text, clientIdentifier: String($0)) }
				for response in try await session.translations(from: requests) {
					guard
						let identifier = response.clientIdentifier,
						let index = Int(identifier),
						translated.indices.contains(index)
					else { continue }

					translated[index] = PageTranslationScripts.arrange([.init(run: 0, text: response.targetText)], runs: segments[index])
				}
			}
			for index in segments.indices where !plain.contains(index) {
				try Task.checkCancellation()
				let response = try await session.translate(AppleTranslationRuns.attributed(segments[index]))
				translated[index] = response.attributedTargetText.flatMap { AppleTranslationRuns.texts(from: $0, runs: segments[index]) }

					// Without marks, the sentence goes whole into its first translated run.
					?? PageTranslationScripts.arrange([.init(run: nil, text: response.targetText)], runs: segments[index])
			}
			return translated
		} catch is CancellationError {
			throw .failed
		} catch {
			throw TranslationError.notInstalled ~= error ? .needsDownload : .failed
		}
	}

	private static func googleSegments(
		_ segments: [[PageTranslationScripts.Run]],
		source: String,
		target: String
	) async throws(Failure) -> [PageTranslationScripts.Arrangement?] {
		let html = segments.map(GoogleTranslation.html)
		var translated: [PageTranslationScripts.Arrangement?] = Array(repeating: nil, count: segments.count)
		for range in GoogleTranslation.requests(html) {
			let request = GoogleTranslation.request(Array(html[range]), source: source, target: target)
			do {
				let (data, response) = try await GoogleTranslation.session.data(for: request)
				guard
					(response as? HTTPURLResponse)?.statusCode == 200,
					let texts = GoogleTranslation.decode(data, count: range.count)
				else { throw Failure.failed }

				for (offset, text) in texts.enumerated() {
					let index = range.lowerBound + offset
					translated[index] = GoogleTranslation.texts(from: text, runs: segments[index])
				}
			} catch {
				throw .failed
			}
		}
		return translated
	}

	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var pageTranslation: PageTranslationClient {
		get { self[PageTranslationClient.self] }
		set { self[PageTranslationClient.self] = newValue }
	}
}
