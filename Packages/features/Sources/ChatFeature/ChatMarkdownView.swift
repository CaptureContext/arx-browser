import AppKit
import AppUI
import BrowserCore
import Foundation
import SwiftUI

/// Renders an answer's Markdown (`ChatMarkdown`): headings, paragraphs with emphasis, code,
/// strikethrough and links, nested and task lists, quotes, code blocks with a copy button,
/// tables and rules. A table wider than the panel scrolls sideways, its long cells wrapped, so
/// its columns stay aligned. Images show their description and are never loaded, since answers
/// can repeat untrusted page content.
internal struct ChatMarkdownView: View {
	internal let markdown: String

	/// The body text's size. Headings and code follow it.
	internal let size: CGFloat

	/// The body text's design. Code stays monospaced.
	internal let design: Font.Design

	/// An answer still being written: its unfinished tail is drawn as it will settle.
	internal let isStreaming: Bool

	internal init(
		markdown: String,
		size: CGFloat = 13,
		design: Font.Design = .default,
		isStreaming: Bool = false
	) {
		self.markdown = markdown
		self.size = size
		self.design = design
		self.isStreaming = isStreaming
	}

	/// Reads long answers off the main actor and keeps the blocks last read.
	@SwiftUI.State
	private var reader: ChatMarkdownReader = .init()

	/// Markdown up to this long is read on the spot when its blocks aren't kept yet. Longer
	/// Markdown is read off the main actor: it shows its last blocks, or its text before the
	/// first read, until a read catches up.
	internal static let synchronousLength: Int = 4_000

	internal var body: some View {
		ChatMarkdownBlocks(
			blocks: blocks,
			style: .init(size: size, design: design)
		)
		.font(.system(size: size, design: design))
		.lineSpacing(design == .serif ? size * 0.2 : 0)
		.textSelection(.enabled)
		.frame(maxWidth: .infinity, alignment: .leading)
		.onChange(of: source, initial: true) {
			reader.read(source)
		}
	}

	private var source: ChatMarkdownReader.Source {
		.init(markdown: markdown, isStreaming: isStreaming)
	}

	private var blocks: [ChatMarkdown.Block] {
		if let latest = reader.latest, latest.source == source {
			return latest.blocks
		}
		if markdown.count <= Self.synchronousLength {
			return ChatMarkdown.blocks(markdown, isStreaming: isStreaming)
		}
		return reader.latest?.blocks ?? [.paragraph(AttributedString(markdown))]
	}
}

/// Reads an answer's Markdown off the main actor, one read at a time. A read in progress always
/// finishes and shows; text that arrives meanwhile waits, and only the newest is read next, so a
/// streaming answer keeps showing as fast as it can be read.
@MainActor
@Observable
internal final class ChatMarkdownReader {
	internal struct Source: Equatable, Sendable {
		internal var markdown: String
		internal var isStreaming: Bool
	}

	internal struct Read {
		internal var source: Source
		internal var blocks: [ChatMarkdown.Block]
	}

	/// The blocks last read, and what they were read from.
	internal private(set) var latest: Read?

	/// The reads in progress, for tests to wait on.
	@ObservationIgnored
	internal private(set) var reading: Task<Void, Never>?

	@ObservationIgnored
	private var pending: Source?

	internal init() {
		self.latest = nil
		self.reading = nil
		self.pending = nil
	}

	internal func read(_ source: Source) {
		guard latest?.source != source else {
			pending = nil
			return
		}

		pending = source
		guard reading == nil
		else { return }

		reading = Task { [weak self] in
			await self?.readPending()
		}
	}

	private func readPending() async {
		while let source = pending {
			pending = nil
			let blocks: [ChatMarkdown.Block] = await ChatMarkdown.blocksOffMain(source.markdown, isStreaming: source.isStreaming)
			latest = .init(source: source, blocks: blocks)
		}
		reading = nil
	}
}

/// The sizes an answer's blocks follow from its body text.
internal struct ChatMarkdownStyle: Equatable {
	internal var size: CGFloat
	internal var design: Font.Design

	/// How many lists this block sits in, for the bullet it draws.
	internal var listDepth: Int = 0

	internal var blockSpacing: CGFloat { size * 0.6 }
	internal var codeSize: CGFloat { (size * 0.92).rounded() }

