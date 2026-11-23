#if DEBUG
import AppKit
import BrowserCore
import Foundation
import _ComposableArchitecture

/// The inline completion ticket's hand check (DEV-1223), in the app's own window.
///
/// ⌘L opens the expanded URL bar, and an address far wider than the bar is typed into it a key
/// at a time. The field must hold exactly what was typed, with no completion after it, and its
/// caret must stay in view at the end, at the start after ⌘← and at the end again after ⌘→.
/// Return then opens the typed address.
@MainActor
internal enum AddressFieldSmoke {
	internal static func run(
		store: StoreOf<AppFeature>,
		window: NSWindow,
		baseURL: URL
	) async throws {
		// A first visit to the same long address, so the address the text leads toward is in
		// history, as inline completion once completed it.
		let address = longAddress(baseURL: baseURL)
		window.makeKeyAndOrderFront(nil)
		store.send(.ui(.openURLInSpace(address, store.main.sidebar.spaceID, .mainBrowser)))
		try await HandCheckSmoke.wait("first visit") {
			store.main.viewer.item.navigation.url == address && !store.main.viewer.item.navigation.isLoading
		}
		store.send(.ui(.openURLInSpace(baseURL, store.main.sidebar.spaceID, .mainBrowser)))
		try await HandCheckSmoke.wait("back on the start page") {
			store.main.viewer.item.navigation.url == baseURL && !store.main.viewer.item.navigation.isLoading
		}

		try HandCheckSmoke.press(.address, store: store, window: window)
		try await HandCheckSmoke.wait("URL bar focused", context: { HandCheckSmoke.responder(in: window) }) {
			field(in: window) != nil
		}

		// The bar selects the page's address once it has opened; a key before then is replaced.
		try await Task.sleep(for: .milliseconds(500))

		// ⌘A replaces the current page's address, as typing over it does.
		try HandCheckSmoke.key("a", code: 0, modifiers: .command, in: window)
		try await HandCheckSmoke.wait("the address selected", context: {
			field(in: window).map { "\($0.editor.string)@\(NSStringFromRange($0.editor.selectedRange()))" } ?? "no field"
		}) {
			guard let editor = field(in: window)?.editor else { return false }
			return editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length)
		}
		let typed = address.absoluteString

		// First a proper prefix, which the visited address would once have completed: the field
		// must hold just the prefix, and nothing in the window may show the rest of the address.
		let prefix = completionPrefix(of: typed)
		try await HandCheckSmoke.typeText(prefix, in: window)
		try await HandCheckSmoke.wait("prefix typed", context: { field(in: window).map { "field=\($0.editor.string)" } ?? "no field" }) {
			field(in: window)?.editor.string == prefix
		}

		// Give suggestions and a completion time to arrive.
		try await Task.sleep(for: .milliseconds(1_200))
		guard let (_, prefixEditor) = field(in: window) else { throw HandCheckSmoke.Failure("the URL bar lost focus") }
		guard
			prefixEditor.string == prefix,
			prefixEditor.selectedRange() == NSRange(location: (prefix as NSString).length, length: 0)
		else {
			throw HandCheckSmoke.Failure(
				"after the prefix the field shows \(prefixEditor.string) selecting \(NSStringFromRange(prefixEditor.selectedRange()))"
			)
		}
		let remainder = String(typed.dropFirst(prefix.count))
		let shown = HandCheckSmoke.accessibilityTexts(in: window)
		if let suffix = shown.first(where: { showsCompletion($0, remainder: remainder) }) {
			throw HandCheckSmoke.Failure("the window shows a completion after the prefix: \(suffix)")
		}
		print("ARX_HAND_CHECK_ADDRESS_PREFIX characters=\(prefix.count) texts=\(shown.count) suffix=none")
		try await HandCheckSmoke.typeText(remainder, in: window)
		try await HandCheckSmoke.wait("typed", context: { field(in: window).map { "field=\($0.field.stringValue)" } ?? "no field" }) {
			field(in: window)?.editor.string == typed
		}

		// Give a completion time to arrive, as it once did after the suggestions.
		try await Task.sleep(for: .milliseconds(800))
		guard let (input, editor) = field(in: window) else { throw HandCheckSmoke.Failure("the URL bar lost focus") }
		guard input.stringValue == typed, editor.string == typed
		else { throw HandCheckSmoke.Failure("the field shows \(editor.string.count) characters, typed \(typed.count): \(editor.string)") }

