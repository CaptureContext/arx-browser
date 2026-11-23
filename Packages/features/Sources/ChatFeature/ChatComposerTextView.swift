import AppKit
import AppUI
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// The composer's text (DEV-798): it grows with the message up to ``maxHeight``, then scrolls.
/// Return follows Settings › Assistant, Shift-Return always starts a new line and ⌘Return
/// always sends. Pasting an image or a file attaches it; file drags fall through to the panel.
internal struct ChatComposerTextView: NSViewRepresentable {
	internal var text: String
	internal var placeholder: String
	internal var font: NSFont
	internal var minHeight: CGFloat
	internal var maxHeight: CGFloat
	internal var returnKey: ChatReturnKeyBehavior
	internal var focusRequest: Int
	internal var onChange: (String) -> Void
	internal var onSend: () -> Void
	internal var onFiles: ([URL]) -> Void
	internal var onImage: (Data) -> Void

	internal init(
		text: String,
		placeholder: String,
		font: NSFont = .systemFont(ofSize: 13.5),
		minHeight: CGFloat = 34,
		maxHeight: CGFloat = 200,
		returnKey: ChatReturnKeyBehavior,
		focusRequest: Int,
		onChange: @escaping (String) -> Void,
		onSend: @escaping () -> Void,
		onFiles: @escaping ([URL]) -> Void,
		onImage: @escaping (Data) -> Void
	) {
		self.text = text
		self.placeholder = placeholder
		self.font = font
		self.minHeight = minHeight
		self.maxHeight = maxHeight
		self.returnKey = returnKey
		self.focusRequest = focusRequest
		self.onChange = onChange
		self.onSend = onSend
		self.onFiles = onFiles
		self.onImage = onImage
	}

	internal func makeCoordinator() -> Coordinator {
		.init(self)
	}

	internal func makeNSView(context: Context) -> NSScrollView {
		// TextKit 1, since the height is measured with the layout manager.
		let textView: ChatComposerNSTextView = .init(usingTextLayoutManager: false)
		textView.delegate = context.coordinator
		textView.coordinator = context.coordinator
		textView.isRichText = false
		textView.importsGraphics = false
		textView.allowsUndo = true
		textView.drawsBackground = false
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.textContainerInset = .zero
		textView.textContainer?.lineFragmentPadding = 0
		textView.textContainer?.widthTracksTextView = true
		textView.isHorizontallyResizable = false
		textView.isVerticallyResizable = true
		textView.autoresizingMask = [.width]
		textView.font = font
		textView.textColor = .labelColor
		textView.string = text
		textView.setAccessibilityLabel(placeholder)

		let scrollView: NSScrollView = .init()
		scrollView.drawsBackground = false
		scrollView.borderType = .noBorder
		scrollView.hasVerticalScroller = true
		scrollView.autohidesScrollers = true
		scrollView.hasHorizontalScroller = false
		scrollView.scrollerStyle = .overlay
		scrollView.documentView = textView
		return scrollView
	}

	internal func updateNSView(
		_ scrollView: NSScrollView,
		context: Context
	) {
		context.coordinator.parent = self
		guard let textView = scrollView.documentView as? ChatComposerNSTextView
		else { return }

		if textView.string != text, !textView.hasMarkedText() {
			textView.string = text
			textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
		}
		if textView.font != font {
			textView.font = font
		}
		textView.setAccessibilityLabel(placeholder)
		if context.coordinator.focusRequest != focusRequest {
			context.coordinator.focusRequest = focusRequest
			DispatchQueue.main.async {
				textView.window?.makeFirstResponder(textView)
			}
		}
	}

	internal func sizeThatFits(
		_ proposal: ProposedViewSize,
		nsView scrollView: NSScrollView,
		context: Context
	) -> CGSize? {
		guard
			let textView = scrollView.documentView as? NSTextView,
			let container = textView.textContainer,
			let layout = textView.layoutManager
		else { return nil }

		let width: CGFloat = proposal.width ?? 280
		container.containerSize = .init(width: width, height: .greatestFiniteMagnitude)
		layout.ensureLayout(for: container)
		let used: CGFloat = ceil(layout.usedRect(for: container).height)
		return .init(width: width, height: min(max(used, minHeight), maxHeight))
	}

	internal final class Coordinator: NSObject, NSTextViewDelegate {
		internal var parent: ChatComposerTextView
		internal var focusRequest: Int

		internal init(_ parent: ChatComposerTextView) {
			self.parent = parent

			// The composer takes focus when it appears, then on every request.
			self.focusRequest = .min
		}

		internal func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView
			else { return }

			parent.onChange(textView.string)
			textView.enclosingScrollView?.invalidateIntrinsicContentSize()
		}

		/// Return, or `false` to let the text view insert it.
		internal func handleReturn(
			_ modifiers: NSEvent.ModifierFlags,
			in textView: NSTextView
		) -> Bool {
			var keys: ChatReturnKeyModifiers = []
			if modifiers.contains(.shift) { keys.insert(.shift) }
			if modifiers.contains(.command) { keys.insert(.command) }
			if modifiers.contains(.option) { keys.insert(.option) }
			switch parent.returnKey.action(modifiers: keys, draft: textView.string) {
			case .send:
				parent.onSend()

			case .newLine:
				textView.insertNewlineIgnoringFieldEditor(nil)
			}
			return true
		}