	/// A table cell wider than this wraps.
	internal var cellWidth: CGFloat { size * 18 }

	internal func headingSize(_ level: Int) -> CGFloat {
		switch level {
		case 1: size + 4
		case 2: size + 2
		case 3: size + 1
		default: size
		}
	}

	/// Rules and a table's lines: the chrome's section divider.
	internal static var line: Color { BrowserTheme.divider.opacity(BrowserMetrics.Section.dividerOpacity) }

	/// A quote's bar, a little stronger than a line.
	internal static var quoteBar: Color { BrowserTheme.divider.opacity(BrowserMetrics.Section.dividerOpacity * 2) }

	internal var nested: Self {
		var style: Self = self
		style.listDepth += 1
		return style
	}

	/// Inline text as drawn: code in the monospaced face on a subtle fill.
	internal func inline(_ text: AttributedString) -> AttributedString {
		var text: AttributedString = text
		for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
			text[run.range].font = .system(size: codeSize, design: .monospaced)
			text[run.range].backgroundColor = BrowserTheme.fill
		}
		return text
	}
}

private struct ChatMarkdownBlocks: View {
	internal let blocks: [ChatMarkdown.Block]
	internal let style: ChatMarkdownStyle

	internal var body: some View {
		VStack(alignment: .leading, spacing: style.blockSpacing) {
			ForEach(blocks.indices, id: \.self) { index in
				ChatMarkdownBlock(block: blocks[index], style: style)
			}
		}
	}
}

private struct ChatMarkdownBlock: View {
	internal let block: ChatMarkdown.Block
	internal let style: ChatMarkdownStyle

	internal var body: some View {
		switch block {
		case let .paragraph(text):
			Text(style.inline(text))
				.fixedSize(horizontal: false, vertical: true)

		case let .heading(level, text):
			Text(style.inline(text))
				.font(.system(size: style.headingSize(level), weight: .semibold, design: style.design))
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, level <= 2 ? style.size * 0.2 : 0)
				.accessibilityAddTraits(.isHeader)

		case let .list(list):
			ChatMarkdownList(list: list, style: style)

		case let .quote(blocks):
			ChatMarkdownBlocks(blocks: blocks, style: style)
				.foregroundStyle(BrowserTheme.secondary)
				.padding(.leading, 10)
				.overlay(alignment: .leading) {
					Capsule().fill(ChatMarkdownStyle.quoteBar).frame(width: 2)
				}

		case let .code(language, text):
			ChatMarkdownCode(language: language, text: text, style: style)

		case let .table(table):
			ChatMarkdownTable(table: table, style: style)

		case .rule:
			Rectangle()
				.fill(ChatMarkdownStyle.line)
				.frame(height: 1)
				.padding(.vertical, style.size * 0.2)
		}
	}
}

// MARK: - Lists

private struct ChatMarkdownList: View {
	internal let list: ChatMarkdown.List
	internal let style: ChatMarkdownStyle

	internal var body: some View {
		VStack(alignment: .leading, spacing: style.size * 0.35) {
			ForEach(list.items.indices, id: \.self) { index in
				let item: ChatMarkdown.List.Item = list.items[index]
				HStack(alignment: .firstTextBaseline, spacing: 6) {
					// The widest marker keeps every item's text on one edge.
					ZStack(alignment: .trailing) {
						marker(widestOrdinal).hidden()
						marker(item)
					}
					ChatMarkdownBlocks(blocks: item.blocks, style: style.nested)
				}
			}
		}
	}

	private var widestOrdinal: ChatMarkdown.List.Item {
		.init(ordinal: list.items.map(\.ordinal).max() ?? 1, isChecked: nil, blocks: [])
	}

	private func marker(_ item: ChatMarkdown.List.Item) -> Text {
		if let isChecked = item.isChecked {
			return Text(Image(systemName: isChecked ? "checkmark.square.fill" : "square"))
				.foregroundStyle(isChecked ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(BrowserTheme.secondary))
		}
		if list.isOrdered {
			return Text("\(item.ordinal).")
				.foregroundStyle(BrowserTheme.secondary)
				.monospacedDigit()
		}
		let bullets: [String] = ["•", "◦", "▪︎"]
		return Text(bullets[style.listDepth % bullets.count])
			.foregroundStyle(BrowserTheme.secondary)
	}
}

// MARK: - Code

