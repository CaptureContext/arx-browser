import AppKit
@testable import AppUI
import SwiftUI
import Testing

/// The "Ask an agent ⇥" hint takes its own room beside the command bar's field, so a long
/// address scrolls inside the field and never runs under the hint (DEV-954).
@MainActor
@Suite(
	.serialized,
	.renderTurn
)
internal struct CommandBarHintLayoutTests {
	/// ⌘T and ⌘K use the palette, ⌘L the address field, each from a narrow width to its widest.
	internal struct Layout: Sendable, CustomTestStringConvertible {
		internal var style: CommandBarStyle
		internal var width: CGFloat

		internal var testDescription: String {
			"\(style == .palette ? "palette" : "address field") at \(Int(width)) points"
		}

		internal static let all: [Self] = [
			.init(style: .palette, width: 300),
			.init(style: .palette, width: BrowserMetrics.CommandBar.width),
			.init(style: .urlField, width: BrowserMetrics.CommandBar.URLField.minimumWidth),
			.init(style: .urlField, width: BrowserMetrics.CommandBar.URLField.maximumWidth),
		]

		/// Where the field's room ends without the hint: the input row's trailing padding, inside
		/// the palette's bezel (DEV-1277).
		internal var fieldEnd: CGFloat {
			width - style.contentInset - style.inputHorizontalPadding
		}

		/// The hint's leading edge.
		@MainActor
		internal var hintLeading: CGFloat {
			fieldEnd - CommandBarHintLayoutTests.hintWidth()
		}

		/// Where the field's room ends while the hint shows: the hint's leading edge, less the row's spacing.
		@MainActor
		internal var fieldEndBesideTheHint: CGFloat {
			hintLeading - BrowserMetrics.CommandBar.inputSpacing
		}
	}

	@Test(arguments: Layout.all)
	internal func theFieldEndsWhereTheHintBegins(layout: Layout) throws {
		let bar = try BarHost(layout, showsHint: true)
		defer { bar.close() }

		#expect(bar.width == layout.width)
		#expect(bar.fieldSlot.width > 0)
		#expect(abs(bar.fieldSlot.maxX - layout.fieldEndBesideTheHint) <= 0.5)
	}

	@Test(arguments: Layout.all)
	internal func theFieldTakesTheFullWidthWithoutTheHint(layout: Layout) throws {
		let bar = try BarHost(layout, showsHint: false)
		defer { bar.close() }

		#expect(bar.width == layout.width)
		#expect(abs(bar.fieldSlot.maxX - layout.fieldEnd) <= 0.5)
	}

	/// The hint comes in once something is typed, so the field narrows while it's being edited,
	/// as when typing at the end of a long address in ⌘L. The end of the text and the caret stay
	/// in view, left of the hint.
	@Test(arguments: Layout.all)
	internal func theHintNarrowsTheFieldBeingEdited(layout: Layout) throws {
		let bar = try BarHost(layout, showsHint: false)
		defer { bar.close() }

		try bar.beginEditing()
		try bar.moveToTheEnd()
		bar.showsHint = true
		let editing = try bar.editing()

		#expect(abs(bar.fieldSlot.maxX - layout.fieldEndBesideTheHint) <= 0.5)
		#expect(editing.visibleText.maxX <= layout.hintLeading)
		#expect(editing.showsTheEnd)
	}

	/// When the hint goes away mid-edit, the field and its text take the full width again.
	@Test(arguments: Layout.all)
	internal func theFieldWidensAgainWhenTheHintHides(layout: Layout) throws {
		let bar = try BarHost(layout, showsHint: true)
		defer { bar.close() }

		try bar.beginEditing()
		try bar.moveToTheEnd()
		bar.showsHint = false
		let editing = try bar.editing()

		#expect(abs(bar.fieldSlot.maxX - layout.fieldEnd) <= 0.5)
		#expect(editing.visibleText.maxX > layout.hintLeading)
		#expect(editing.visibleText.maxX <= layout.width)
		#expect(editing.showsTheEnd)
	}

