import BrowserCore
import SwiftUI
@preconcurrency import Translation

/// The popover under "Translation Available" (DEV-996): "Translate this page to
/// English?" with Options and Translate; Show Original once it's translated. Options holds
/// Choose Another Language, Never Translate This Site and Language Settings.
public struct PageTranslationPopover: View {
	private let offer: PageTranslationOffer
	private let send: @MainActor @Sendable (PageTranslationOfferAction) -> Void
	private let dismiss: () -> Void

	/// Set to ask macOS for the pair's languages; its task shows the system's download sheet.
	@SwiftUI.State
	private var download: TranslationSession.Configuration?

	@SwiftUI.State
	private var downloadFailed: Bool

	public static let width: CGFloat = 300

	public init(
		offer: PageTranslationOffer,
		send: @escaping @MainActor @Sendable (PageTranslationOfferAction) -> Void,
		dismiss: @escaping () -> Void
	) {
		self.offer = offer
		self.send = send
		self.dismiss = dismiss
		self._download = .init(initialValue: nil)
		self._downloadFailed = .init(initialValue: false)
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Label(title, systemImage: "translate")
				.font(.headline)
				.fixedSize(horizontal: false, vertical: true)
			if let detail {
				Text(detail)
					.font(.system(size: 12))
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: 8) {
				options
				Spacer(minLength: 0)
				primary
			}
		}
		.padding(16)
		.frame(width: Self.width, alignment: .leading)
		.popoverOpensWithoutFocus()
		.translationTask(download) { session in
			do {
				try await session.prepareTranslation()
				await MainActor.run {
					download = nil
					send(.downloaded)
				}
			} catch {
				await MainActor.run {
					download = nil
					downloadFailed = true
				}
			}
		}
	}

	private var sourceName: String { PageTranslationOffer.name(offer.source) }
	private var targetName: String { PageTranslationOffer.name(offer.target) }

	private var title: String {
		switch offer.phase {
		case .available: String.localized(.appUI.translation.offerTitle(targetName))
		case .needsDownload: String.localized(.appUI.translation.downloadTitle(sourceName, targetName))
		case .translating: String.localized(.appUI.translation.translatingTitle(targetName))
		case .translated: String.localized(.appUI.translation.translatedTitle(sourceName, targetName))
		}
	}

	private var detail: String? {
		if downloadFailed { return String.localized(.appUI.translation.downloadFailed) }
		switch offer.phase {
		case .available, .translating, .translated:
			return offer.provider == .google
			? String.localized(.appUI.translation.byGoogle)
			: String.localized(.appUI.translation.onDevice(sourceName))
		case .needsDownload:
			return String.localized(.appUI.translation.downloadDetail)
		}
	}

	@ViewBuilder
	private var primary: some View {
		switch offer.phase {
		case .available:
			Button(String.localized(.appUI.translation.translate)) {
				send(.translate(target: nil))
				dismiss()
			}
			.keyboardShortcut(.defaultAction)
		case .needsDownload:
			Button(String.localized(.appUI.translation.download)) {
				downloadFailed = false
				download = configuration
			}
			.keyboardShortcut(.defaultAction)
			.disabled(download != nil)
		case .translating, .translated:
			Button(String.localized(.appUI.translation.showOriginal)) {
				send(.showOriginal)
				dismiss()
			}
		}
	}

	private var options: some View {
		Menu(String.localized(.appUI.translation.options)) {
			if !offer.targets.isEmpty {
				Menu(String.localized(.appUI.translation.chooseLanguage)) {
					ForEach(sortedTargets, id: \.self) { code in
						Button(PageTranslationOffer.name(code)) {
							send(.translate(target: code))
							dismiss()
						}
						.disabled(code == offer.source)
					}
				}
			}
			Toggle(
				String.localized(.appUI.translation.neverSiteMenu),
				isOn: Binding(get: { offer.neverTranslatesSite }, set: { send(.setNeverTranslateSite($0)) })
			)
			Divider()
			Button(String.localized(.appUI.translation.languageSettings)) {
				send(.openLanguageSettings)
				dismiss()
			}
		}
		.fixedSize()
	}

	private var sortedTargets: [String] {
		offer.targets.sorted {
			PageTranslationOffer.name($0).localizedStandardCompare(PageTranslationOffer.name($1)) == .orderedAscending
		}
	}

	/// The pair and quality the page is translated with, for the download.
	private var configuration: TranslationSession.Configuration {
		let source = Locale.Language(identifier: offer.source)
		let target = Locale.Language(identifier: offer.target)
		return switch offer.quality {
		case .automatic: .init(source: source, target: target)
		case .quality: .init(source: source, target: target, preferredStrategy: .highFidelity)
		case .faster: .init(source: source, target: target, preferredStrategy: .lowLatency)
		}
	}
}