private struct ChatMarkdownCode: View {
	internal let language: String?
	internal let text: String
	internal let style: ChatMarkdownStyle

	@SwiftUI.State
	private var isCopied: Bool = false

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 6) {
				Text(language ?? "")
					.font(.system(size: style.size - 2.5, weight: .medium))
					.foregroundStyle(BrowserTheme.secondary)
				Spacer(minLength: 0)
				Button {
					ChatPasteboard.copy(text)
					isCopied = true
				} label: {
					Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
						.font(.system(size: style.size - 2.5, weight: .medium))
						.frame(width: 14, height: 14)
				}
				.buttonStyle(.arx(.plain, size: .small))
				.help(String.localized(.appUI.chat.copyCode))
				.accessibilityLabel(String.localized(isCopied ? .appUI.chat.codeCopied : .appUI.chat.copyCode))
			}
			.padding(.leading, 10)
			.padding(.trailing, 4)
			.padding(.top, 4)

			ScrollView(.horizontal) {
				Text(text)
					.font(.system(size: style.codeSize, design: .monospaced))
					.fixedSize()
					.padding(.horizontal, 10)
					.padding(.top, 2)
					.padding(.bottom, 9)
			}
			.scrollIndicators(.automatic)
		}
		.background(BrowserTheme.fill, in: .rect(cornerRadius: 8, style: .continuous))
		.task(id: isCopied) {
			guard isCopied
			else { return }

			try? await Task.sleep(for: .seconds(1.5))
			isCopied = false
		}
	}
}

// MARK: - Tables

private struct ChatMarkdownTable: View {
	internal let table: ChatMarkdown.Table
	internal let style: ChatMarkdownStyle

	internal var body: some View {
		ScrollView(.horizontal) {
			Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
				GridRow {
					ForEach(table.alignments.indices, id: \.self) { column in
						cell(table.header[column], column: column)
							.fontWeight(.semibold)
							.background(BrowserTheme.fill)
					}
				}
				ForEach(table.rows.indices, id: \.self) { row in
					Rectangle()
						.fill(ChatMarkdownStyle.line)
						.frame(height: 1)
						.gridCellUnsizedAxes(.horizontal)
					GridRow {
						ForEach(table.alignments.indices, id: \.self) { column in
							cell(table.rows[row][column], column: column)
						}
					}
				}
			}

			// Measured and laid out at the same, natural width, so a wrapped cell's height holds.
			.fixedSize()
			.clipShape(.rect(cornerRadius: 6, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 6, style: .continuous)
					.strokeBorder(ChatMarkdownStyle.line)
			}
		}
		.scrollIndicators(.automatic)
	}

	private func cell(
		_ text: AttributedString,
		column: Int
	) -> some View {
		let alignment: ChatMarkdown.Table.Alignment = table.alignments[column]
		return ChatTableCellLayout(maxWidth: style.cellWidth) {
			Text(style.inline(text))
				.multilineTextAlignment(alignment.text)
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 5)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment.frame)
	}
}

/// A cell's text at its natural width, wrapped once it's wider than `maxWidth`: the table
/// scrolls sideways, so a cell would otherwise run as wide as its longest line.
private struct ChatTableCellLayout: Layout {
	internal let maxWidth: CGFloat

	internal func sizeThatFits(
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout ()
	) -> CGSize {
		guard let text = subviews.first
		else { return .zero }

		return text.sizeThatFits(.init(width: min(proposal.width ?? maxWidth, maxWidth), height: nil))
	}

	internal func placeSubviews(
		in bounds: CGRect,
		proposal: ProposedViewSize,
		subviews: Subviews,
		cache: inout ()
	) {
		subviews.first?.place(at: bounds.origin, proposal: .init(width: bounds.width, height: bounds.height))
	}
}

extension ChatMarkdown.Table.Alignment {
	fileprivate var frame: SwiftUI.Alignment {
		switch self {
		case .leading: .leading
		case .center: .center
		case .trailing: .trailing
		}
	}

	fileprivate var text: TextAlignment {
		switch self {
		case .leading: .leading
		case .center: .center
		case .trailing: .trailing
		}
	}
}

// MARK: - Copying

/// What chat copies goes to the general pasteboard as plain text.
internal enum ChatPasteboard {
	internal static func copy(_ text: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
	}
}
