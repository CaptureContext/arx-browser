import AppKit
import AppUI
import BrowserCore
import DiagnosticsClient
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// The Send Feedback card (DEV-1284), a Raised modal (DEV-1308): the title on a header bar, who
/// reads it, the kinds as a Raised segmented control, the text with its attach button and the
/// files under it, the email in a labeled field, Include diagnostics as a Settings switch row
/// with the privacy policy agreement under it, the versions, and Cancel and Send. Files come in
/// by the button, a drop on the card or ⌘V.
public struct SendFeedbackView: View {
	@Bindable
	private var store: StoreOf<SendFeedbackFeature>

	@SwiftUI.State
	private var isDropTargeted: Bool = false

	@FocusState
	private var isWriting: Bool

	public static let width: CGFloat = 480

	public init(store: StoreOf<SendFeedbackFeature>) {
		self.store = store
	}

	/// For renders: the card as it looks with files dragged over it.
	internal init(
		store: StoreOf<SendFeedbackFeature>,
		isDropTargeted: Bool
	) {
		self.store = store
		self._isDropTargeted = .init(initialValue: isDropTargeted)
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			ArxHeaderBar(.none, title: String.localized(.appUI.sendFeedback.title))

				// The bar's title lines up with the content under it; Cancel closes the card.
				.padding(.horizontal, ArxModalMetrics.contentPadding - ArxHeaderBarMetrics.horizontalPadding)
			VStack(alignment: .leading, spacing: 16) {
				header
				kinds

					// Above the text, which the Vulnerability hint hangs over.
					.zIndex(1)
				message
				if !store.draft.attachments.isEmpty || store.pendingAttachments > 0 {
					tiles
				}
				SettingsTextField(
					String.localized(.appUI.sendFeedback.email),
					text: Binding(get: { store.draft.email }, set: { store.send(.ui(.emailChanged($0))) }),
					prompt: String.localized(.appUI.sendFeedback.emailPrompt)
				)
				.textContentType(.emailAddress)
				.disabled(!store.isEditable)
				diagnostics
				if let failure = store.failure {
					Text(Self.text(failure))
						.font(.callout)
						.foregroundStyle(.red)
						.fixedSize(horizontal: false, vertical: true)
						.accessibilityAddTraits(.updatesFrequently)
				}
				footer
			}
			.padding([.horizontal, .bottom], ArxModalMetrics.contentPadding)
		}
		.frame(width: Self.width)
		.overlay { if isDropTargeted { dropOverlay } }
		.onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
			guard store.canAttach else { return false }

