import AppUI
import BrowserCore
import ExtensionsFeature
import SwiftUI
import _ComposableArchitecture

extension View {
	/// The review for each store extension an import brings (DEV-845), shown by Customize and by
	/// onboarding's import page while the import's extension step runs. Dismissing it skips that
	/// extension.
	public func extensionImportReview(
		_ store: StoreOf<ExtensionImportFeature>?
	) -> some View {
		modifier(ExtensionImportReviewSheet(store: store))
	}
}

private struct ExtensionImportReviewSheet: ViewModifier {
	private let store: StoreOf<ExtensionImportFeature>?

	internal init(store: StoreOf<ExtensionImportFeature>?) {
		self.store = store
	}

	internal func body(content: Content) -> some View {
		content.sheet(item: Binding(
			get: { store?.prompt },
			set: { value in
				if value == nil, let prompt = store?.prompt {
					store?.send(.ui(.respond(prompt, false)))
				}
			}
		)) { prompt in
			if let store {
				review(prompt, store: store)
			}
		}
	}

	private func review(
		_ prompt: BrowserExtensionInstallPrompt,
		store: StoreOf<ExtensionImportFeature>
	) -> ExtensionImportReview {
		let detail: String = ExtensionImportReview.detail(
			publisher: prompt.candidate.publisher,
			position: store.position,
			sourceName: store.sourceName,
			profileName: store.current?.profileName
		)
		let acceptAllCount: Int? = store.offersAcceptAll ? store.remainingCount : nil
		return ExtensionImportReview(
			prompt: prompt,
			detail: detail,
			acceptAllCount: acceptAllCount,
			skipAll: { store.send(.ui(.skipAll)) },
			acceptAll: { store.send(.ui(.acceptAll)) },
			respond: { accept in store.send(.ui(.respond(prompt, accept))) }
		)
	}
}

/// One extension of an import's series (DEV-1300): "Add “uBlock Origin Lite”?", who publishes
/// it and where it goes, what it can do, and its package details folded away. Skip All, Skip,
/// Install All and Install; Install All says in one line what it does, since it installs the
/// rest without showing their reviews. Granting takes a click: Return doesn't install.
public struct ExtensionImportReview: View {
	private let prompt: BrowserExtensionInstallPrompt
	private let detail: String
	private let acceptAllCount: Int?
	private let skipAll: () -> Void
	private let acceptAll: () -> Void
	private let respond: (Bool) -> Void

	@SwiftUI.State
	private var showsDetails: Bool = false

	/// How tall what it can do and its details may grow before they scroll, so the sheet fits
	/// the onboarding window (540 points).
	internal static let contentMaxHeight: CGFloat = 240

	/// - Parameters:
	///   - detail: The line under the title, from ``detail(publisher:position:sourceName:profileName:)``.
	///   - acceptAllCount: How many Install All would install, this one included, or nil to hide it.
	public init(
		prompt: BrowserExtensionInstallPrompt,
		detail: String,
		acceptAllCount: Int?,
		skipAll: @escaping () -> Void,
		acceptAll: @escaping () -> Void,
		respond: @escaping (Bool) -> Void
	) {
		self.prompt = prompt
		self.detail = detail
		self.acceptAllCount = acceptAllCount
		self.skipAll = skipAll
		self.acceptAll = acceptAll
		self.respond = respond
	}