		let length = (typed as NSString).length
		guard textWidth(editor) > input.bounds.width
		else { throw HandCheckSmoke.Failure("the address fits the bar (\(textWidth(editor)) ≤ \(input.bounds.width)); nothing to scroll") }

		try expectCaret(at: length, editor: editor, field: input, step: "end")

		// ⌘← and ⌘→, as the field editor's key bindings run them: ⌘← is also Back in the menu.
		editor.doCommand(by: #selector(NSResponder.moveToBeginningOfLine(_:)))
		try await HandCheckSmoke.wait("caret at the start", context: { NSStringFromRange(editor.selectedRange()) }) {
			editor.selectedRange() == NSRange(location: 0, length: 0)
		}
		try expectCaret(at: 0, editor: editor, field: input, step: "start")
		editor.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
		try await HandCheckSmoke.wait("caret at the end", context: { NSStringFromRange(editor.selectedRange()) }) {
			editor.selectedRange() == NSRange(location: length, length: 0)
		}
		try expectCaret(at: length, editor: editor, field: input, step: "end again")
		guard editor.string == typed else { throw HandCheckSmoke.Failure("moving the caret changed the text") }

		try HandCheckSmoke.key("\r", code: 36, in: window)
		try await HandCheckSmoke.wait("Return opened the typed address", context: {
			"url=\(store.main.viewer.item.navigation.url?.absoluteString ?? "nil")"
		}) {
			store.main.viewer.item.navigation.url == address
		}
		print("ARX_HAND_CHECK_ADDRESS_LENGTH characters=\(length) field=\(Int(input.bounds.width))")
		print(HandCheckSmoke.Phase.address.successMarker)
	}

	/// A loopback address about four times as wide as the expanded URL bar.
	internal static func longAddress(baseURL: URL) -> URL {
		let segment = (1...12).map { "long-address-segment-\($0)" }.joined(separator: "/")
		return baseURL.deletingLastPathComponent().appending(path: "address/\(segment).html")
	}

	/// The typed address up to its sixth segment: a proper prefix of the visited address.
	internal static func completionPrefix(of address: String) -> String {
		guard let range = address.range(of: "long-address-segment-6/") else { return String(address.prefix(address.count / 2)) }
		return String(address[..<range.upperBound])
	}

	/// Whether `text`, a string the window shows, holds the address's untyped rest: a completion
	/// drawn after the prefix, in the field or beside it. The suggestion list's rows show whole
	/// addresses, so a row holding the prefix too is a suggestion, not a completion.
	internal static func showsCompletion(
		_ text: String,
		remainder: String
	) -> Bool {
		let tail = String(remainder.prefix(24))
		guard !tail.isEmpty, text.contains(tail) else { return false }
		return !text.contains("long-address-segment-1/")
	}

	/// Whether the caret's rect sits inside the part of the field that shows text.
	internal static let caretSlack: CGFloat = 4

	internal static func caretIsVisible(
		caret: NSRect,
		visible: NSRect
	) -> Bool {
		// AppKit draws the caret at the text's end a couple of points into the field's inset, past
		// its frame; a caret left unscrolled is hundreds of points out.
		caret.minX >= visible.minX - caretSlack && caret.minX <= visible.maxX + caretSlack
	}

	private static func expectCaret(
		at location: Int,
		editor: NSTextView,
		field: NSTextField,
		step: String
	) throws {
		guard editor.selectedRange() == NSRange(location: location, length: 0)
		else { throw HandCheckSmoke.Failure("\(step): the caret is at \(NSStringFromRange(editor.selectedRange())), expected \(location)") }

		var actual = NSRange()
		let caret = editor.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: &actual)
		guard let window = field.window else { throw HandCheckSmoke.Failure("\(step): the field left its window") }
		let visible = window.convertToScreen(field.convert(field.bounds, to: nil))
		guard caretIsVisible(caret: caret, visible: visible)
		else { throw HandCheckSmoke.Failure("\(step): the caret at \(NSStringFromRect(caret)) is outside the field \(NSStringFromRect(visible))") }
		print("ARX_HAND_CHECK_ADDRESS_CARET \(step) x=\(Int(caret.minX - visible.minX))/\(Int(visible.width))")
	}

	private static func textWidth(_ editor: NSTextView) -> CGFloat {
		editor.attributedString().size().width
	}

	/// The URL bar's field and its field editor, while it's being edited.
	private static func field(in window: NSWindow) -> (field: NSTextField, editor: NSTextView)? {
		guard
			let edited = HandCheckSmoke.editedField(in: window),
			edited.field.accessibilityIdentifier() == "command-bar-input"
		else { return nil }
		return edited
	}
}
#endif
