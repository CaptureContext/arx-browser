import AppKit
import SwiftUI

/// Arx's prompt for a page's link to another app (DEV-857), portrait (DEV-872): the app's icon
/// and the title, the site that asked and the link, the caller's details (notes, the script,
/// a failure, Always allow), then full-width buttons at the bottom with the primary one last.
public struct AppLinkPromptCard<Details: View, Actions: View>: View {
	/// About 4:5.
	public static var width: CGFloat { 320 }
	public static var minimumHeight: CGFloat { 400 }

	private let icon: NSImage?
	private let symbol: String
	private let title: String
	private let source: String
	private let link: String
	private let details: Details
	private let actions: Actions

	/// `symbol` stands in for `icon` when there's none, such as a script with no app.
	public init(
		icon: NSImage?,
		symbol: String,
		title: String,
		source: String,
		link: String,
		@ViewBuilder details: () -> Details,
		@ViewBuilder actions: () -> Actions
	) {
		self.icon = icon
		self.symbol = symbol
		self.title = title
		self.source = source
		self.link = link
		self.details = details()
		self.actions = actions()
	}

	public var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 10) {
				Group {
					if let icon {
						Image(nsImage: icon)
							.resizable()
							.interpolation(.high)
					} else {
						Image(systemName: symbol)
							.resizable()
							.scaledToFit()
							.padding(8)
							.foregroundStyle(.secondary)
					}
				}
				.frame(width: 56, height: 56)
				.accessibilityHidden(true)
				Text(title)
					.font(.system(size: 17, weight: .semibold))
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
					.accessibilityAddTraits(.isHeader)
				Text(source)
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
				Text(link)
					.font(.caption.monospaced())
					.foregroundStyle(.secondary)
					.lineLimit(3)
					.truncationMode(.middle)
					.multilineTextAlignment(.center)
					.textSelection(.enabled)
			}
			.frame(maxWidth: .infinity)
			.padding(.bottom, 14)

			VStack(alignment: .leading, spacing: 10) {
				details
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			Spacer(minLength: 18)

			VStack(spacing: ArxModalMetrics.buttonSpacing) {
				actions
			}
			.frame(maxWidth: .infinity)
		}
		.padding(ArxModalMetrics.contentPadding)
		.frame(width: Self.width)
		.frame(minHeight: Self.minimumHeight)
	}
}

/// One of the prompt's full-width buttons, in Arx's modal style.
public struct AppLinkPromptButton: View {
	private let title: String
	private let prominence: ArxButtonStyle.Prominence
	private let keyHint: ArxKeyHint?
	private let action: () -> Void

	public init(
		_ title: String,
		prominence: ArxButtonStyle.Prominence = .secondary,
		keyHint: ArxKeyHint? = nil,
		action: @escaping () -> Void
	) {
		self.title = title
		self.prominence = prominence
		self.keyHint = keyHint
		self.action = action
	}

	public var body: some View {
		Button(action: action) {
			ArxButtonLabel(Text(title), keyHint: keyHint)
				.frame(maxWidth: .infinity)
		}
		.buttonStyle(.arxModal(prominence))
	}
}

/// The prompt's main button, full width, with Copy Link in the menu beside it. It's the
/// default button: Return presses it, and VoiceOver announces it as the default.
public struct AppLinkPromptConfirm: View {
	private let title: String
	private let copyTitle: String
	private let onConfirm: () -> Void
	private let onCopy: () -> Void

	public init(
		_ title: String,
		copyTitle: String,
		onConfirm: @escaping () -> Void,
		onCopy: @escaping () -> Void
	) {
		self.title = title
		self.copyTitle = copyTitle
		self.onConfirm = onConfirm
		self.onCopy = onCopy
	}

	public var body: some View {
		HStack(spacing: 4) {
			AppLinkPromptButton(title, prominence: .primary, keyHint: .return, action: onConfirm)
				.keyboardShortcut(.defaultAction)
			Menu {
				Button(copyTitle, action: onCopy)
			} label: {
				Image(systemName: "chevron.down")
					.font(.system(size: 11, weight: .bold))
					.accessibilityLabel(Text(copyTitle))
			}
			.menuStyle(.button)
			.menuIndicator(.hidden)
			.buttonStyle(.arxModal(.primary))
			.fixedSize()
		}
	}
}