	/// "Raymond Hill · 2 of 3 from Chrome · into Personal", each part when it's known.
	public static func detail(
		publisher: String?,
		position: (index: Int, count: Int)?,
		sourceName: String?,
		profileName: String?
	) -> String {
		let place: String? = switch (position, sourceName, profileName) {
		case let (position?, source?, profile?):
			String.localized(.appUI.extensions.importReview.positionFromInto(position.index, position.count, source, profile))
		case let (position?, nil, profile?):
			String.localized(.appUI.extensions.importReview.positionInto(position.index, position.count, profile))
		case let (position?, _, nil):
			String.localized(.appUI.migration.extensionsProgress(position.index, position.count))
		case let (nil, _, profile?):
			String.localized(.appUI.extensions.importReview.into(profile))
		case (nil, _, nil):
			nil
		}
		switch (publisher, place) {
		case let (publisher?, place?): return String.localized(.appUI.extensions.importReview.byPublisher(publisher, place))
		case let (publisher?, nil): return publisher
		case let (nil, place?): return place
		case (nil, nil): return ""
		}
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			header

			// What it can do and its details scroll once they outgrow the sheet, so a long list
			// of permissions can always be read whole; the buttons stay below.
			ScrollView {
				VStack(alignment: .leading, spacing: 16) {
					if !prompt.candidate.warnings.isEmpty {
						capabilities
					}

					DisclosureGroup(isExpanded: $showsDetails) {
						details
					} label: {
						Text(localized: .appUI.extensions.importReview.details)
							.font(.callout)
							.foregroundStyle(.secondary)
					}
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
			.scrollBounceBehavior(.basedOnSize)
			.frame(maxHeight: ExtensionImportReview.contentMaxHeight)

			if acceptAllCount != nil {
				Text(localized: .appUI.extensions.importReview.installAllNote)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}

			buttons
		}
		.padding(24)
		.frame(width: 520)
		.arxModalSheet()
	}

	private var header: some View {
		HStack(spacing: 12) {
			Image(systemName: "puzzlepiece.extension.fill")
				.font(.system(size: 20, weight: .medium))
				.foregroundStyle(.white)
				.frame(width: 44, height: 44)
				.background(.tint, in: .rect(cornerRadius: 10))
				.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 2) {
				Text(localized: .appUI.extensions.importReview.title(prompt.candidate.name))
					.font(.headline)
					.accessibilityAddTraits(.isHeader)
				if !detail.isEmpty {
					Text(detail)
						.font(.callout)
						.foregroundStyle(.secondary)
				}
			}
		}
	}

	/// What it can do, in Chromium's words for its permissions.
	private var capabilities: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(localized: .appUI.extensions.importReview.itCan)
				.font(.callout)
				.foregroundStyle(.secondary)

			VStack(alignment: .leading, spacing: 8) {
				ForEach(Array(prompt.candidate.warnings.enumerated()), id: \.offset) { _, warning in
					Label {
						VStack(alignment: .leading, spacing: 2) {
							Text(warning.message)
							ForEach(Array(warning.details.enumerated()), id: \.offset) { _, detail in
								Text(detail)
									.font(.callout)
									.foregroundStyle(.secondary)
							}
						}
					} icon: {
						Image(systemName: "checkmark.shield")
							.foregroundStyle(.secondary)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(12)
			.background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10))
		}
	}

	private var details: some View {
		VStack(alignment: .leading, spacing: 8) {
			if let publisher = prompt.candidate.publisher {
				LabeledContent(String.localized(.appUI.extensions.publisher), value: publisher)
			}
			LabeledContent(String.localized(.appUI.extensions.version), value: prompt.candidate.version)
			LabeledContent(String.localized(.appUI.extensions.identifier), value: prompt.candidate.extensionID)
			LabeledContent(String.localized(.appUI.extensions.package), value: prompt.candidate.sourceBasename)
			LabeledContent(String.localized(.appUI.extensions.packageHash), value: prompt.candidate.packageSHA256)
				.font(.caption)
			ExtensionPermissionsList(
				title: String.localized(.appUI.extensions.required),
				permissions: prompt.candidate.requiredPermissions
			)
			ExtensionPermissionsList(
				title: String.localized(.appUI.extensions.optional),
				permissions: prompt.candidate.optionalPermissions
			)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.textSelection(.enabled)
		.padding(.top, 6)
	}

	private var buttons: some View {
		HStack(spacing: ArxModalMetrics.buttonSpacing) {
			Button(String.localized(.appUI.extensions.skipAll), action: skipAll)
				.buttonStyle(.arx(.plain, size: ArxModalMetrics.buttonSize))

			Spacer(minLength: 8)

			// Each button keeps its whole title and key; the space before them gives way.
			ArxModalButton.cancel(String.localized(.appUI.extensions.importReview.skip)) {
				respond(false)
			}
			.fixedSize()

			if let acceptAllCount {
				ArxModalButton(
					String.localized(.appUI.extensions.importReview.installAll(acceptAllCount)),
					prominence: .secondary,
					key: nil,
					action: acceptAll
				)
				.fixedSize()
			}

			// Granting an extension's permissions takes a click: Return doesn't install it.
			ArxModalButton(String.localized(.appUI.extensions.install), key: nil) {
				respond(true)
			}
			.fixedSize()
		}

	}
}