		/// Pasted files and images join the message; anything with text pastes as text.
		internal func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
			let urls: [URL] = (pasteboard.readObjects(
				forClasses: [NSURL.self],
				options: [.urlReadingFileURLsOnly: true]
			) as? [URL]) ?? []
			if !urls.isEmpty {
				parent.onFiles(urls)
				return true
			}
			guard pasteboard.string(forType: .string) == nil
			else { return false }

			for type in [NSPasteboard.PasteboardType.png, .tiff, .init(UTType.jpeg.identifier)] {
				if let data = pasteboard.data(forType: type) {
					parent.onImage(data)
					return true
				}
			}
			return false
		}
	}
}

/// Sends Return and paste to the coordinator, and takes only text drags, so files dropped on
/// the composer reach the panel's drop target.
internal final class ChatComposerNSTextView: NSTextView {
	internal weak var coordinator: ChatComposerTextView.Coordinator?

	override internal func keyDown(with event: NSEvent) {
		let isReturn: Bool = event.keyCode == 36 || event.keyCode == 76
		if isReturn, !hasMarkedText(), let coordinator, coordinator.handleReturn(event.modifierFlags, in: self) {
			return
		}
		super.keyDown(with: event)
	}

	override internal func performKeyEquivalent(with event: NSEvent) -> Bool {
		// ⌘Return reaches key equivalents before keyDown.
		let isReturn: Bool = event.keyCode == 36 || event.keyCode == 76
		if isReturn, event.modifierFlags.contains(.command), window?.firstResponder === self, let coordinator {
			return coordinator.handleReturn(event.modifierFlags, in: self)
		}
		return super.performKeyEquivalent(with: event)
	}

	override internal func paste(_ sender: Any?) {
		if let coordinator, coordinator.handlePaste(.general) {
			return
		}
		super.paste(sender)
	}

	/// Images and files keep Paste enabled; ``paste(_:)`` attaches them instead of inserting them.
	override internal var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
		super.readablePasteboardTypes + [.fileURL, .png, .tiff]
	}

	override internal var acceptableDragTypes: [NSPasteboard.PasteboardType] {
		[.string]
	}
}

/// The composer's text with its placeholder.
internal struct ChatComposerInput: View {
	@Bindable
	internal var store: StoreOf<ChatFeature>

	internal let placeholder: String

	internal init(
		store: StoreOf<ChatFeature>,
		placeholder: String
	) {
		self.store = store
		self.placeholder = placeholder
	}

	internal var body: some View {
		ChatComposerTextView(
			text: store.draft,
			placeholder: placeholder,
			returnKey: store.returnKey,
			focusRequest: store.focusRequest,
			onChange: { store.send(.ui(.draftChanged($0))) },
			onSend: { store.send(.ui(.sendTapped)) },
			onFiles: { store.send(.ui(.filesAdded($0))) },
			onImage: { store.send(.ui(.imageAdded($0, name: ChatAttachmentNames.pasted(), pageURL: nil))) }
		)
		.overlay(alignment: .topLeading) {
			if store.draft.isEmpty {
				Text(placeholder)
					.font(.system(size: 13.5))
					.foregroundStyle(.tertiary)
					.allowsHitTesting(false)
					.accessibilityHidden(true)
			}
		}
	}
}

/// Names for images that come without a file.
public enum ChatAttachmentNames {
	public static func pasted() -> String {
		String.localized(.appUI.chat.attachPastedImage) + ".png"
	}

	public static func capture(title: String) -> String {
		let title: String = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return (title.isEmpty ? String.localized(.appUI.chat.attachCapture) : title) + ".png"
	}
}

// MARK: - Dropping files

extension View {
	/// Files and images dropped anywhere on the chat join the composer's message (DEV-798).
	internal func chatFileDrop(
		isTargeted: Binding<Bool>,
		store: StoreOf<ChatFeature>
	) -> some View {
		onDrop(of: [.fileURL, .image], isTargeted: isTargeted) { providers in
			ChatDrop.load(providers, store: store)
		}
	}
}

internal enum ChatDrop {
	@MainActor
	internal static func load(
		_ providers: [NSItemProvider],
		store: StoreOf<ChatFeature>
	) -> Bool {
		var handled: Bool = false
		for provider in providers {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				handled = true
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					guard let url, url.isFileURL
					else { return }

					Task { @MainActor in store.send(.ui(.filesAdded([url]))) }
				}
			} else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
				handled = true
				let name: String = provider.suggestedName.map { $0 + ".png" } ?? ChatAttachmentNames.pasted()
				provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
					guard let data
					else { return }

					Task { @MainActor in store.send(.ui(.imageAdded(data, name: name, pageURL: nil))) }
				}
			}
		}
		return handled
	}
}
