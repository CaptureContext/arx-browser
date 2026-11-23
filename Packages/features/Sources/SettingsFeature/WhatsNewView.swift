import AppKit
import AppUI
import AppUpdaterClient
import SwiftUI

/// The short What's New sheet the first launch after an update shows (DEV-888): the release
/// notes the update feed gave for this build, and a link to the full notes in the manual.
public struct WhatsNewView: View {
	private let whatsNew: AppUpdaterClient.WhatsNew
	private let openFullNotes: () -> Void
	private let dismiss: () -> Void

	public init(
		whatsNew: AppUpdaterClient.WhatsNew,
		openFullNotes: @escaping () -> Void,
		dismiss: @escaping () -> Void
	) {
		self.whatsNew = whatsNew
		self.openFullNotes = openFullNotes
		self.dismiss = dismiss
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			HStack(spacing: 12) {
				Image(nsImage: NSApplication.shared.applicationIconImage)
					.resizable()
					.frame(width: 48, height: 48)
					.accessibilityHidden(true)
				Text(localized: .appUI.whatsNew.title(whatsNew.version))
					.font(.title2.weight(.semibold))
			}
			ScrollView {
				Text(notes)
					.frame(maxWidth: .infinity, alignment: .leading)
					.textSelection(.enabled)
			}
			.frame(maxHeight: 280)
			.fixedSize(horizontal: false, vertical: true)
			HStack {
				Button(String.localized(.appUI.whatsNew.fullNotes), action: openFullNotes)
				Spacer()
				Button(String.localized(.appUI.whatsNew.continue), action: dismiss)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 440)
	}

	/// Markdown from the feed, with inline styles and line breaks kept; plain text otherwise.
	private var notes: AttributedString {
		guard let notes = whatsNew.notes
		else { return AttributedString(String.localized(.appUI.whatsNew.noNotes(whatsNew.version))) }

		let options: AttributedString.MarkdownParsingOptions = .init(
			interpretedSyntax: .inlineOnlyPreservingWhitespace
		)
		return (try? AttributedString(markdown: notes, options: options)) ?? AttributedString(notes)
	}
}
