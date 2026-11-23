import AppKit
import SwiftUI

/// A one-line URL template with live placeholder colors and completions as `{` is typed.
///
/// AppKit, because completion needs the caret's position and the field's own key handling.
public struct TemplateField: NSViewRepresentable {
	private let placeholder: String
	private let label: String
	private let placeholders: [TemplatePlaceholder]
	private let isBordered: Bool

	@Binding
	private var text: String

	public init(
		_ placeholder: String,
		text: Binding<String>,
		placeholders: [TemplatePlaceholder],
		isBordered: Bool = true,
		label: String? = nil
	) {
		self.placeholder = placeholder
		self.label = label ?? placeholder
		self._text = text
		self.placeholders = placeholders
		self.isBordered = isBordered
	}

	public func makeCoordinator() -> Coordinator {
		.init(self)
	}

	public func makeNSView(context: Context) -> NSTextField {
		let field = NSTextField()
		field.delegate = context.coordinator
		field.font = Coordinator.font
		if isBordered {
			field.bezelStyle = .roundedBezel
		} else {
			// Drawn inside a field frame, such as Settings' `SettingsFieldFrame`. It keeps the
			// native focus ring, since the frame can't tell when an AppKit field has focus.
			field.isBordered = false
			field.drawsBackground = false
		}
		field.lineBreakMode = .byTruncatingTail
		field.cell?.isScrollable = true
		field.cell?.usesSingleLineMode = true
		field.setContentHuggingPriority(.defaultLow, for: .horizontal)
		field.placeholderString = placeholder
		field.setAccessibilityLabel(label)
		context.coordinator.show(text, in: field)
		return field
	}

	public func updateNSView(
		_ field: NSTextField,
		context: Context
	) {
		context.coordinator.parent = self
		field.placeholderString = placeholder
		if field.currentEditor() == nil {
			context.coordinator.show(text, in: field)
		} else if field.stringValue != text {
			field.stringValue = text
			context.coordinator.highlight(field)
		}
	}

	public static func dismantleNSView(
		_ field: NSTextField,
		coordinator: Coordinator
	) {
		coordinator.closeCompletions()
	}

	@MainActor
	public final class Coordinator: NSObject, NSTextFieldDelegate {
		fileprivate static let font: NSFont = .monospacedSystemFont(
			ofSize: NSFont.systemFontSize,
			weight: .regular
		)

		fileprivate var parent: TemplateField
		private var completion: TemplateSyntax.Completion?
		private var options: [TemplatePlaceholder] = []
		private var selectedIndex: Int = 0
		private var panel: ArxSuggestionPanel?

		fileprivate init(_ parent: TemplateField) {
			self.parent = parent
		}

		private var known: Set<String> { Set(parent.placeholders.map(\.name)) }

		fileprivate func show(
			_ text: String,
			in field: NSTextField
		) {
			field.attributedStringValue = attributed(text)
		}

		private func attributed(_ text: String) -> NSAttributedString {
			let result: NSMutableAttributedString = .init(
				string: text,
				attributes: [
					.font: Self.font,
					.foregroundColor: NSColor.labelColor,
				]
			)
			for token in TemplateSyntax.tokens(in: text) {
				for (range, color) in colors(of: token) {
					result.addAttribute(.foregroundColor, value: color, range: range)
				}
			}
			return result
		}

		private func colors(of token: TemplateSyntax.Token) -> [(NSRange, NSColor)] {
			let brace: NSColor = token.isClosed && known.contains(token.name) ? .systemGreen : .systemRed
			let start = token.range.location
			var colors: [(NSRange, NSColor)] = [
				(NSRange(location: start, length: 1), brace),
				(NSRange(location: start + 1, length: (token.name as NSString).length), .secondaryLabelColor),
			]
			if token.isClosed {
				let closingBrace = NSRange(location: NSMaxRange(token.range) - 1, length: 1)
				colors.append((closingBrace, brace))
			}
			return colors
		}

		/// Temporary attributes color the field editor without entering its undo history.
		fileprivate func highlight(_ field: NSTextField) {
			guard
				let editor = field.currentEditor() as? NSTextView,
				let layout = editor.layoutManager
			else { return }
			let whole = NSRange(location: 0, length: (editor.string as NSString).length)
			layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
			for token in TemplateSyntax.tokens(in: editor.string) {
				for (range, color) in colors(of: token) {
					layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
				}
			}
		}

		public func controlTextDidBeginEditing(_ notification: Notification) {
			if let field = notification.object as? NSTextField { highlight(field) }
		}

