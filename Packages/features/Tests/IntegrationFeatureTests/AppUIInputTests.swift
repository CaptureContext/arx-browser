import AppKit

@testable import AppUI
import CustomDump
import SwiftUI
import Testing

@Suite(.dependencies)
@MainActor
internal struct AppUIInputTests {
	@Test
	func inputMethodKeepsCompositionCommands() async throws {
		var commands: [String] = []
		let input = CommandInput(
			text: .constant(""),
			focusRequest: 0,
			onFocusChanged: { _ in },
			onMove: { commands.append("move\($0)") },
			onSubmit: { commands.append("submit") },
			onDismiss: { commands.append("dismiss") }
		)
		let coordinator = input.makeCoordinator()
		let editor = NSTextView()
		editor.setMarkedText(
			"に",
			selectedRange: NSRange(location: 1, length: 0),
			replacementRange: NSRange(location: NSNotFound, length: 0)
		)
		#expect(editor.hasMarkedText())
		for command in [
			#selector(NSResponder.moveDown(_:)),
			#selector(NSResponder.insertNewline(_:)),
			#selector(NSResponder.cancelOperation(_:))
		] {
			#expect(!coordinator.control(NSControl(), textView: editor, doCommandBy: command))
		}
		expectNoDifference(commands, [])
		editor.unmarkText()
		#expect(coordinator.control(
			NSControl(),
			textView: editor,
			doCommandBy: #selector(NSResponder.moveDown(_:))
		))
		#expect(coordinator.control(
			NSControl(),
			textView: editor,
			doCommandBy: #selector(NSResponder.insertNewline(_:))
		))
		expectNoDifference(commands, ["move1", "submit"])
	}

	@Test
	func compositionKeepsTabAndCaretKeys() async throws {
		var commands: [String] = []
		let input = CommandInput(
			text: .constant("git"),
			focusRequest: 0,
			onFocusChanged: { _ in },
			onTab: {
				commands.append("tab")
				return true
			},
			onMove: { commands.append("move\($0)") },
			onSubmit: { commands.append("submit") },
			onDismiss: { commands.append("dismiss") }
		)
		let coordinator = input.makeCoordinator()
		let editor = NSTextView()
		editor.string = "git"
		editor.setMarkedText(
			"ぎ",
			selectedRange: NSRange(location: 1, length: 0),
			replacementRange: NSRange(location: 3, length: 0)
		)
		for command in [
			#selector(NSResponder.insertTab(_:)),
			#selector(NSResponder.moveRight(_:)),
			#selector(NSResponder.deleteBackward(_:)),
			#selector(NSResponder.cancelOperation(_:)),
		] {
			#expect(!coordinator.control(NSControl(), textView: editor, doCommandBy: command))
		}
		expectNoDifference(commands, [])
	}

	/// DEV-1223: there's no inline completion, so caret moves and deletions are the field's own,
	/// and Tab still goes to the bar.
	@Test
	func caretMovesAndDeletionsAreTheFieldsOwn() async throws {
		var text = "git"
		var commands: [String] = []
		let input = CommandInput(
			text: Binding(get: { text }, set: { text = $0 }),
			focusRequest: 0,
			onFocusChanged: { _ in },
			onTab: {
				commands.append("tab")
				return true
			},
			onMove: { commands.append("move\($0)") },
			onSubmit: { commands.append("submit") },
			onDismiss: { commands.append("dismiss") }
		)
		let coordinator = input.makeCoordinator()
		let editor = NSTextView()
		editor.string = "git"
		editor.setSelectedRange(NSRange(location: 3, length: 0))

		for command in [
			#selector(NSResponder.moveRight(_:)),
			#selector(NSResponder.moveLeft(_:)),
			#selector(NSResponder.moveToEndOfLine(_:)),
			#selector(NSResponder.deleteBackward(_:)),
			#selector(NSResponder.deleteForward(_:)),
		] {
			#expect(!coordinator.control(NSControl(), textView: editor, doCommandBy: command))
		}
		#expect(coordinator.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
		expectNoDifference(text, "git")
		expectNoDifference(editor.string, "git")
		expectNoDifference(commands, ["tab"])
	}

	/// DEV-1223: the field shows exactly what was typed, however long, with nothing after it.
	@Test
	func theFieldShowsOnlyWhatWasTyped() async throws {
		let typed = "capturecontext.dev/docs/arx/settings/general/tabs/where-new-tabs-open/and-more"
		let bar = CommandBar(
			query: .constant(typed),
			selectedID: .constant("long"),
			results: [
				.init(
					id: "long",
					title: "Long",
					subtitle: "https://\(typed)/and/a/much/longer/page/address",
					actionTitle: "Open",
					symbol: "globe"
				),
			],
			onSelect: { _ in },
			onDismiss: {}
		)
		let host = NSHostingView(rootView: bar.frame(width: 300, height: 400))
		host.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
		host.layoutSubtreeIfNeeded()

		let field = try #require(Self.field(in: host))
		expectNoDifference(field.stringValue, typed)
	}

	private static func field(in view: NSView) -> CommandInput.Field? {
		if let field = view as? CommandInput.Field { return field }
		for subview in view.subviews {
			if let field = field(in: subview) { return field }
		}
		return nil
	}

	/// DEV-750: ⌫ in an already-empty field reports itself instead of deleting; other
	/// deletions, text and composition keep their usual behaviour.
	@Test
	func deleteInAnEmptyFieldIsReportedOnce() async throws {
		var commands: [String] = []
		let input = CommandInput(
			text: .constant(""),
			focusRequest: 0,
			onFocusChanged: { _ in },
			onDeleteWhenEmpty: { commands.append("empty delete") },
			onMove: { _ in },
			onSubmit: {},
			onDismiss: {}
		)
		let coordinator = input.makeCoordinator()
		let editor = NSTextView()

		#expect(coordinator.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
		#expect(coordinator.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.deleteWordBackward(_:))))
		expectNoDifference(commands, ["empty delete", "empty delete"])

		// Forward Delete has nothing to do with closing.
		commands = []
		_ = coordinator.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.deleteForward(_:)))
		#expect(!commands.contains("empty delete"))

		// The ⌫ that empties the field is the field's own deletion.
		commands = []
		editor.string = "a"
		editor.setSelectedRange(NSRange(location: 1, length: 0))
		#expect(!coordinator.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
		#expect(!commands.contains("empty delete"))

		// Composition keeps ⌫.
		commands = []
		editor.setMarkedText(
			"に",
			selectedRange: NSRange(location: 1, length: 0),
			replacementRange: NSRange(location: NSNotFound, length: 0)
		)
		#expect(!coordinator.control(NSControl(), textView: editor, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
		expectNoDifference(commands, [])
	}
}
