import AppKit
import SwiftUI

/// A hint at the input's trailing edge that names what a key does and does it when clicked,
/// as Raycast's "Quick AI ⇥": the command bar's "Ask an agent ⇥" (DEV-751).
///
/// Plain text and a key cap at rest; on hover a subtle fill with Arx's control corners, and the
/// text brightens. It never takes keyboard focus: the key itself is the keyboard path.
public struct CommandBarKeyHintButton: View {
	private let title: String

	/// No key cap when nil, as for a command whose shortcut is turned off.
	private let key: String?
	private let keyName: String
	private let action: () -> Void

	@SwiftUI.State
	private var isHovered: Bool = false

	@Environment(\.arxControlStateOverride)
	private var stateOverride

	@Environment(\.colorSchemeContrast)
	private var contrast

	public init(
		_ title: String,
		key: String?,
		keyName: String,
		action: @escaping () -> Void
	) {
		self.title = title
		self.key = key
		self.keyName = keyName
		self.action = action
	}

	public var body: some View {
		let metrics = BrowserMetrics.CommandBar.KeyHint.self
		let hovered = stateOverride.isHovered ?? isHovered
		Button(action: action) {
			HStack(spacing: metrics.spacing) {
				Text(verbatim: title)
					.font(.system(size: metrics.fontSize, weight: .medium))
					.lineLimit(1)
					.fixedSize()
				if let key {
					Text(verbatim: key)
						.font(.system(size: metrics.keyFontSize, weight: .semibold))
						.padding(.horizontal, key.count > 1 ? metrics.wideKeyPadding : 0)
						.frame(minWidth: metrics.keySize, minHeight: metrics.keySize, maxHeight: metrics.keySize)
						.overlay {
							ArxControlShape()
								.strokeBorder(.primary.opacity(hovered ? 0.4 : 0.28), lineWidth: metrics.keyStroke)
						}
				}
			}
			.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.State.opacity(hovered ? 0.82 : 0.5, contrast: contrast)))
			.padding(.leading, metrics.horizontalPadding)
			.padding(.trailing, key == nil ? metrics.horizontalPadding : metrics.trailingPadding)
			.frame(height: metrics.height)
			.background {
				if hovered {
					ArxControlShape().fill(.primary.opacity(0.08))
				}
			}
			.contentShape(ArxControlShape())
		}
		.buttonStyle(.plain)
		.focusable(false)
		.onHover { isHovered = $0 }
		.accessibilityLabel(Text(verbatim: keyName.isEmpty ? title : title + ", " + keyName))
	}
}

extension CommandBarKeyHintButton {
	/// The command bar's "Ask an agent ⇥" hint.
	internal static var agentTitle: String { .localized(.appUI.command.askAgent) }
	internal static let agentKey: String = "⇥"

	/// ⌘↩, opening what's typed as an address (DEV-1189).
	public static let openURLKey: String = "⌘↩"

	/// How wide the hint lays out, for a panel that sizes itself around its text, as ⌘L's
	/// address field does (DEV-954).
	internal static func width(
		title: String,
		key: String?
	) -> CGFloat {
		let metrics = BrowserMetrics.CommandBar.KeyHint.self
		let titleWidth = (title as NSString).size(withAttributes: [
			.font: NSFont.systemFont(ofSize: metrics.fontSize, weight: .medium),
		]).width
		guard let key else { return ceil(titleWidth) + 2 * metrics.horizontalPadding }

		let keyWidth = (key as NSString).size(withAttributes: [
			.font: NSFont.systemFont(ofSize: metrics.keyFontSize, weight: .semibold),
		]).width
		let cap = max(metrics.keySize, ceil(keyWidth) + (key.count > 1 ? 2 * metrics.wideKeyPadding : 0))
		return metrics.horizontalPadding + ceil(titleWidth) + metrics.spacing + cap + metrics.trailingPadding
	}
}
