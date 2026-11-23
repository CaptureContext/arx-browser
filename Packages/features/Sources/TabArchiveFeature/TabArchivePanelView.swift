import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// The Tab Archive as the Library shows it, beside the rail.
public struct TabArchivePanelView: View {
	@Bindable
	public var store: StoreOf<TabArchiveFeature>

	public init(store: StoreOf<TabArchiveFeature>) {
		self.store = store
	}

	public var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(groups, id: \.title) { group in
						SidebarLibraryGroupHeader(title: group.title)
						ForEach(group.items) { entry in
							row(entry)
						}
					}
				}
				.padding(.bottom, 12)
			}
			.scrollIndicators(.hidden)
			.scrollBounceBehavior(.basedOnSize, axes: .vertical)

			// Entries scroll under the search into Arx's progressive edge, with no line (DEV-807, DEV-826).
			.arxScrollBar(background: nil) { header }
			.overlay {
				if store.visibleEntries.isEmpty {
					VStack(spacing: 6) {
						Text(
							store.query.isEmpty
							? String.localized(.appUI.archive.empty)
							: String.localized(.appUI.archive.noMatches)
						)
						.font(.system(size: BrowserMetrics.Row.fontSize))

						// What comes here, and after how long (DEV-1326).
						if store.query.isEmpty {
							Text(store.emptyExplanation)
								.font(.caption)
								.multilineTextAlignment(.center)
						}
					}
					.foregroundStyle(BrowserTheme.secondary)
					.padding(.horizontal, 16)
				}
			}

			if let message = store.message {
				Text(message)
					.font(.caption)
					.foregroundStyle(.red)
					.padding(BrowserMetrics.Sidebar.horizontalPadding)
			}
		}
		.disabled(store.isWorking)
		.modifier(TabArchiveConfirmations(store: store))
	}

	private var header: some View {
		SidebarLibraryHeader(
			placeholder: String.localized(.appUI.archive.panelSearchPlaceholder),
			query: $store.query.sending(\.ui.queryChanged)
		) {
			SidebarLibraryMenu(
				title: String.localized(.appUI.library.filter),
				symbol: "line.3.horizontal.decrease.circle"
			) {
				Picker(
					String.localized(.appUI.library.filter),
					selection: $store.spaceFilter.sending(\.ui.spaceFilterChanged)
				) {
					Text(String.localized(.appUI.archive.allSpaces))
						.tag(Space.ID?.none)
					ForEach(store.spaces) { space in
						Text(space.name)
							.tag(Space.ID?.some(space.id))
					}
				}
				.pickerStyle(.inline)
				Divider()
				Button(String.localized(.appUI.archive.clear), role: .destructive) {
					store.send(.ui(.clearRequested))
				}
				.disabled(store.entries.isEmpty)
			}
		}
	}

	private var groups: [SidebarLibraryGroup<ArchivedTab>] {
		SidebarLibraryGroup.grouping(store.visibleEntries, date: \.closedAt)
	}

	private func row(_ entry: ArchivedTab) -> some View {
		SidebarLibraryRow(
			title: entry.tab.displayTitle,
			subtitle: address(entry),
			action: { restore(entry) },
			icon: {
				SidebarLibrarySiteIcon(
					key: .init(
						profileID: entry.tab.profileID.rawValue,
						pageURL: entry.tab.restoration.url
					)
				)
			}
		)
		.contextMenu {
			Button(String.localized(.appUI.archive.restore)) { restore(entry) }
			Button(String.localized(.appUI.archive.restoreGroup)) {
				store.send(.ui(.restoreGroup(entry.groupID, nil)))
			}
			Button(String.localized(.appUI.archive.deleteSelected), role: .destructive) {
				store.send(.ui(.selectionChanged([entry.id])))
				store.send(.ui(.deleteSelected))
			}
		}
	}

	private func address(_ entry: ArchivedTab) -> String {
		let url = entry.tab.restoration.url
		guard let host = url.host() else { return url.absoluteString }
		let path = url.path()
		return path == "/" ? host : host + path
	}

	private func restore(_ entry: ArchivedTab) {
		store.send(.ui(.selectionChanged([entry.id])))
		store.send(.ui(.restoreSelected(nil)))
	}
}