		public func controlTextDidChange(_ notification: Notification) {
			guard let field = notification.object as? NSTextField else { return }
			parent.text = field.stringValue
			highlight(field)
			updateCompletions(for: field)
		}

		public func controlTextDidEndEditing(_ notification: Notification) {
			closeCompletions()
			if let field = notification.object as? NSTextField {
				parent.text = field.stringValue
				show(field.stringValue, in: field)
			}
		}

		public func control(
			_ control: NSControl,
			textView: NSTextView,
			doCommandBy selector: Selector
		) -> Bool {
			guard !options.isEmpty, let field = control as? NSTextField else { return false }
			switch selector {
			case #selector(NSResponder.moveDown(_:)):
				move(by: 1, in: field)
			case #selector(NSResponder.moveUp(_:)):
				move(by: -1, in: field)
			case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
				accept(options[selectedIndex], in: field)
			case #selector(NSResponder.cancelOperation(_:)):
				closeCompletions()
			default:
				return false
			}
			return true
		}

		private func move(
			by offset: Int,
			in field: NSTextField
		) {
			selectedIndex = min(max(selectedIndex + offset, 0), options.count - 1)
			present(in: field)
		}

		private func updateCompletions(for field: NSTextField) {
			guard let editor = field.currentEditor() as? NSTextView else { return }
			let text = editor.string
			let caret = editor.selectedRange().location
			guard let found = TemplateSyntax.completion(in: text, caret: caret) else {
				closeCompletions()
				return
			}
			completion = found
			options = TemplateSyntax.options(for: found, from: parent.placeholders, in: text)
			selectedIndex = min(selectedIndex, max(options.count - 1, 0))
			if options.isEmpty {
				closeCompletions()
			} else {
				present(in: field)
			}
		}

		private func accept(
			_ placeholder: TemplatePlaceholder,
			in field: NSTextField
		) {
			guard
				let editor = field.currentEditor() as? NSTextView,
				let completion
			else { return }
			let result = TemplateSyntax.accepting(
				placeholder,
				for: completion,
				in: editor.string,
				caret: editor.selectedRange().location
			)
			let whole = NSRange(location: 0, length: (editor.string as NSString).length)

			// Through the text view, so one undo takes the whole completion back.
			if editor.shouldChangeText(in: whole, replacementString: result.text) {
				editor.replaceCharacters(in: whole, with: result.text)
				editor.didChangeText()
			}
			editor.setSelectedRange(NSRange(location: result.caret, length: 0))
			parent.text = result.text
			highlight(field)
			closeCompletions()
		}

		private func present(in field: NSTextField) {
			guard
				let window = field.window,
				let editor = field.currentEditor() as? NSTextView,
				let completion
			else { return }
			let highlighted = options.indices.contains(selectedIndex) ? options[selectedIndex].id : nil
			let list = ArxSuggestionList(
				options.map { ArxSuggestion(id: $0.id, title: $0.title, symbol: $0.symbol) },
				highlighted: highlighted
			) { [weak self, weak field, options] suggestion in
				guard
					let field,
					let option = options.first(where: { $0.id == suggestion.id })
				else { return }
				self?.accept(option, in: field)
			}
			let panel = self.panel ?? ArxSuggestionPanel(parent: window)
			self.panel = panel
			let anchor = editor.firstRect(
				forCharacterRange: NSRange(location: completion.start, length: 0),
				actualRange: nil
			)
			panel.show(list, below: anchor)
		}

		fileprivate func closeCompletions() {
			completion = nil
			options = []
			selectedIndex = 0
			panel?.close()
			panel = nil
		}
	}
}

extension TemplatePlaceholder {
	/// A link's subdomain with its dot, such as `vm.`, which starts a Proxy Links host (DEV-1003).
	public static let subdomain: Self = .init(
		name: "subdomain",
		title: String.localized(.appUI.links.placeholderSubdomain),
		symbol: "point.3.connected.trianglepath.dotted"
	)

	public static let host: Self = .init(
		name: "host",
		title: String.localized(.appUI.links.placeholderHost),
		symbol: "globe"
	)

	public static let path: Self = .init(
		name: "path",
		title: String.localized(.appUI.links.placeholderPath),
		symbol: "folder"
	)

	public static let query: Self = .init(
		name: "query",
		title: String.localized(.appUI.links.placeholderQuery),
		symbol: "magnifyingglass"
	)

	public static let fragment: Self = .init(
		name: "fragment",
		title: String.localized(.appUI.links.placeholderFragment),
		symbol: "number"
	)
}