	/// ⌘L's panel makes room for the hint from its worked-out width, so it has to match the view's.
	@Test(arguments: ["⇥", "⌘K", nil] as [String?])
	internal func theHintsWorkedOutWidthMatchesItsLayout(key: String?) {
		let title = CommandBarKeyHintButton.agentTitle
		let laidOut = NSHostingView(rootView: CommandBarKeyHintButton(title, key: key, keyName: "") {}).fittingSize.width
		#expect(abs(CommandBarKeyHintButton.width(title: title, key: key) - laidOut) <= 1)
	}

	fileprivate static let longURL: String = "github.com/CaptureContext/homebrew-tap/blob/main/Formula/arx.rb?tab=readme-ov-file"

	fileprivate static func hintWidth() -> CGFloat {
		NSHostingView(
			rootView: CommandBarKeyHintButton(
				CommandBarKeyHintButton.agentTitle,
				key: CommandBarKeyHintButton.agentKey,
				keyName: String.localized(.appUI.command.tabKey)
			) {}
		)
		.fittingSize
		.width
	}
}

/// A command bar holding a long address in an offscreen window, measured in its own coordinates.
@MainActor
private final class BarHost {
	private struct Root: View {
		internal var layout: CommandBarHintLayoutTests.Layout
		internal var showsHint: Bool

		internal var body: some View {
			CommandBar(
				query: .constant(CommandBarHintLayoutTests.longURL),
				selectedID: .constant(nil),
				results: [],
				style: layout.style,
				inputSymbol: "globe",
				onAskAgent: showsHint ? {} : nil,
				onSelect: { _ in },
				onDismiss: {}
			)
			.frame(width: layout.width)
		}
	}

	private let window: NSWindow
	private let host: NSHostingView<Root>
	private let field: CommandInput.Field

	internal init(
		_ layout: CommandBarHintLayoutTests.Layout,
		showsHint: Bool
	) throws {
		let host = NSHostingView(rootView: Root(layout: layout, showsHint: showsHint))
		host.frame = .init(origin: .zero, size: host.fittingSize)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: host.frame.size),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = host
		self.window = window
		self.host = host
		Self.settle(host)
		self.field = try #require(Self.field(in: host))
	}

	internal var showsHint: Bool {
		get { host.rootView.showsHint }
		set {
			host.rootView.showsHint = newValue
			Self.settle(host)
		}
	}

	internal var width: CGFloat { host.fittingSize.width }

	/// The room the bar gives the field: its frame without its alignment insets.
	internal var fieldSlot: CGRect {
		let frame = field.convert(field.bounds, to: host)
		let insets = field.alignmentRectInsets
		return .init(
			x: frame.minX + insets.left,
			y: frame.minY,
			width: frame.width - insets.left - insets.right,
			height: frame.height
		)
	}

	internal func beginEditing() throws {
		#expect(window.makeFirstResponder(field))
		_ = try #require(field.currentEditor())
	}

	/// Puts the caret after the last character and scrolls it into view, as typing there does.
	internal func moveToTheEnd() throws {
		let editor = try #require(field.currentEditor() as? NSTextView)
		let end = NSRange(location: (editor.string as NSString).length, length: 0)
		editor.setSelectedRange(end)
		if let layout = editor.textLayoutManager {
			layout.ensureLayout(for: layout.documentRange)
		}
		editor.sizeToFit()
		editor.scrollRangeToVisible(end)
		Self.settle(host)
	}

	/// Where the editor shows text, and whether the end of the text, where the caret is, is in view.
	internal func editing() throws -> (visibleText: CGRect, showsTheEnd: Bool) {
		let editor = try #require(field.currentEditor() as? NSTextView)
		let clip = try #require(editor.superview)
		let font = try #require(editor.font)
		let textEnd = (editor.string as NSString).size(withAttributes: [.font: font]).width
			+ editor.textContainerOrigin.x
			+ (editor.textContainer?.lineFragmentPadding ?? 0)
		let visible = editor.visibleRect
		return (clip.convert(clip.bounds, to: host), visible.minX < textEnd && textEnd <= visible.maxX + 1)
	}

	internal func close() {
		window.close()
	}

	private static func settle(_ host: NSView) {
		for _ in 0..<4 {
			host.layoutSubtreeIfNeeded()
			host.displayIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
	}

	private static func field(in view: NSView) -> CommandInput.Field? {
		if let field = view as? CommandInput.Field { return field }
		return view.subviews.lazy.compactMap { field(in: $0) }.first
	}
}