			attach(providers)
			return true
		}
		.onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in
			guard store.canAttach else { return }

			attach(providers)
		}
		.arxModalSheet()
		.task { store.send(.ui(.task)) }
	}

	// MARK: - Parts

	private var header: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(localized: .appUI.sendFeedback.privateNotice)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			Button(String.localized(.appUI.sendFeedback.publicIssue)) {
				store.send(.ui(.openPublicIssueForms))
			}
			.buttonStyle(.link)
			.font(.callout)
		}
	}

	private var kinds: some View {
		ArxSegmentedControl(
			SendFeedback.Kind.allCases.map { kind in
				ArxSegment(kind, title: Self.title(kind), hint: Self.hint(kind))
			},
			selection: store.draft.kind
		) { kind in
			store.send(.ui(.kindSelected(kind)))
		}
		.disabled(!store.isEditable)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.sendFeedback.kind))
	}

	private var message: some View {
		VStack(alignment: .leading, spacing: 6) {
			TextEditor(text: Binding(get: { store.draft.message }, set: { store.send(.ui(.messageChanged($0))) }))
				.font(.body)
				.focused($isWriting)
				.frame(height: 150)
				.scrollContentBackground(.hidden)
				.padding(.horizontal, 6)
				.padding(.top, 6)
				.padding(.bottom, 30)
				.background(.background.secondary, in: .rect(cornerRadius: 10))
				.overlay(alignment: .topLeading) {
					if store.draft.message.isEmpty {
						Text(Self.prompt(store.draft.kind))
							.foregroundStyle(.tertiary)
							.padding(.horizontal, 11)
							.padding(.vertical, 6)
							.allowsHitTesting(false)
					}
				}
				.overlay(alignment: .bottomTrailing) {
					Button {
						chooseFiles()
					} label: {
						Label(String.localized(.appUI.sendFeedback.attach), systemImage: "paperclip")
							.labelStyle(.iconOnly)
					}
					.buttonStyle(.arx(.plain, size: .small))
					.help(String.localized(.appUI.sendFeedback.attach))
					.disabled(!store.canAttach)
					.padding(6)
				}
				.accessibilityLabel(Text(Self.prompt(store.draft.kind)))
				.disabled(!store.isEditable)
			if store.draft.kind == .vulnerability {
				Text(localized: .appUI.sendFeedback.vulnerabilityNote)
					.font(.callout)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	private var tiles: some View {
		HStack(spacing: 8) {
			ForEach(store.draft.attachments) { attachment in
				FeedbackAttachmentTile(attachment: attachment) {
					store.send(.ui(.removeAttachment(attachment.id)))
				}
				.disabled(!store.isEditable)
			}
			ForEach(0 ..< store.pendingAttachments, id: \.self) { _ in
				ProgressView()
					.controlSize(.small)
					.frame(width: FeedbackAttachmentTile.side, height: FeedbackAttachmentTile.side)
					.background(.background.secondary, in: .rect(cornerRadius: 8))
			}
		}
	}

	private var diagnostics: some View {
		SettingsSection {
			SettingsToggle(
				String.localized(.appUI.sendFeedback.includeDiagnostics),
				detail: String.localized(.appUI.sendFeedback.diagnosticsDetail),
				isOn: Binding(get: { store.draft.includesDiagnostics }, set: { store.send(.ui(.includesDiagnostics($0))) })
			)
			.disabled(!store.isEditable)
		} footer: {
			// The policy's name is the link; it opens through the store, which closes the card.
			Text(Self.privacyAgreement)
				.environment(\.openURL, OpenURLAction { _ in
					store.send(.ui(.openPrivacyPolicy))
					return .handled
				})
		}
	}

	private var footer: some View {
		HStack(alignment: .firstTextBaseline, spacing: ArxModalMetrics.buttonSpacing) {
			if let versions {
				Text(localized: .appUI.sendFeedback.versions(versions))
					.font(.caption)
					.foregroundStyle(.tertiary)
					.fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
			}
			Spacer(minLength: 0)
			ArxModalButton.cancel { store.send(.ui(.close)) }
				.disabled(!store.canClose)
			ArxModalButton(
				store.isSending
				? String.localized(.appUI.sendFeedback.sending)
				: String.localized(.appUI.sendFeedback.send)
			) {
				store.send(.ui(.send))
			}
			.disabled(!store.isEditable || store.pendingAttachments > 0)
		}
	}

	private var dropOverlay: some View {
		RoundedRectangle(cornerRadius: 16, style: .continuous)
			.strokeBorder(Color.accentColor, style: .init(lineWidth: 2, dash: [6, 4]))
			.background(
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.fill(ArxModalMetrics.background.opacity(0.92))
			)
			.overlay {
				VStack(spacing: 6) {
					Image(systemName: "paperclip")
						.font(.title)
					Text(localized: .appUI.sendFeedback.dropToAttach)
						.font(.headline)
					Text(Self.limits)
						.font(.callout)
						.foregroundStyle(.secondary)
				}
			}
			.padding(6)
			.allowsHitTesting(false)
	}

	private var versions: String? {
		store.environment.map { environment in
			"Arx \(GitHubIssue.appVersion(environment)) · \(environment.macOSVersion)"
		}
	}

	// MARK: - Files

	private func chooseFiles() {
		let panel: NSOpenPanel = .init()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.allowedContentTypes = [.image, .movie, .plainText, .pdf]
		guard panel.runModal() == .OK
		else { return }

		store.send(.ui(.attachFiles(panel.urls)))
	}

	private func attach(_ providers: [NSItemProvider]) {
		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					guard let url else { return }

					Task { @MainActor in store.send(.ui(.attachFiles([url]))) }
				}
			} else if let type = [UTType.png, .jpeg, .tiff].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
				provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
					guard let data, let png = Self.pastedPicture(data, type: type)
					else { return }

					Task { @MainActor in
						store.send(.ui(.attachData(name: String.localized(.appUI.sendFeedback.pastedPictureName) + ".png", data: png)))
					}
				}
			}
		}
	}

	/// A pasted picture as PNG: screenshots arrive as TIFF, which the report doesn't take.
	private static func pastedPicture(_ data: Data, type: UTType) -> Data? {
		guard type == .tiff
		else { return data }

		return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
	}

	// MARK: - Text

	internal static func title(_ kind: SendFeedback.Kind) -> String {
		switch kind {
		case .bug: String.localized(.appUI.sendFeedback.kindBug)
		case .feature: String.localized(.appUI.sendFeedback.kindFeature)
		case .vulnerability: String.localized(.appUI.sendFeedback.kindVulnerability)
		case .other: String.localized(.appUI.sendFeedback.kindOther)
		}
	}

	/// A kind's tooltip in the kinds: only Vulnerability needs a word more than its name.
	internal static func hint(_ kind: SendFeedback.Kind) -> String? {
		switch kind {
		case .vulnerability: String.localized(.appUI.sendFeedback.vulnerabilityHint)
		case .bug, .feature, .other: nil
		}
	}

	/// "By sending this report, you agree to our Privacy Policy.", with the policy's name linked.
	internal static var privacyAgreement: AttributedString {
		let policy: String = .localized(.appUI.sendFeedback.privacyPolicy)
		var text: AttributedString = .init(String.localized(.appUI.sendFeedback.privacyAgreement(policy)))
		if let range = text.range(of: policy) {
			text[range].link = ArxService.privacyPolicy
		}
		return text
	}

	internal static func prompt(_ kind: SendFeedback.Kind) -> String {
		switch kind {
		case .bug: String.localized(.appUI.sendFeedback.promptBug)
		case .feature: String.localized(.appUI.sendFeedback.promptFeature)
		case .vulnerability: String.localized(.appUI.sendFeedback.promptVulnerability)
		case .other: String.localized(.appUI.sendFeedback.promptOther)
		}
	}

	private static func bytes(_ count: Int) -> String {
		count.formatted(.byteCount(style: .memory))
	}

	internal static var limits: String {
		String.localized(.appUI.sendFeedback.limits(SendFeedback.Limits.attachments, bytes(SendFeedback.Limits.attachmentBytes)))
	}

	/// What the sheet says for a failure, in plain words.
	public static func text(_ failure: FeedbackFailure) -> String {
		switch failure {
		case .emptyMessage: String.localized(.appUI.sendFeedback.failure.emptyMessage)
		case .invalidEmail: String.localized(.appUI.sendFeedback.failure.invalidEmail)
		case .offline: String.localized(.appUI.sendFeedback.failure.offline)
		case .tooLarge: String.localized(.appUI.sendFeedback.failure.tooLarge)
		case .tooMany: String.localized(.appUI.sendFeedback.failure.tooMany)
		case .unavailable: String.localized(.appUI.sendFeedback.failure.unavailable)
		case .refused: String.localized(.appUI.sendFeedback.failure.refused)
		case .tooManyFiles: String.localized(.appUI.sendFeedback.failure.tooManyFiles(SendFeedback.Limits.attachments))
		case let .fileTooLarge(name, total):
			String.localized(.appUI.sendFeedback.failure.fileTooLarge(name, bytes(total), bytes(SendFeedback.Limits.attachmentBytes)))
		case let .unsupportedFile(name): String.localized(.appUI.sendFeedback.failure.unsupportedFile(name))
		case let .unreadableFile(name): String.localized(.appUI.sendFeedback.failure.unreadableFile(name))
		}
	}
}

/// One attached file: a picture shows itself, anything else its extension; the button in its
/// corner removes it.
internal struct FeedbackAttachmentTile: View {
	internal static let side: CGFloat = 64

	internal let attachment: FeedbackAttachment
	internal let remove: () -> Void

	internal var body: some View {
		preview
			.frame(width: Self.side, height: Self.side)
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
			.overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
			.overlay(alignment: .topTrailing) {
				Button(action: remove) {
					Image(systemName: "xmark.circle.fill")
						.symbolRenderingMode(.palette)
						.foregroundStyle(.white, .black.opacity(0.6))
						.font(.system(size: 16))
				}
				.buttonStyle(.plain)
				.padding(3)
				.accessibilityLabel(Text(localized: .appUI.sendFeedback.removeAttachment(attachment.name)))
			}
			.help(attachment.name)
			.accessibilityElement(children: .contain)
			.accessibilityLabel(Text(attachment.name))
	}

	@ViewBuilder
	private var preview: some View {
		if attachment.isPicture, let image = NSImage(data: attachment.data) {
			Image(nsImage: image)
				.resizable()
				.scaledToFill()
		} else {
			Text(attachment.fileExtension)
				.font(.caption.weight(.semibold))
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(.background.secondary)
		}
	}
}
