import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

public struct TabArchiveView: View {
	@Bindable
	public var store: StoreOf<TabArchiveFeature>

	public init(store: StoreOf<TabArchiveFeature>) {
		self.store = store
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack {
				VStack(alignment: .leading) {
					Text(String.localized(.appUI.archive.title))
						.font(.title2.bold())
					Text(store.profileName)
						.foregroundStyle(.secondary)
				}
				Spacer()
				Button(String.localized(.appUI.common.done)) {
					store.send(.ui(.dismissed))
				}
				.keyboardShortcut(.cancelAction)
			}
			TextField(
				String.localized(.appUI.archive.searchPlaceholder),
				text: $store.query.sending(\.ui.queryChanged)
			)
			.textFieldStyle(.roundedBorder)
			.accessibilityLabel(String.localized(.appUI.archive.searchLabel))
			List(selection: $store.selectedIDs.sending(\.ui.selectionChanged)) {
				ForEach(store.visibleEntries) { entry in
					VStack(alignment: .leading, spacing: 3) {
						Text(entry.tab.displayTitle)
							.fontWeight(.medium)
						Text(entry.tab.restoration.url.absoluteString)
							.lineLimit(1)
							.foregroundStyle(.secondary)
						HStack {
							Text(store.spaces[id: entry.originalSpaceID]?.name ?? entry.originalSpaceName)
							Text(entry.closedAt, style: .date)
							Text(entry.closedAt, style: .time)
						}
						.font(.caption)
						.foregroundStyle(.secondary)
					}
					.tag(entry.id)
					.contextMenu {
						Button(String.localized(.appUI.archive.restoreGroup)) {
							store.send(.ui(.restoreGroup(entry.groupID, nil)))
						}
						Menu(String.localized(.appUI.archive.restoreGroupTo)) {
							destinations { destination in
								store.send(.ui(.restoreGroup(entry.groupID, destination)))
							}
						}
					}
				}
			}
			.overlay {
				if store.visibleEntries.isEmpty {
					ContentUnavailableView(
						store.query.isEmpty
						? String.localized(.appUI.archive.empty)
						: String.localized(.appUI.archive.noMatches),
						systemImage: "archivebox",
						description: store.query.isEmpty ? Text(store.emptyExplanation) : nil
					)
				}
			}
			if let message = store.message {
				Text(message)
					.foregroundStyle(.red)
					.accessibilityLabel(message)
			}
			HStack {
				Button(String.localized(.appUI.archive.restore)) {
					store.send(.ui(.restoreSelected(nil)))
				}
				.keyboardShortcut(.defaultAction)
				.disabled(store.selectedIDs.isEmpty)
				Menu(String.localized(.appUI.archive.restoreTo)) {
					destinations { destination in
						store.send(.ui(.restoreSelected(destination)))
					}
				}
				.disabled(store.selectedIDs.isEmpty)
				Button(String.localized(.appUI.archive.deleteSelected), role: .destructive) {
					store.send(.ui(.deleteSelected))
				}
				.disabled(store.selectedIDs.isEmpty)
				Spacer()
				if store.isWorking { ProgressView().controlSize(.small) }
				Button(String.localized(.appUI.archive.clear), role: .destructive) {
					store.send(.ui(.clearRequested))
				}
				.disabled(store.entries.isEmpty)
			}
			Text(String.localized(.appUI.archive.retention))
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(24)
		.frame(minWidth: 650, minHeight: 440)
		.disabled(store.isWorking)
		.modifier(TabArchiveConfirmations(store: store))
	}

	@ViewBuilder
	private func destinations(
		_ restore: @escaping (ArchiveDestination) -> Void
	) -> some View {
		let profiles = store.profiles.filter { profile in
			store.spaces.contains { $0.profileID == profile.id }
		}
		ForEach(profiles) { profile in
			Menu(profile.name) {
				ForEach(store.spaces.filter { $0.profileID == profile.id }) { space in
					Button(space.name) { restore(.init(space: space)) }
				}
			}
		}
	}
}

internal struct TabArchiveConfirmations: ViewModifier {
	@Bindable
	internal var store: StoreOf<TabArchiveFeature>

	internal func body(content: Content) -> some View {
		content
			.confirmationDialog(
				String.localized(.appUI.archive.clearConfirmation(store.profileName)),
				isPresented: Binding(
					get: { store.confirmsClear },
					set: { if !$0 { store.send(.ui(.clearCancelled)) } }
				)
			) {
				Button(String.localized(.appUI.archive.deleteAll), role: .destructive) {
					store.send(.ui(.clearConfirmed))
				}
			} message: {
				Text(String.localized(.appUI.archive.clearDescription))
			}
			.confirmationDialog(
				String.localized(.appUI.archive.restoreProfileConfirmation(
					store.restorationConfirmation?.profileName ?? ""
				)),
				isPresented: Binding(
					get: { store.restorationConfirmation != nil },
					set: { if !$0 { store.send(.ui(.restoreCancelled)) } }
				)
			) {
				if let confirmation = store.restorationConfirmation {
					Button(String.localized(.appUI.archive.restoreInProfile(confirmation.profileName))) {
						store.send(.ui(.restoreConfirmed(confirmation)))
					}
				}
			} message: {
				if let confirmation = store.restorationConfirmation {
					Text(String.localized(.appUI.archive.restoreProfileDescription(confirmation.spaceName)))
				}
			}
	}
}

extension TabArchiveFeature.State {
	/// What an empty archive says comes here: closed tabs, and those left unviewed for the
	/// profile's interval (DEV-1326).
	internal var emptyExplanation: String {
		guard let duration = archiveInterval?.duration else {
			return String.localized(.appUI.archive.emptyExplanationNever)
		}

		return String.localized(.appUI.archive.emptyExplanation(Self.durationText(duration)))
	}

	/// "6 hours", "1 day", "7 days", in the person's language.
	internal static func durationText(_ duration: TimeInterval) -> String {
		let formatter = DateComponentsFormatter()
		formatter.unitsStyle = .full
		formatter.allowedUnits = [.day, .hour]
		formatter.maximumUnitCount = 1
		return formatter.string(from: duration) ?? ""
	}
}
