import AppKit
import SwiftUI

/// The surfaces a command bar can attach to, published from separate parts of the window.
internal struct CommandBarAnchors {
	internal var url: Anchor<CGRect>?
	internal var pane: Anchor<CGRect>?

	internal init(
		url: Anchor<CGRect>? = nil,
		pane: Anchor<CGRect>? = nil
	) {
		self.url = url
		self.pane = pane
	}
}

internal struct CommandBarAnchorsKey: PreferenceKey {
	internal static let defaultValue: CommandBarAnchors = .init()

	internal static func reduce(
		value: inout CommandBarAnchors,
		nextValue: () -> CommandBarAnchors
	) {
		let next = nextValue()
		if let url = next.url { value.url = url }
		if let pane = next.pane { value.pane = pane }
	}
}

extension View {
	/// Marks the pane a new-pane command bar centers over.
	public func commandBarPaneAnchor(isActive: Bool) -> some View {
		anchorPreference(
			key: CommandBarAnchorsKey.self,
			value: .bounds
		) { .init(pane: isActive ? $0 : nil) }
	}

	/// Presents address editing over the URL field, or a centered command palette.
	///
	/// Address editing grows with `urlFieldText`, and by the "Ask an agent ⇥" hint's room while
	/// `urlFieldShowsAgentHint`, so the hint never takes the text's room (DEV-954).
	public func commandBarPresentation<Content: View>(
		isPresented: Bool,
		anchoredToURL: Bool,
		centeredOverPane: Bool = false,
		urlFieldText: String = "",
		urlFieldShowsAgentHint: Bool = false,
		onDismiss: @escaping () -> Void,
		@ViewBuilder content: @escaping (CGFloat) -> Content
	) -> some View {
		overlayPreferenceValue(CommandBarAnchorsKey.self) { anchors in
			if isPresented {
				GeometryReader { geometry in
					let metrics = BrowserMetrics.CommandBar.self
					let field = anchoredToURL ? anchors.url.map { geometry[$0] } : nil
					let pane = centeredOverPane ? anchors.pane.map { geometry[$0] } : nil
					let paletteWidth = min(
						metrics.width,
						(pane?.width ?? geometry.size.width) - 2 * metrics.margin,
						pane == nil ? geometry.size.width * metrics.maximumWidthFraction : .infinity
					)
					let maximumWidth = max(0, paletteWidth)
					let urlField = metrics.URLField.self
					let width = field.map { field in
						let font: NSFont = .systemFont(ofSize: urlField.inputFontSize, weight: .medium)
						let textWidth = (urlFieldText as NSString).size(withAttributes: [.font: font]).width
						let hint = CommandBarKeyHintButton.self
						let hintWidth = urlFieldShowsAgentHint
						? hint.width(title: hint.agentTitle, key: hint.agentKey) + metrics.inputSpacing
						: 0
						let wanted = max(
							urlField.minimumWidth,
							field.width + 2 * urlField.outset,
							ceil(textWidth) + urlField.textChromeWidth + hintWidth
						)
						return min(
							wanted,
							urlField.maximumWidth,
							geometry.size.width - 2 * urlField.outset
						)
					} ?? maximumWidth
					let inputHeight = field == nil ? metrics.inputHeight : urlField.inputHeight
					let top = field.map { max(urlField.outset, $0.midY - inputHeight / 2) }
					?? max(metrics.margin, (geometry.size.height * metrics.topFraction).rounded())
					let left = field.map { field in
						let maximumLeft = geometry.size.width - width - urlField.outset
						return min(max(urlField.outset, field.minX - urlField.outset), maximumLeft)
					}
					?? pane.map { ($0.midX - width / 2).rounded() }
					?? ((geometry.size.width - width) / 2).rounded()

					// The palette's content sits inside its bezel (DEV-1277); the address field's doesn't.
					let contentInset = field == nil ? metrics.contentInset : 0
					let chromeHeight = inputHeight + BrowserMetrics.Section.dividerThickness + 2 * contentInset
					let availableHeight = geometry.size.height - top - metrics.margin

					ZStack(alignment: .topLeading) {
						// Clear still has to catch the click that dismisses the bar.
						Color.black.opacity(0.001)
							.contentShape(.rect)
							.onTapGesture(perform: onDismiss)

						let resultsHeight = max(0, min(metrics.maximumResultsHeight, availableHeight - chromeHeight))

						content(resultsHeight)
							.frame(width: width)
							.padding(.leading, left)
							.padding(.top, top)
					}
				}
			}
		}
	}
}
