import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

public struct DownloadsView: View {
	@Bindable
	public var store: StoreOf<DownloadsFeature>

	public init(store: StoreOf<DownloadsFeature>) {
		self.store = store
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack {
				Text(String.localized(.appUI.downloads.title))
					.font(.title2.bold())

				Spacer()

				Button(String.localized(.appUI.common.done)) {
					store.send(.ui(.dismissed))
				}
				.keyboardShortcut(.cancelAction)
			}

			Picker(
				String.localized(.appUI.downloads.scope),
				selection: $store.filter.sending(\.ui.filterChanged)
			) {
				Text(String.localized(.appUI.downloads.currentProfile))
					.tag(DownloadsFeature.Filter.currentProfile)

				Text(String.localized(.appUI.downloads.allProfiles))
					.tag(DownloadsFeature.Filter.allProfiles)

				Text(String.localized(.appUI.downloads.privateTransfers))
					.tag(DownloadsFeature.Filter.privateTransfers)
			}
			.pickerStyle(.segmented)

			if store.filter == .privateTransfers {
				Text(String.localized(.appUI.downloads.privateExplanation))
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			List(store.visibleDownloads) { download in
				HStack(alignment: .top, spacing: 12) {
					Image(systemName: download.isDangerous ? "exclamationmark.shield" : "arrow.down.document")
						.font(.title2)
						.accessibilityHidden(true)

					VStack(alignment: .leading, spacing: 5) {
						Text(download.filename.isEmpty ? String.localized(.appUI.downloads.preparing) : download.filename)
							.fontWeight(.medium)
							.textSelection(.enabled)

						Text([download.profileName, download.spaceName].compactMap { $0 }.joined(separator: " · "))
							.font(.caption)
							.foregroundStyle(.secondary)

						if download.status == .inProgress {
							if let progress = download.progress {
								ProgressView(value: progress)

							} else {
								ProgressView()
									.controlSize(.small)
							}

							Text(ByteCountFormatter.string(fromByteCount: download.receivedBytes, countStyle: .file))
								.font(.caption)
								.foregroundStyle(.secondary)
						}

						Text(download.statusDescription)
							.font(.caption)
							.foregroundStyle(.secondary)
					}

					Spacer()

					if download.canPause {
						Button(String.localized(.appUI.downloads.pause)) {
							store.send(.ui(.pause(download.id)))
						}
					} else if download.canResume {
						Button(String.localized(.appUI.downloads.resume)) {
							store.send(.ui(.resume(download.id)))
						}
					}

					if download.status == .inProgress {
						Button(String.localized(.appUI.downloads.cancel)) {
							store.send(.ui(.cancel(download.id)))
						}
					}

					if download.canOpen {
						Button(String.localized(.appUI.downloads.open)) {
							store.send(.ui(.open(download.id)))
						}

						Button(String.localized(.appUI.downloads.reveal)) {
							store.send(.ui(.reveal(download.id)))
						}
					}
				}
				.padding(.vertical, 6)
				.contextMenu { DownloadActions(download: download, send: { store.send($0) }) }
			}
			.overlay {
				if store.visibleDownloads.isEmpty {
					ContentUnavailableView(
						String.localized(.appUI.downloads.empty),
						systemImage: "arrow.down.circle"
					)
				}
			}

			if let message = store.message ?? store.queue.message {
				Text(message)
					.foregroundStyle(.red)
			}

			Text(String.localized(.appUI.downloads.destination))
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.padding(24)
		.frame(minWidth: 650, minHeight: 440)
		.task { await store.send(.ui(.appeared)).finish() }
		.onDisappear { store.send(.ui(.dismissed)) }
	}
}

/// A download's menu in the Downloads window and the Library panel (DEV-892).
internal struct DownloadActions: View {
	internal let download: BrowserDownload
	internal let send: (DownloadsFeature.Action) -> Void

	internal var body: some View {
		if download.canOpen {
			Button(String.localized(.appUI.downloads.open)) { send(.ui(.open(download.id))) }
			Button(String.localized(.appUI.downloads.reveal)) { send(.ui(.reveal(download.id))) }
		}
		if download.canPause {
			Button(String.localized(.appUI.downloads.pause)) { send(.ui(.pause(download.id))) }
		} else if download.canResume {
			Button(String.localized(.appUI.downloads.resume)) { send(.ui(.resume(download.id))) }
		}
		if download.status == .inProgress {
			Button(String.localized(.appUI.downloads.cancel)) { send(.ui(.cancel(download.id))) }
		}
		if download.canCopyLink {
			Divider()
			Button(String.localized(.appUI.downloads.copyLink)) { send(.ui(.copyLink(download.id))) }
		}
		if download.canRemoveFromList || download.canMoveToTrash {
			Divider()
		}
		if download.canRemoveFromList {
			Button(String.localized(.appUI.downloads.removeFromList)) { send(.ui(.removeFromList(download.id))) }
		}
		if download.canMoveToTrash {
			Button(String.localized(.appUI.downloads.moveToTrash)) { send(.ui(.moveToTrash(download.id))) }
		}
	}
}

extension BrowserDownload {
	internal var statusDescription: String {
		if isDangerous {
			return String.localized(.appUI.downloads.blocked)
		}

		if isMissing {
			return String.localized(.appUI.downloads.missing)
		}

		if isPaused {
			return String.localized(.appUI.downloads.paused)
		}

		switch status {
		case .inProgress: return String.localized(.appUI.downloads.inProgress)

		case .complete: return String.localized(.appUI.downloads.complete)

		case .cancelled: return String.localized(.appUI.downloads.cancelled)

		// One Chromium can continue, such as one a quit stopped (DEV-966), says Resume continues
		// it; its reason means nothing to the person (DEV-1152).
		case .interrupted where canResume: return String.localized(.appUI.downloads.resumable)

		case .interrupted: return String.localized(.appUI.downloads.interrupted) + " (\(interruptReason))"
		}
	}
}
