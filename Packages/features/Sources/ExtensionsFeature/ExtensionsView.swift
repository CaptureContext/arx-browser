import AppUI
import BrowserCore
import BrowserExtensionsClient
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

public struct ExtensionsView: View {
	public let store: StoreOf<ExtensionsFeature>

	public init(store: StoreOf<ExtensionsFeature>) {
		self.store = store
	}

	/// The header's actions, each shown only when it is today (Load Unpacked in developer mode,
	/// Check for Updates once a store extension can update).
	private var headerActions: [ArxIconAction] {
		var actions: [ArxIconAction] = []
		if store.canLoadUnpacked {
			actions.append(ArxIconAction(
				String.localized(.appUI.extensions.loadUnpacked),
				systemImage: "folder.badge.plus",
				isEnabled: !(store.isWorking || hasSelection || store.inventory == nil)
			) { store.send(.ui(.chooseUnpackedDirectory)) })
		}

		if store.isWebstoreAvailable {
			actions.append(ArxIconAction(
				String.localized(.appUI.extensions.chromeWebStore),
				systemImage: "bag",
				isEnabled: !hasSelection
			) { store.send(.ui(.openWebstore)) })
		}

		// DEV-776: shown once the profile has a store extension to check.
		if store.isWebstoreUpdateAvailable, !store.updatableExtensionIDs.isEmpty {
			actions.append(ArxIconAction(
				String.localized(.appUI.extensions.checkForUpdates),
				systemImage: "arrow.triangle.2.circlepath",
				isEnabled: !(store.isWorking || hasSelection)
			) { store.send(.ui(.checkForUpdates)) })
		}

		if store.isInstallationAvailable {
			actions.append(ArxIconAction(
				String.localized(.appUI.extensions.installPackage),
				systemImage: "shippingbox",
				isEnabled: !(store.isWorking || hasSelection || store.inventory == nil)
			) { store.send(.ui(.choosePackage(nil))) })
		}

		actions.append(ArxIconAction(
			String.localized(.appUI.extensions.refresh),
			systemImage: "arrow.clockwise",
			isEnabled: !(store.isWorking || hasSelection)
		) { store.send(.ui(.refresh)) })
		return actions
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// AppUI's header bar (DEV-782): a raised Close tile (Escape) in place of the large Done,
			// the title over the profile, and the actions as icons that name themselves on hover
			// (DEV-872), so the title and profile keep their room.
			ArxHeaderBar(
				.close { store.send(.ui(.dismiss)) },
				title: String.localized(.appUI.extensions.title),
				subtitle: store.profile?.name
			) {
				if store.isWorking {
					ProgressView()
						.controlSize(.small)
						.accessibilityLabel(String.localized(.appUI.extensions.working))
				}

				ArxIconActionGroup(headerActions)
			}

			// Above the content, which a hovered action's tooltip hangs over.
			.zIndex(1)

			content
				.padding(.horizontal, ArxModalMetrics.contentPadding)
				.padding(.bottom, ArxModalMetrics.contentPadding)
		}
		.frame(width: 760, height: 560)
		.arxModalSheet()
		.background {
			pickers
		}
		.sheet(item: Binding(
			get: { store.pendingInstallation },
			set: { value in
				if value == nil, let prompt = store.pendingInstallation {
					store.send(.ui(.respondToInstallation(prompt, false)))
				}
			}
		)) { prompt in
			installationPrompt(prompt)
		}
		.confirmationDialog(
			String.localized(.appUI.extensions.removeTitle),
			isPresented: Binding(
				get: { store.pendingRemoval != nil },
				set: { if !$0 { store.send(.ui(.cancelRemoval)) } }
			),
			titleVisibility: .visible,
			presenting: store.pendingRemoval
		) { request in
			removalActions(request)
		} message: { request in
			removalMessage(request)
		}
	}

	private var content: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(localized: .appUI.extensions.scope)
				.font(.callout)
				.foregroundStyle(.secondary)

			if store.canLoadUnpacked {
				Text(localized: .appUI.extensions.unpackedScope)
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			if let error = store.error {
				Text(ExtensionsPresentation.message(error))
					.foregroundStyle(.red)
					.accessibilityAddTraits(.updatesFrequently)
			}

			if let result = store.updateCheckResult {
				Text(ExtensionsPresentation.updateCheck(result))
					.font(.callout)
					.foregroundStyle(.secondary)
					.accessibilityAddTraits(.updatesFrequently)
			}

			if let inventory = store.inventory {
				if inventory.extensions.isEmpty {
					ContentUnavailableView {
						Label(String.localized(.appUI.extensions.empty), systemImage: "puzzlepiece.extension")
					} description: {
						// DEV-801: point an empty profile at the store.
						if store.isWebstoreAvailable {
							Text(localized: .appUI.extensions.emptyWebstoreHint)
						}
					} actions: {
						if store.isWebstoreAvailable {
							Button(String.localized(.appUI.extensions.chromeWebStore)) {
								store.send(.ui(.openWebstore))
							}
							.buttonStyle(.arxRaised(.capsule))
							.disabled(hasSelection)
						}
					}

				} else {
					HStack(alignment: .top, spacing: 16) {
						ScrollView {
							LazyVStack(alignment: .leading, spacing: 4) {
								ForEach(inventory.extensions) { item in
									let needsReview = store.pendingUpdateReviews.first(where: { $0.extensionID == item.id }) != nil
									Button {
										store.send(.ui(.select(item.id)))
									} label: {
										HStack(spacing: 10) {
											ExtensionIconTile(name: item.name, icon: icon(item), side: 28)
												.accessibilityHidden(true)

											VStack(alignment: .leading, spacing: 4) {
												Text(item.name)
													.lineLimit(2)

												Text(ExtensionsPresentation.state(item.state))
													.font(.caption)
													.foregroundStyle(.secondary)

												// DEV-1210: an update the automatic check turned down.
												if needsReview {
													Text(localized: .appUI.extensions.updateNeedsReview)
														.font(.caption)
														.foregroundStyle(.orange)
												}
											}

											Spacer(minLength: 0)

											if needsReview {
												// Leaves room for the mark, which is a button of its own.
												Color.clear.frame(width: 18, height: 18)
											}
										}
										.padding(10)
									}

									// The whole row selects, not only its text (DEV-1002).
									.buttonStyle(.arxListRow(isSelected: store.selectedID == item.id))
									.accessibilityAddTraits(store.selectedID == item.id ? .isSelected : [])
									.overlay(alignment: .trailing) {
										if needsReview {
											updateReviewMark(item)
												.padding(.trailing, 10)
										}
									}
								}
							}
						}
						.scrollEdgeEffectStyle(.soft, for: .all)
						.frame(width: 210)

						Divider()

						ScrollView {
							if let item = inventory.extensions.first(where: { $0.id == store.selectedID }) {
								details(item, inventory: inventory)
							}
						}
						.scrollEdgeEffectStyle(.soft, for: .all)
						.frame(maxWidth: .infinity, alignment: .leading)
					}
				}

			} else {
				Spacer()
			}

			Text(localized: .appUI.extensions.support)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private var pickers: some View {
		if let selection = store.packageSelection {
			PackagePicker(selection: selection) { result in
				switch result {
				case let .success(url): store.send(.ui(.selectPackage(selection, url)))
				case .failure: store.send(.ui(.cancelPackageSelection(selection)))
				}
			}
			.id(selection.id)
		}

		if let selection = store.directorySelection {
			DirectoryPicker(selection: selection) { result in
				switch result {
				case let .success(url): store.send(.ui(.selectDirectory(selection, url)))
				case .failure: store.send(.ui(.cancelDirectorySelection(selection)))
				}
			}
			.id(selection.id)
		}
	}

	@ViewBuilder
	private func removalActions(_ request: BrowserExtensionRequest) -> some View {
		Button(String.localized(.appUI.extensions.remove), role: .destructive) {
			store.send(.ui(.confirmRemoval(request)))
		}

		Button(String.localized(.appUI.common.cancel), role: .cancel) {
			store.send(.ui(.cancelRemoval))
		}
	}

	private func removalMessage(_ request: BrowserExtensionRequest) -> some View {
		let name = store.inventory?.extensions.first(where: { $0.id == request.extensionID })?.name
		?? request.extensionID

		return Text([
			name,
			store.profile?.name ?? "",
			String.localized(.appUI.extensions.removeMessage),
		].joined(separator: "\n"))
	}

	/// The extension's icon once read; nil shows its letter.
	private func icon(_ item: BrowserExtension) -> Data? {
		item.iconPath(pixels: ExtensionsFeature.iconPixels).flatMap { store.icons[$0] } ?? item.bundledIcon
	}

	/// The row's "Update needs review" mark (DEV-1210): opens that update's review.
	private func updateReviewMark(_ item: BrowserExtension) -> some View {
		Button {
			store.send(.ui(.reviewUpdate(item.id)))
		} label: {
			Image(systemName: "arrow.up.circle.fill")
				.font(.system(size: 15))
				.foregroundStyle(.orange)
		}
		.buttonStyle(.plain)
		.help(String.localized(.appUI.extensions.updateNeedsReview))
		.accessibilityLabel(String.localized(.appUI.extensions.updateNeedsReview))
		.accessibilityHint(String.localized(.appUI.extensions.reviewUpdate))
		.disabled(store.isWorking || hasSelection)
	}

	private var hasSelection: Bool {
		store.packageSelection != nil || store.directorySelection != nil
	}

	private func details(
		_ item: BrowserExtension,
		inventory: BrowserExtensionInventory
	) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				ExtensionIconTile(name: item.name, icon: icon(item), side: 40)
					.accessibilityHidden(true)

				Text(item.name)
					.font(.headline)
					.textSelection(.enabled)
			}

			LabeledContent(String.localized(.appUI.extensions.version), value: item.version)
			LabeledContent(String.localized(.appUI.extensions.identifier), value: item.id)
				.font(.caption)
				.textSelection(.enabled)

			LabeledContent(
				String.localized(.appUI.extensions.origin),
				value: ExtensionsPresentation.location(item.location)
			)

			if let folder = item.sourcePath {
				LabeledContent(String.localized(.appUI.extensions.sourceFolder), value: folder)
					.font(.caption)
					.textSelection(.enabled)
			}

			if item.fromWebStore {
				Text(localized: .appUI.extensions.fromWebStore)
					.font(.caption)
			}

			// DEV-1210: the update the automatic check turned down, and its review.
			if let review = store.pendingUpdateReviews.first(where: { $0.extensionID == item.id }) {
				VStack(alignment: .leading, spacing: 6) {
					Text(localized: .appUI.extensions.updateNeedsReviewDetail(review.version))
						.font(.callout)
						.fixedSize(horizontal: false, vertical: true)

					Button(String.localized(.appUI.extensions.reviewUpdate)) {
						store.send(.ui(.reviewUpdate(item.id)))
					}
					.disabled(store.isWorking || hasSelection)
				}
			}

			HStack {
				if store.optionsAvailable && item.canOpenOptions {
					Button(String.localized(.appUI.extensions.options)) {
						store.send(.ui(.openOptions(.init(inventory: inventory, extensionID: item.id))))
					}
				}

				if item.state == .enabled {
					Button(String.localized(.appUI.extensions.disable)) {
						store.send(.ui(.setEnabled(.init(
							inventory: inventory,
							extensionID: item.id,
							action: .disable
						))))
					}
					.disabled(!item.allows(.disable))

				} else {
					Button(String.localized(.appUI.extensions.enable)) {
						store.send(.ui(.setEnabled(.init(
							inventory: inventory,
							extensionID: item.id,
							action: .enable
						))))
					}
					.disabled(!item.allows(.enable))
				}

				if store.canLoadUnpacked && item.canReload {
					Button(String.localized(.appUI.extensions.reload)) {
						store.send(.ui(.reload(.init(
							inventory: inventory,
							extensionID: item.id,
							action: .reload
						))))
					}
				}

				if store.isInstallationAvailable && !item.canReload {
					Button(String.localized(.appUI.extensions.updatePackage)) {
						store.send(.ui(.choosePackage(item.id)))
					}
					.disabled(!item.allows(.remove))
				}

				Spacer()

				Button(String.localized(.appUI.extensions.remove), role: .destructive) {
					store.send(.ui(.requestRemoval(.init(
						inventory: inventory,
						extensionID: item.id,
						action: .remove
					))))
				}
				.disabled(!item.allows(.remove))
			}
			.disabled(store.isWorking || hasSelection)

			// DEV-889: a private window belongs to the profile it was opened from, and only the
			// extensions allowed here run in it.
			if item.canAllowInPrivate {
				VStack(alignment: .leading, spacing: 2) {
					Toggle(
						String.localized(.appUI.extensions.allowInPrivate),
						isOn: Binding(
							get: { item.allowedInPrivate },
							set: { allowed in
								store.send(.ui(.setAllowedInPrivate(.init(
									inventory: inventory,
									extensionID: item.id,
									action: allowed ? .allowInPrivate : .disallowInPrivate
								))))
							}
						)
					)
					.toggleStyle(.switch)

					Text(localized: .appUI.extensions.allowInPrivateDetail)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				.disabled(store.isWorking || hasSelection)
			}

			if item.permissionsIncreased {
				Text(localized: .appUI.extensions.permissionReview)
					.foregroundStyle(.secondary)
			}

			ForEach(item.disableReasons, id: \.self) { reason in
				Text(ExtensionsPresentation.reason(reason))
					.font(.caption)
					.foregroundStyle(.secondary)
			}

			permissions(String.localized(.appUI.extensions.required), item.requiredPermissions)
			permissions(String.localized(.appUI.extensions.optional), item.optionalPermissions)
			permissions(String.localized(.appUI.extensions.active), item.activePermissions)
			permissions(String.localized(.appUI.extensions.withheld), item.withheldPermissions)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func installationPrompt(_ prompt: BrowserExtensionInstallPrompt) -> some View {
		ExtensionInstallReview(prompt: prompt, profileName: store.profile?.name, requester: store.reviewRequester) { accept in
			store.send(.ui(.respondToInstallation(prompt, accept)))
		}
	}

	private func permissions(
		_ title: String,
		_ permissions: BrowserExtension.Permissions
	) -> some View {
		ExtensionPermissionsList(title: title, permissions: permissions)
	}
}

