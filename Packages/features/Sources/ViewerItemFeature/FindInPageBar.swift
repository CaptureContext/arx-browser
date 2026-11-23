import AppKit
import AppUI
import BrowserCore
import SwiftUI

/// A small bar at the page's top right, on floating raised glass (DEV-1272). Return moves on,
/// and Shift-Return moves back.
internal struct FindInPageBar: View {
	private let query: String
	private let result: BrowserNavigation.FindResult?

	/// Changes on each ⌘F: the field takes focus and selects its text (DEV-1222).
	private let focusRequest: Int
	private let onChange: (String) -> Void
	private let onStep: (Bool) -> Void
	private let onDismiss: () -> Void

	@FocusState
	private var isFocused: Bool

	@SwiftUI.State
	private var selection: TextSelection?

	/// The keys Previous and Next name in their tooltips: the window's, or the defaults.
	@Environment(\.browserShortcuts)
	private var shortcuts

	internal init(
		query: String,
		result: BrowserNavigation.FindResult?,
		focusRequest: Int = 0,
		onChange: @escaping (String) -> Void,
		onStep: @escaping (Bool) -> Void,
		onDismiss: @escaping () -> Void
	) {
		self.query = query
		self.result = result
		self.focusRequest = focusRequest
		self.onChange = onChange
		self.onStep = onStep
		self.onDismiss = onDismiss
	}

	internal var body: some View {
		let placeholder = String.localized(.appUI.find.placeholder)

		// The raised glass a folder's hover preview searches in (DEV-1272): the field, its count
		// at its end, Previous and Next after it (DEV-1297), and Close beside it.
		HStack(spacing: ArxFloatingGlass.controlSpacing) {
			ArxGlassSearchField(placeholder: placeholder, isEmpty: query.isEmpty, onEscape: onDismiss) {
				TextField(
					placeholder,
					text: Binding(
						get: { query },
						set: { onChange($0) }
					),
					selection: $selection,
					prompt: Text(verbatim: "")
				)
				.focused($isFocused)
				.onSubmit {
					onStep(!NSEvent.modifierFlags.contains(.shift))
					isFocused = true
				}
				.accessibilityLabel(Text(verbatim: placeholder))
			} trailing: {
				if let result, !query.isEmpty {
					Text(verbatim: "\(result.active)/\(result.matches)")
						.font(.system(size: BrowserMetrics.FindBar.countFontSize))
						.monospacedDigit()
						.foregroundStyle(BrowserTheme.secondary)
				}
			} accessories: {
				stepButton(.findPrevious)
				stepButton(.findNext)
			}
			ArxGlassCloseButton(action: onDismiss)
		}
		.frame(width: BrowserMetrics.FindBar.width, height: BrowserMetrics.FindBar.height)
		.onAppear { isFocused = true }
		.onChange(of: focusRequest) { refocus() }
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.find.command))
	}

	/// Whether there's a match to step to, which Previous and Next need.
	internal static func canStep(
		query: String,
		result: BrowserNavigation.FindResult?
	) -> Bool {
		!query.isEmpty && (result?.matches ?? 0) > 0
	}

	/// What Previous and Next do: what ⇧Return and Return do in the field, and the keyboard stays
	/// in it.
	internal func step(_ command: BrowserCommand) {
		onStep(command == .findNext)
		isFocused = true
	}

	/// Previous (⇧⌘G, ⇧Return) or Next (⌘G, Return) as an arrow in the field (DEV-1297). A click
	/// leaves the keyboard in the field.
	private func stepButton(_ command: BrowserCommand) -> some View {
		let title = command.title
		let help = shortcuts.shortcut(for: command).map {
			String.localized(.appUI.common.titleWithShortcut(title, $0.display))
		} ?? title
		return Button {
			step(command)
		} label: {
			Image(systemName: command.symbol)
				.font(.system(size: ArxFloatingGlass.fontSize, weight: .medium))
		}
		.buttonStyle(.arxRaised(.item, isSquare: true))
		.focusEffectDisabled()
		.disabled(!Self.canStep(query: query, result: result))
		.help(help)
		.accessibilityLabel(Text(verbatim: title))
	}

	/// ⌘F on a bar that's already open (DEV-1222): the field takes focus back, wherever it went,
	/// and selects its text, so the next keystroke replaces the query. Focus first lets go, so
	/// SwiftUI asks AppKit again even when it still thinks the field has it; the text is selected
	/// once the field editor is in place.
	private func refocus() {
		isFocused = false
		DispatchQueue.main.async {
			isFocused = true
			DispatchQueue.main.async {
				selection = TextSelection(range: query.startIndex..<query.endIndex)
			}
		}
	}
}
