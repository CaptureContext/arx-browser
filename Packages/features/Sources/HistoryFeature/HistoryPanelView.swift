import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The History page as the Library shows it, beside the rail (DEV-817).
public struct HistoryPanelView: View {
	/// The moment "Today" is measured from; nil reads the clock. Snapshots fix it.
	private let now: Date?

	@Bindable
	public var store: StoreOf<HistoryFeature>

	@Environment(\.calendar)
	private var calendar

	@Environment(\.locale)
	private var locale

	public init(
		store: StoreOf<HistoryFeature>,
		now: Date? = nil
	) {
		self.store = store
		self.now = now
	}

	public var body: some View {
		let days = store.state.days(in: calendar)
		ScrollView {
			LazyVStack(spacing: 0) {
				ForEach(days) { day in
					SidebarLibraryGroupHeader(title: title(of: day))
						.contentShape(Rectangle())
						.contextMenu { deleteDayButton(day.id) }
					ForEach(day.entries) { entry in
						row(entry, day: day.id)
					}
				}
			}
			.padding(.bottom, 12)
		}
		.scrollIndicators(.hidden)
		.scrollBounceBehavior(.basedOnSize, axes: .vertical)

		// Entries scroll under the search into Arx's progressive edge, with no line, as on the
		// Library's other pages (DEV-807, DEV-826).
		.arxScrollBar(background: nil) { header }
		.overlay {
			if days.isEmpty {
				Text(emptyText)
					.font(.system(size: BrowserMetrics.Row.fontSize))
					.foregroundStyle(BrowserTheme.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
			}
		}
		.modifier(HistoryDeletionConfirmation(store: store, title: confirmationTitle))
	}

	private var header: some View {
		SidebarLibraryHeader(
			placeholder: String.localized(.appUI.history.page.searchPlaceholder),
			query: $store.query.sending(\.ui.queryChanged)
		) {
			EmptyView()
		}
	}

	private var emptyText: String {
		if store.isUnavailable { return String.localized(.appUI.history.page.unavailable) }
		return store.query.isEmpty
		? String.localized(.appUI.history.page.empty)
		: String.localized(.appUI.history.page.noMatches)
	}

	private func row(
		_ entry: BrowsingHistoryEntry,
		day: Date
	) -> some View {
		SidebarLibraryRow(
			title: entry.title.isEmpty ? Self.address(entry.url) : entry.title,
			// The time first, so a long address truncates before it.
			subtitle: entry.lastVisited.formatted(
				Date.FormatStyle(
					date: .omitted,
					time: .shortened,
					locale: locale,
					calendar: calendar,
					timeZone: calendar.timeZone
				)
			) + " · " + Self.address(entry.url),
			action: { store.send(.ui(.open(entry.id))) },
			icon: {
				SidebarLibrarySiteIcon(
					key: store.profileID.map { .init(profileID: $0.rawValue, pageURL: entry.url) }
				)
			}
		)
		.contextMenu {
			Button(String.localized(.appUI.history.page.openInNewTab)) { store.send(.ui(.open(entry.id))) }
			Divider()
			Button(String.localized(.appUI.history.page.delete), role: .destructive) {
				store.send(.ui(.delete(entry.id)))
			}
			deleteDayButton(day)
			if let site = HistoryFeature.site(of: entry.url) {
				Button(String.localized(.appUI.history.page.deleteSite(site)), role: .destructive) {
					store.send(.ui(.deleteSite(entry.id)))
				}
			}
		}
	}

	private func deleteDayButton(_ day: Date) -> some View {
		Button(String.localized(.appUI.history.page.deleteDay), role: .destructive) {
			store.send(.ui(.deleteDay(day)))
		}
	}

	private func title(of day: HistoryFeature.Day) -> String {
		title(ofDay: day.id)
	}

	private func title(ofDay start: Date) -> String {
		HistoryFeature.title(
			ofDay: start,
			now: now ?? .now,
			calendar: calendar,
			locale: locale
		)
	}

	private var confirmationTitle: String {
		switch store.pendingDeletion {
		case let .day(start):
			return String.localized(.appUI.history.page.deleteDayConfirmation(title(ofDay: start)))

		case let .site(host):
			return String.localized(.appUI.history.page.deleteSiteConfirmation(BrowsingHistoryRemoval.siteKey(host)))

		case nil:
			return ""
		}
	}

	private static func address(_ url: URL) -> String {
		guard let host = url.host() else { return url.absoluteString }
		let path = url.path()
		return path == "/" || path.isEmpty ? host : host + path
	}
}

extension HistoryFeature {
	/// A day's heading: Today, Yesterday, or its date, with the year only when it isn't this one.
	public static func title(
		ofDay day: Date,
		now: Date,
		calendar: Calendar,
		locale: Locale
	) -> String {
		if calendar.isDate(day, inSameDayAs: now) { return String.localized(.appUI.history.page.today) }
		if
			let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
			calendar.isDate(day, inSameDayAs: yesterday)
		{ return String.localized(.appUI.history.page.yesterday) }

		var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
			.weekday(.wide)
			.day()
			.month(.wide)
		if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
			style = style.year()
		}
		return day.formatted(style)
	}
}

private struct HistoryDeletionConfirmation: ViewModifier {
	internal let title: String

	@Bindable
	internal var store: StoreOf<HistoryFeature>

	@Environment(\.calendar)
	private var calendar

	internal init(
		store: StoreOf<HistoryFeature>,
		title: String
	) {
		self.store = store
		self.title = title
	}

	internal func body(content: Content) -> some View {
		content
			.confirmationDialog(
				title,
				isPresented: Binding(
					get: { store.pendingDeletion != nil },
					set: { if !$0 { store.send(.ui(.deletionCancelled)) } }
				)
			) {
				Button(String.localized(.appUI.history.page.deleteConfirm), role: .destructive) {
					store.send(.ui(.deletionConfirmed))
				}
			} message: {
				if let deletion = store.pendingDeletion {
					let count = store.state.entries(of: deletion, in: calendar).count
					Text(
						count == 1
						? String.localized(.appUI.history.page.deleteOne)
						: String.localized(.appUI.history.page.deleteDescription(count))
					)
				}
			}
	}
}
