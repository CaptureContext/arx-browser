import BrowserCore
import Foundation

/// Readable text or Markdown built from a semantic snapshot. It uses only the
/// roles, explicit names and text the snapshot already exposes, so it covers
/// exactly what `browser_inspect` would return and nothing more.
internal enum AutomationReadableText {
	internal enum Format: String, Codable, CaseIterable, Sendable {
		case markdown
		case text
	}

	internal enum Scope: String, Codable, CaseIterable, Sendable {
		/// The `main` landmark when the page has one, otherwise the page without
		/// navigation, banner, footer and complementary landmarks.
		case main
		case all
	}

	private static let inlineRoles: Set<String> = [
		"staticText", "inlineTextBox", "link", "emphasis", "strong", "mark", "code", "subscript",
		"superscript", "abbr", "time", "lineBreak", "image", "contentDeletion", "contentInsertion",
	]

	private static let chromeRoles: Set<String> = [
		"navigation", "banner", "contentInfo", "complementary",
	]

	/// Containers whose content never runs into a neighbor's text.
	private static let sectionRoles: Set<String> = chromeRoles.union([
		"main", "region", "article", "section", "form", "search", "dialog", "table", "row", "figure",
	])

	internal static func render(
		_ nodes: [PageInspectionNode],
		format: Format,
		scope: Scope
	) -> String {
		var children: [Int: [Int]] = [:]
		var roots: [Int] = []
		for node in nodes {
			if let parent = node.parent {
				children[parent, default: []].append(node.index)
			} else {
				roots.append(node.index)
			}
		}

		let mainIndex = scope == .main ? nodes.first(where: { $0.role == "main" })?.index : nil
		var renderer = Renderer(
			nodes: nodes,
			children: children,
			format: format,
			skipsChrome: scope == .main && mainIndex == nil
		)
		for root in mainIndex.map({ [$0] }) ?? roots {
			renderer.block(root, listDepth: 0)
		}
		renderer.flush()
		return renderer.lines.joined(separator: "\n")
	}

	/// Splits `text` at a line boundary at or before `maximumBytes`, starting at
	/// the UTF-8 offset `offset`. Returns the chunk and the offset after it.
	internal static func chunk(
		_ text: String,
		offset: Int,
		maximumBytes: Int
	) throws -> (chunk: String, next: Int?) {
		let bytes = Array(text.utf8)
		guard offset <= bytes.count else { throw AutomationFailure.staleCursor }
		guard offset < bytes.count else { return ("", nil) }

		var end = min(bytes.count, offset + maximumBytes)
		if end < bytes.count {
			if let newline = bytes[offset..<end].lastIndex(of: 0x0A), newline > offset {
				end = newline + 1
			} else {
				// Never cut a scalar in half.
				while end > offset, bytes[end] & 0xC0 == 0x80 { end -= 1 }
			}
		}
		guard end > offset else { throw AutomationFailure.limitExceeded }

		let chunk = String(decoding: bytes[offset..<end], as: UTF8.self)
		return (chunk, end < bytes.count ? end : nil)
	}

	// MARK: - Find

	internal struct Match: Codable, Equatable, Sendable {
		internal var index: Int
		internal var role: String

		/// The node's reference, or its nearest ancestor's, for a later action.
		internal var reference: String?
		internal var excerpt: String
	}

	/// Case- and diacritic-insensitive matches in node text and explicit names.
	internal static func find(
		_ query: String,
		in nodes: [PageInspectionNode]
	) -> [Match] {
		let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
		var matches: [Match] = []
		for node in nodes {
			for value in [node.text, node.name].compactMap({ $0 }) {
				guard let range = value.range(of: query, options: options) else { continue }
				matches.append(.init(
					index: node.index,
					role: node.role,
					reference: reference(for: node, in: nodes),
					excerpt: excerpt(value, around: range)
				))
				break
			}
		}
		return matches
	}

	private static func reference(
		for node: PageInspectionNode,
		in nodes: [PageInspectionNode]
	) -> String? {
		var current: PageInspectionNode? = node
		while let candidate = current {
			if let reference = candidate.reference { return reference }
			current = candidate.parent.flatMap { nodes.indices.contains($0) ? nodes[$0] : nil }
		}
		return nil
	}

