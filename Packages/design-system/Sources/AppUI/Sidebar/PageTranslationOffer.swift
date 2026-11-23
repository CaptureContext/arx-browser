import BrowserCore
import Foundation
import SwiftUI

/// What the URL bar's second line says about translating the page, and what its popover offers
/// (DEV-996, behind `ARX_TRANSLATE`).
public struct PageTranslationOffer: Equatable, Sendable {
	public enum Phase: Equatable, Sendable {
		/// The page is in another language than the person's, and can be translated.
		case available

		/// It can be, once Apple's languages for the pair are downloaded.
		case needsDownload
		case translating
		case translated
	}

	/// The page's language and the one it's (to be) translated into, as base codes.
	public var source: String
	public var target: String
	public var phase: Phase
	public var provider: TranslationProvider
	public var quality: TranslationQuality
	public var neverTranslatesSite: Bool

	/// Choose Another Language's list, as base codes.
	public var targets: [String]

	public init(
		source: String,
		target: String,
		phase: Phase,
		provider: TranslationProvider = .apple,
		quality: TranslationQuality = .automatic,
		neverTranslatesSite: Bool = false,
		targets: [String] = []
	) {
		self.source = source
		self.target = target
		self.phase = phase
		self.provider = provider
		self.quality = quality
		self.neverTranslatesSite = neverTranslatesSite
		self.targets = targets
	}

	/// A language's name in the person's own language, such as "French".
	public static func name(_ code: String) -> String {
		Locale.current.localizedString(forIdentifier: code) ?? code
	}

	/// The second line under the address.
	public var line: String {
		switch phase {
		case .available, .needsDownload: String.localized(.appUI.translation.available)
		case .translating: String.localized(.appUI.translation.translatingLine)
		case .translated: String.localized(.appUI.translation.translatedFrom(Self.name(source)))
		}
	}
}

/// What the person does in the popover.
public enum PageTranslationOfferAction: Equatable, Sendable {
	/// Translate into `target`, or into the offer's target when nil.
	case translate(target: String?)
	case showOriginal
	case setNeverTranslateSite(Bool)
	case openLanguageSettings

	/// Apple's languages for the pair were downloaded from the popover.
	case downloaded
}

/// The offer for the page the URL bar shows, and where the popover's actions go.
public struct PageTranslationOfferSource: Sendable {
	public var offer: PageTranslationOffer?
	public var send: @MainActor @Sendable (PageTranslationOfferAction) -> Void

	public init(
		offer: PageTranslationOffer?,
		send: @escaping @MainActor @Sendable (PageTranslationOfferAction) -> Void
	) {
		self.offer = offer
		self.send = send
	}
}

extension EnvironmentValues {
	@Entry
	public var pageTranslationOffer: PageTranslationOfferSource? = nil
}
