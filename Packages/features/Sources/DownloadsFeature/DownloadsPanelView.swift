import AppKit
import AppUI
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// Downloads as the Library shows them, beside the rail.
public struct DownloadsPanelView: View {
	@Bindable
	public var store: StoreOf<DownloadsFeature>

	private let profiles: IdentifiedArrayOf<Profile>

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion: Bool

	@SwiftUI.State
	private var width: CGFloat = .infinity

	/// `profiles` are the ones the filter offers, in the order the pane lists them.
	public init(
		store: StoreOf<DownloadsFeature>,
		profiles: IdentifiedArrayOf<Profile>
	) {
		self.store = store
		self.profiles = profiles
	}

	public var body: some View {
		VStack(spacing: 0) {
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(groups, id: \.title) { group in
						SidebarLibraryGroupHeader(title: group.title)
						ForEach(group.items) { download in
							row(download)
						}
					}
				}
				.padding(.bottom, 12)
			}
			.scrollIndicators(.hidden)
			.scrollBounceBehavior(.basedOnSize, axes: .vertical)

			// Downloads scroll under the search, chips and filters into Arx's progressive edge,
			// with no line (DEV-807, DEV-826).
			.arxScrollBar(background: nil) { header }
			.overlay {
				if store.searchedDownloads.isEmpty {
					Text(String.localized(.appUI.downloads.empty))
						.font(.system(size: BrowserMetrics.Row.fontSize))
						.foregroundStyle(BrowserTheme.secondary)
				}
			}

			if let message = store.message ?? store.queue.message {
				Text(message)
					.font(.caption)
					.foregroundStyle(.red)
					.padding(BrowserMetrics.Sidebar.horizontalPadding)
			}
		}
		.animation(reduceMotion ? nil : .snappy(duration: 0.22), value: store.isFilterPanePresented)
		.animation(reduceMotion ? nil : .snappy(duration: 0.22), value: activeFilters)
		.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
		.onAppear { store.send(.ui(.panelAppeared)) }
		.onDisappear { store.send(.ui(.panelDisappeared)) }
	}

	private var header: some View {
		VStack(spacing: 0) {
			SidebarLibraryHeader(
				placeholder: String.localized(.appUI.downloads.searchPlaceholder),
				query: $store.query.sending(\.ui.queryChanged)
			) {
				SidebarLibraryFilterButton(
					title: String.localized(.appUI.library.filter),
					count: activeFilters.count,
					isOpen: store.isFilterPanePresented,
					// A narrow panel keeps its room for the search field.
					showsTitle: width >= BrowserMetrics.Library.filterTitleMinimumWidth,
					action: { store.send(.ui(.filterPaneToggled)) }
				)
			}

			if !activeFilters.isEmpty {
				ArxFlowLayout(spacing: 4) {
					ForEach(activeFilters) { filter in
						SidebarLibraryFilterChip(filter.title) { store.send(filter.removal) }
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(.horizontal, BrowserMetrics.Library.headerInset)
				.padding(.bottom, BrowserMetrics.Library.headerBottomPadding)
				.transition(.opacity)
			}

			if store.isFilterPanePresented {
				filterPane
					.padding(.horizontal, BrowserMetrics.Library.headerInset)
					.padding(.bottom, BrowserMetrics.Library.headerBottomPadding)
					.transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
			}
		}
	}

	private var filterPane: some View {
		SidebarLibraryFilterPane(
			title: String.localized(.appUI.downloads.filterTitle),
			onDone: { store.send(.ui(.filterPaneDismissed)) }
		) {
			if !profiles.isEmpty {
				SidebarLibraryFilterSection(String.localized(.appUI.downloads.profiles)) {
					ForEach(profiles) { profile in
						SidebarLibraryChoiceChip(
							profile.name,
							isSelected: store.filter != .privateTransfers && store.profileFilter.contains(profile.id),
							action: { store.send(.ui(.profileFilterToggled(profile.id))) }
						)
					}
				}
			}
			SidebarLibraryFilterSection(String.localized(.appUI.downloads.privateSection)) {
				SidebarLibraryChoiceChip(
					String.localized(.appUI.downloads.privateTransfers),
					isSelected: store.filter == .privateTransfers,
					action: { store.send(.ui(.privateTransfersToggled)) }
				)
			}
		}
	}

	/// The header's chips: picked profiles that still exist, or Private Transfers.
	private var activeFilters: [ActiveFilter] {
		guard store.filter != .privateTransfers else {
			return [.init(
				id: "private",
				title: String.localized(.appUI.downloads.privateTransfers),
				removal: .ui(.privateTransfersToggled)
			)]
		}
		return profiles
			.filter { store.profileFilter.contains($0.id) }
			.map { profile in
				.init(
					id: profile.id.rawValue.uuidString,
					title: profile.name,
					removal: .ui(.profileFilterRemoved(profile.id))
				)
			}
	}

	private var groups: [SidebarLibraryGroup<BrowserDownload>] {
		SidebarLibraryGroup.grouping(store.searchedDownloads, date: \.startedAt)
	}

	private func row(_ download: BrowserDownload) -> some View {
		SidebarLibraryRow(
			title: download.filename.isEmpty ? String.localized(.appUI.downloads.preparing) : download.filename,
			subtitle: subtitle(download),
			action: { store.send(.ui(.open(download.id))) },
			icon: {
				Image(nsImage: icon(download))
					.resizable()
					.scaledToFit()
					.accessibilityHidden(true)
			},
			accessory: {
				if download.status == .inProgress {
					ProgressView(value: download.progress)
						.controlSize(.small)
				}
			}
		)
		.contextMenu { DownloadActions(download: download, send: { store.send($0) }) }
	}

	private func subtitle(_ download: BrowserDownload) -> String {
		// Finished downloads read as "Disk Image from cursor.com"; anything else states its status.
		guard download.status == .complete, !download.isDangerous, !download.isMissing else {
			return download.statusDescription
		}
		let kind = UTType(filenameExtension: (download.filename as NSString).pathExtension)?.localizedDescription
		guard let kind, let host = download.url?.host() else {
			return kind ?? String.localized(.appUI.downloads.item)
		}
		return String.localized(.appUI.downloads.kindFromHost(kind, host))
	}

	private func icon(_ download: BrowserDownload) -> NSImage {
		if let target = download.target, download.canOpen {
			return NSWorkspace.shared.icon(forFile: target.path)
		}
		let type = UTType(filenameExtension: (download.filename as NSString).pathExtension)
		return NSWorkspace.shared.icon(for: type ?? .data)
	}
}

/// A filter that's on, as the header shows it.
private struct ActiveFilter: Identifiable, Equatable {
	internal static func == (
		lhs: Self,
		rhs: Self
	) -> Bool {
		lhs.id == rhs.id && lhs.title == rhs.title
	}

	internal let id: String
	internal let title: String
	internal let removal: DownloadsFeature.Action
}
