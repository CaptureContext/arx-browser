import Foundation

/// One of Arx's skills for a site agents use often: Gmail, Google Docs and Sheets, Linear,
/// GitHub and Notion. Each says how that site works in terms of Arx's MCP tools, so an agent
/// doesn't rediscover it on every task.
///
/// `arx setup` installs them beside the `arx-browser` skill. The MCP server names the one that
/// fits a page in its first answer about that site, and serves its text as the
/// `arx://skills/<name>` resource for agents without a skill folder.
///
/// `Skill/<name>/SKILL.md` in this target is the source; `AgentSiteSkillText.swift` holds the
/// same text, compiled in. `AgentSiteSkillTests` fails when the two differ.
public struct AgentSiteSkill: Equatable, Sendable {
	public let name: String
	public let version: Int
	public let description: String

	/// Hosts, each optionally with a path: `docs.google.com/spreadsheets` is Sheets, not Docs.
	/// A host covers its subdomains.
	public let sites: [String]

	public let text: String

	internal init(text: String) {
		let fields: [String: String] = AgentSkill.frontmatter(text)
		self.name = fields["name"] ?? ""
		self.version = fields["version"].flatMap(Int.init) ?? 0
		self.description = fields["description"] ?? ""
		self.sites = (fields["sites"] ?? "")
			.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
			.filter { !$0.isEmpty }
		self.text = text
	}

	public static let all: [AgentSiteSkill] = texts.map(AgentSiteSkill.init(text:))

	public static func named(_ name: String) -> AgentSiteSkill? {
		all.first { $0.name == name }
	}

	/// The skills for a page's address.
	public static func matching(_ url: URL) -> [AgentSiteSkill] {
		all.filter { $0.matches(url) }
	}

	public func matches(_ url: URL) -> Bool {
		guard
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			let host = url.host()?.lowercased()
		else { return false }

		let path: String = url.path(percentEncoded: true).lowercased()
		return sites.contains { site in
			let parts = site.split(separator: "/", maxSplits: 1)
			guard let siteHost = parts.first.map(String.init)
			else { return false }

			let isOnHost: Bool = host == siteHost || host.hasSuffix("." + siteHost)
			guard isOnHost, parts.count == 2
			else { return isOnHost }

			let prefix: String = "/" + parts[1]
			return path == prefix || path.hasPrefix(prefix + "/")
		}
	}
}