	private static func excerpt(
		_ value: String,
		around range: Range<String.Index>
	) -> String {
		let radius = 60
		let start = value.index(range.lowerBound, offsetBy: -radius, limitedBy: value.startIndex) ?? value.startIndex
		let end = value.index(range.upperBound, offsetBy: radius, limitedBy: value.endIndex) ?? value.endIndex
		let prefix = start == value.startIndex ? "" : "…"
		let suffix = end == value.endIndex ? "" : "…"
		return prefix + collapsed(String(value[start..<end])) + suffix
	}

	fileprivate static func collapsed(_ value: String) -> String {
		value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
	}

	// MARK: - Rendering

	private struct Renderer {
		internal let nodes: [PageInspectionNode]
		internal let children: [Int: [Int]]
		internal let format: Format
		internal let skipsChrome: Bool
		internal var lines: [String] = []
		internal var pending: String = ""

		internal init(
			nodes: [PageInspectionNode],
			children: [Int: [Int]],
			format: Format,
			skipsChrome: Bool
		) {
			self.nodes = nodes
			self.children = children
			self.format = format
			self.skipsChrome = skipsChrome
		}

		internal mutating func block(
			_ index: Int,
			listDepth: Int
		) {
			let node = nodes[index]
			if skipsChrome, AutomationReadableText.chromeRoles.contains(node.role) { return }
			if AutomationReadableText.inlineRoles.contains(node.role) {
				append(inline(index))
				return
			}

			switch node.role {
			case "heading":
				paragraph(prefix: format == .markdown ? "## " : "", inline(index))

			case "listItem":
				let indent = String(repeating: "  ", count: max(0, listDepth - 1))
				paragraph(prefix: indent + "- ", inline(index, skippingLists: true), separated: false)
				for child in children[index] ?? [] where isList(child) {
					block(child, listDepth: listDepth)
				}

			case "list", "descriptionList":
				flush()
				for child in children[index] ?? [] {
					block(child, listDepth: listDepth + 1)
				}
				flush()
				separate()

			case "blockquote":
				paragraph(prefix: format == .markdown ? "> " : "", inline(index))

			case "pre":
				let text = inline(index, preservesWhitespace: true)
				guard !text.isEmpty else { return }
				flush()
				lines += format == .markdown ? ["```", text, "```"] : [text]
				separate()

			case "paragraph", "caption", "figcaption", "term", "definition", "cell", "columnHeader",
				"rowHeader", "button", "checkBox", "radioButton", "menuItem", "tab", "label":
				paragraph(prefix: "", inline(index))

			default:
				let isSection = AutomationReadableText.sectionRoles.contains(node.role)
				if isSection { flush() }
				for child in children[index] ?? [] {
					block(child, listDepth: listDepth)
				}
				if isSection { flush() }
			}
		}

		internal mutating func flush() {
			let text = AutomationReadableText.collapsed(pending)
			pending = ""
			guard !text.isEmpty else { return }
			lines.append(text)
			separate()
		}

		private mutating func append(_ text: String) {
			guard !text.isEmpty else { return }
			pending += pending.isEmpty || pending.last?.isWhitespace == true ? text : " " + text
		}

		private mutating func paragraph(
			prefix: String,
			_ text: String,
			separated: Bool = true
		) {
			flush()
			guard !text.isEmpty else { return }
			lines.append(prefix + text)
			if separated { separate() }
		}

		private mutating func separate() {
			if lines.last != "" { lines.append("") }
		}

		private func isList(_ index: Int) -> Bool {
			["list", "descriptionList"].contains(nodes[index].role)
		}

		private func inline(
			_ index: Int,
			skippingLists: Bool = false,
			preservesWhitespace: Bool = false
		) -> String {
			var parts: [String] = []
			func visit(_ index: Int) {
				let node = nodes[index]
				if skippingLists, isList(index) { return }
				if let text = node.text {
					parts.append(text)
				} else if node.role == "image", let name = node.name {
					parts.append(format == .markdown ? "![\(name)]" : name)
				} else if node.role == "lineBreak" {
					parts.append("\n")
				}
				for child in children[index] ?? [] { visit(child) }
			}
			visit(index)
			let joined = parts.joined()
			return preservesWhitespace
			? joined.trimmingCharacters(in: .newlines)
			: AutomationReadableText.collapsed(joined)
		}
	}
}
