import AppKit
import AppUI
import SwiftUI
import UniformTypeIdentifiers

extension ChatMetrics {
	/// The widest the composer gets, so it stays readable in a wide chat tab (DEV-798).
	public static let composerMaxWidth: CGFloat = 720

	/// The widest the transcript's text gets, matching the composer.
	public static let transcriptMaxWidth: CGFloat = 720
}

/// Where else the + menu attaches from, besides tabs and folders (DEV-798).
internal enum ChatAttachSource: Hashable, CaseIterable {
	/// Files…: images, PDFs and text from the Mac.
	case files

	/// Captures the page's visible area into the chat.
	case captureVisible

	/// Picks a block or draws an area on the page, then sends it to the chat.
	case captureArea

	internal static func available(canCapture: Bool) -> [Self] {
		canCapture ? allCases : [.files]
	}

	internal var title: String {
		switch self {
		case .files: String.localized(.appUI.chat.attachFiles)
		case .captureVisible: String.localized(.appUI.chat.attachCaptureVisible)
		case .captureArea: String.localized(.appUI.chat.attachCaptureArea)
		}
	}

	internal var symbol: String {
		switch self {
		case .files: "paperclip"
		case .captureVisible: "camera.viewfinder"
		case .captureArea: "crop"
		}
	}
}

/// Files… in the + menu: an open panel for images, PDFs and text files.
@MainActor
internal enum ChatFilePicker {
	internal static let contentTypes: [UTType] = [.image, .pdf, .text, .sourceCode, .json]

	internal static func present(_ choose: @escaping @MainActor ([URL]) -> Void) {
		let panel: NSOpenPanel = .init()
		panel.allowsMultipleSelection = true
		panel.canChooseDirectories = false
		panel.canChooseFiles = true
		panel.allowedContentTypes = contentTypes
		panel.prompt = String.localized(.appUI.chat.attach)
		panel.begin { response in
			guard response == .OK
			else { return }

			let urls: [URL] = panel.urls
			MainActor.assumeIsolated { choose(urls) }
		}
	}
}

/// Why a file didn't join the message, under the chips, with a ×.
internal struct ChatAttachmentIssueView: View {
	internal let issue: ChatAttachmentIssue
	internal let dismiss: () -> Void

	internal init(
		issue: ChatAttachmentIssue,
		dismiss: @escaping () -> Void
	) {
		self.issue = issue
		self.dismiss = dismiss
	}

	internal var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Image(systemName: "exclamationmark.triangle.fill")
				.font(.system(size: 10))
				.accessibilityHidden(true)
			Text(issue.message)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 4)
			Button(action: dismiss) {
				Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
			}
			.buttonStyle(.plain)
			.foregroundStyle(.secondary)
			.accessibilityLabel(String.localized(.appUI.chat.dismiss))
		}
		.font(.system(size: 11.5))
		.foregroundStyle(Color.orange)
		.padding(.horizontal, 4)
		.accessibilityElement(children: .combine)
	}
}

/// A menu row that highlights while hovered.
internal struct ChatMenuRowStyle: ButtonStyle {
	internal init() {}

	internal func makeBody(configuration: Configuration) -> some View {
		ChatMenuRow(configuration: configuration)
	}

	private struct ChatMenuRow: View {
		internal let configuration: Configuration

		@SwiftUI.State
		private var isHovered: Bool = false

		internal var body: some View {
			configuration.label
				.background(
					isHovered || configuration.isPressed ? BrowserTheme.hover : .clear,
					in: .rect(cornerRadius: 8, style: .continuous)
				)
				.onHover { isHovered = $0 }
		}
	}
}
