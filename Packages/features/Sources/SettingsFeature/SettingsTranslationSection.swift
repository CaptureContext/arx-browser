import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The Translation section, in General.
internal struct SettingsTranslationSection: View {
	private let store: StoreOf<SettingsFeature>

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		let preferences = store.translation
		SettingsSection(
			String.localized(.appUI.settings.section.translation),
			footer: preferences.provider == .google
			? String.localized(.appUI.settings.translationProviderGoogleExplanation)
			: String.localized(.appUI.settings.translationProviderAppleExplanation)
		) {
			SettingsRow(String.localized(.appUI.settings.translationProvider)) {
				Picker(
					String.localized(.appUI.settings.translationProvider),
					selection: Binding(
						get: { preferences.provider },
						set: { store.send(.ui(.translationProvider($0))) }
					)
				) {
					ForEach(TranslationProvider.allCases, id: \.self) { provider in
						Text(provider.title).tag(provider)
					}
				}
				.labelsHidden()
				.fixedSize()
			}
			if preferences.provider == .apple {
				SettingsRow(
					String.localized(.appUI.settings.translationQuality),
					detail: String.localized(.appUI.settings.translationQualityExplanation)
				) {
					Picker(
						String.localized(.appUI.settings.translationQuality),
						selection: Binding(
							get: { preferences.quality },
							set: { store.send(.ui(.translationQuality($0))) }
						)
					) {
						ForEach(TranslationQuality.allCases, id: \.self) { quality in
							Text(quality.title).tag(quality)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
			}
			SettingsRow(String.localized(.appUI.settings.translationTarget)) {
				Picker(
					String.localized(.appUI.settings.translationTarget),
					selection: Binding(
						get: { preferences.targetLanguage },
						set: { store.send(.ui(.translationTarget($0))) }
					)
				) {
					Text(String.localized(.appUI.settings.translationTargetPreferred(Self.preferredName)))
						.tag(String?.none)
					Divider()
					ForEach(Self.sorted(preferences.provider.targetLanguages, keeping: preferences.targetLanguage), id: \.self) { code in
						Text(PageTranslationOffer.name(code)).tag(String?.some(code))
					}
				}
				.labelsHidden()
				.fixedSize()
			}
		}
		.settingsAnchor(.translation)
	}

	/// The person's first preferred language, as Auto uses it.
	private static var preferredName: String {
		let code = Locale.preferredLanguages.first ?? "en"
		return Locale.current.localizedString(forLanguageCode: Locale.Language(identifier: code).languageCode?.identifier ?? code)
			?? code
	}

	/// The provider's languages by name, with the chosen one kept even if it isn't listed.
	private static func sorted(
		_ codes: [String],
		keeping chosen: String?
	) -> [String] {
		var all = codes
		if let chosen, !all.contains(chosen) { all.append(chosen) }
		return all.sorted {
			PageTranslationOffer.name($0).localizedStandardCompare(PageTranslationOffer.name($1)) == .orderedAscending
		}
	}
}

extension TranslationProvider {
	fileprivate var title: String {
		switch self {
		case .apple: String.localized(.appUI.settings.translationProviderApple)
		case .google: String.localized(.appUI.settings.translationProviderGoogle)
		}
	}
}

extension TranslationQuality {
	fileprivate var title: String {
		switch self {
		case .automatic: String.localized(.appUI.settings.translationQualityAutomatic)
		case .quality: String.localized(.appUI.settings.translationQualityBest)
		case .faster: String.localized(.appUI.settings.translationQualityFaster)
		}
	}
}
