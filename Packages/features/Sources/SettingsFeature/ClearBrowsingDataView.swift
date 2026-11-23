import AppUI
import BrowserCore
import Foundation
import SwiftUI
import _ComposableArchitecture

/// One profile's Clear Browsing Data (DEV-647), opened from its Profiles page: a
/// time range, what to remove, and how much of each there is in that range.
public struct ClearBrowsingDataView: View {
	@Bindable
	public var store: StoreOf<ClearBrowsingDataFeature>

	public init(store: StoreOf<ClearBrowsingDataFeature>) {
		self.store = store
	}

	public var body: some View {
		// The Close bar the other Settings sheets use (DEV-772): × (Escape) cancels, and Clear
		// Data stays pinned under the list.
		ArxModalScaffold(contentPadding: SettingsSheetMetrics.contentPadding) {
			SettingsNavigationBar(
				.close { store.send(.ui(.cancel)) },
				title: String.localized(.appUI.clearData.title),
				trail: [SettingsCategory.profiles.title, store.profileName]
			)
		} content: {
			VStack(alignment: .leading, spacing: 14) {
				Text(localized: .appUI.clearData.subtitle(store.profileName))
					.foregroundStyle(.secondary)
				SettingsCard {
					// The label leads and the pop-up trails, as in every Settings row.
					HStack {
						Text(localized: .appUI.clearData.rangeLabel)
						Spacer(minLength: 16)
						Picker(
							String.localized(.appUI.clearData.rangeLabel),
							selection: Binding(
								get: { store.range },
								set: { store.send(.ui(.rangeChanged($0))) }
							)
						) {
							ForEach(BrowsingDataRange.allCases, id: \.self) { range in
								Text(verbatim: Self.name(range)).tag(range)
							}
						}
						.labelsHidden()
						.fixedSize()
					}
					.padding(.vertical, 4)
				}
				SettingsCard {
					ForEach(BrowsingDataKind.allCases, id: \.self) { kind in
						if kind != BrowsingDataKind.allCases.first { Divider() }
						row(kind)
					}
				}
				Text(localized: .appUI.clearData.passwordsNote)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
			}
		} footer: {
			footer
		}
		.font(SettingsTypography.body)
		.frame(width: SettingsSheetMetrics.width, height: ClearBrowsingDataMetrics.height)
		.arxModalSheet()
		.disabled(store.isClearing)
		.interactiveDismissDisabled(store.isClearing)
		.task { store.send(.ui(.appeared)) }
	}

	private func row(_ kind: BrowsingDataKind) -> some View {
		Toggle(
			isOn: Binding(
				get: { store.kinds.contains(kind) },
				set: { store.send(.ui(.kindToggled(kind, $0))) }
			)
		) {
			VStack(alignment: .leading, spacing: 2) {
				Text(verbatim: Self.name(kind))
				Text(verbatim: Self.detail(kind))
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
				Text(verbatim: count(kind))
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.monospacedDigit()
			}
		}
		.toggleStyle(.checkbox)
		.padding(.vertical, 6)
	}

	private var footer: some View {
		HStack(alignment: .firstTextBaseline) {
			if let notice = store.notice {
				Text(verbatim: Self.message(notice))
					.foregroundStyle(.red)
					.font(SettingsTypography.caption)
					.fixedSize(horizontal: false, vertical: true)
			}
			Spacer()
			if store.isClearing {
				ProgressView().controlSize(.small)
			}
			ArxModalButton(
				String.localized(store.isClearing ? .appUI.clearData.clearing : .appUI.clearData.clear),
				role: .destructive
			) {
				store.send(.ui(.clear))
			}
			.disabled(!store.canClear)
		}
	}

	private func count(_ kind: BrowsingDataKind) -> String {
		let counts = store.counts
		let number: (Int) -> String = { $0.formatted() }
		let value: String? = switch kind {
		case .history: counts.history.map { String.localized(.appUI.clearData.count.pages(number($0))) }
		case .downloads: counts.downloads.map { String.localized(.appUI.clearData.count.downloads(number($0))) }
		case .cookies: counts.cookieSites.map { String.localized(.appUI.clearData.count.sites(number($0))) }
		case .cache: counts.cacheBytes.map { bytes in
			let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
			return counts.cacheIsUpperBound
			? String.localized(.appUI.clearData.count.cacheUpTo(size))
			: String.localized(.appUI.clearData.count.cache(size))
		}
		case .autofill: counts.autofill.map {
			String.localized(.appUI.clearData.count.autofill(number($0.entries), number($0.addresses), number($0.cards)))
		}
		case .siteSettings: counts.siteSettingsSites.map { String.localized(.appUI.clearData.count.sites(number($0))) }
		}
		if let value { return value }
		return store.isCounting
		? String.localized(.appUI.clearData.counting)
		: String.localized(.appUI.clearData.uncounted)
	}

	internal static func name(_ range: BrowsingDataRange) -> String {
		switch range {
		case .lastHour: String.localized(.appUI.clearData.range.lastHour)
		case .lastDay: String.localized(.appUI.clearData.range.lastDay)
		case .lastWeek: String.localized(.appUI.clearData.range.lastWeek)
		case .lastFourWeeks: String.localized(.appUI.clearData.range.lastFourWeeks)
		case .allTime: String.localized(.appUI.clearData.range.allTime)
		}
	}

	internal static func name(_ kind: BrowsingDataKind) -> String {
		switch kind {
		case .history: String.localized(.appUI.clearData.kind.history)
		case .downloads: String.localized(.appUI.clearData.kind.downloads)
		case .cookies: String.localized(.appUI.clearData.kind.cookies)
		case .cache: String.localized(.appUI.clearData.kind.cache)
		case .autofill: String.localized(.appUI.clearData.kind.autofill)
		case .siteSettings: String.localized(.appUI.clearData.kind.siteSettings)
		}
	}

	private static func detail(_ kind: BrowsingDataKind) -> String {
		switch kind {
		case .history: String.localized(.appUI.clearData.kind.historyDetail)
		case .downloads: String.localized(.appUI.clearData.kind.downloadsDetail)
		case .cookies: String.localized(.appUI.clearData.kind.cookiesDetail)
		case .cache: String.localized(.appUI.clearData.kind.cacheDetail)
		case .autofill: String.localized(.appUI.clearData.kind.autofillDetail)
		case .siteSettings: String.localized(.appUI.clearData.kind.siteSettingsDetail)
		}
	}

	internal static func message(_ notice: ClearBrowsingDataFeature.Notice) -> String {
		switch notice {
		case let .partial(kinds):
			let names = BrowsingDataKind.allCases.filter(kinds.contains).map(name)
			return String.localized(.appUI.clearData.partial(names.formatted(.list(type: .and))))
		case .failed(.unavailable): return String.localized(.appUI.clearData.unavailable)
		case .failed(.managed): return String.localized(.appUI.clearData.managed)
		case .failed(.busy): return String.localized(.appUI.clearData.busy)
		case .failed(.invalid), .failed(.failed): return String.localized(.appUI.clearData.failed)
		}
	}
}

private enum ClearBrowsingDataMetrics {
	/// Tall enough for the range, every kind and the note without scrolling.
	internal static let height: CGFloat = 640
}