/// The standard folder panel. Its URL is only a candidate; Chromium validates it.
private struct DirectoryPicker: View {
	private let selection: ExtensionsFeature.DirectorySelection
	private let completion: @MainActor (Result<URL, Error>) -> Void

	@SwiftUI.State
	private var isPresented: Bool

	internal init(
		selection: ExtensionsFeature.DirectorySelection,
		completion: @escaping @MainActor (Result<URL, Error>) -> Void
	) {
		self.selection = selection
		self.completion = completion
		self._isPresented = .init(initialValue: true)
	}

	internal var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
			.fileImporter(
				isPresented: $isPresented,
				allowedContentTypes: [.folder],
				onCompletion: completion
			)
	}
}

private struct PackagePicker: View {
	private let selection: ExtensionsFeature.PackageSelection
	private let completion: @MainActor (Result<URL, Error>) -> Void

	@SwiftUI.State
	private var isPresented: Bool

	internal init(
		selection: ExtensionsFeature.PackageSelection,
		completion: @escaping @MainActor (Result<URL, Error>) -> Void
	) {
		self.selection = selection
		self.completion = completion
		self._isPresented = .init(initialValue: true)
	}

	internal var body: some View {
		Color.clear
			.frame(width: 0, height: 0)
			.fileImporter(
				isPresented: $isPresented,
				allowedContentTypes: [UTType(filenameExtension: "crx") ?? .data],
				onCompletion: completion
			)
	}
}
