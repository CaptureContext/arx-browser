import AgentClient
import AppUI
import Foundation

/// A prompt a new chat offers above the composer, about the tab the window shows.
///
/// Picking one attaches that tab and sends the prompt, so the assistant reads the page
/// only when the person chose to ask about it.
public struct ChatSuggestion: Equatable, Identifiable, Sendable {
	/// What the prompt asks about the page, so a tap can ask it about the page focused when
	/// it's made (DEV-835).
	public enum Kind: Equatable, Sendable {
		case summarize
		case takeaways
		case explain
	}

	public var kind: Kind
	public var prompt: String
	public var tab: AgentContextAttachment.Tab

	public init(
		kind: Kind,
		prompt: String,
		tab: AgentContextAttachment.Tab
	) {
		self.kind = kind
		self.prompt = prompt
		self.tab = tab
	}

	public var id: String { prompt }

	/// The same request about `tab`: its prompt names that page. `nil` when `tab` offers no
	/// suggestions, such as a new tab.
	public func retargeted(to tab: AgentContextAttachment.Tab) -> Self? {
		guard tab != self.tab
		else { return self }

		return Self.suggestions(for: tab).first { $0.kind == kind }
	}

	/// At most three prompts built from a page's title and site. None for pages that aren't
	/// on the web, such as a new tab.
	public static func suggestions(for tab: AgentContextAttachment.Tab) -> [Self] {
		guard
			let url = URL(string: tab.url),
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let site = site(url)
		else { return [] }

		let title: String = tab.title
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.split(whereSeparator: \.isNewline)
			.first
			.map(String.init) ?? ""
		let subject: String = title.isEmpty || title == tab.url ? site : shortened(title)

		let prompts: [(Kind, String)] = [
			(.summarize, String.localized(.appUI.chat.suggestionSummarize(subject))),
			(.takeaways, String.localized(.appUI.chat.suggestionTakeaways(site))),
			(.explain, String.localized(.appUI.chat.suggestionExplain(subject))),
		]
		return prompts.map { Self(kind: $0.0, prompt: $0.1, tab: tab) }
	}

	/// The host without "www.", as people name a site.
	private static func site(_ url: URL) -> String? {
		guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
		else { return nil }

		return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
	}

	private static func shortened(_ title: String) -> String {
		guard title.count > titleLimit
		else { return title }

		return String(title.prefix(titleLimit - 1)) + "…"
	}

	private static let titleLimit: Int = 60
}
