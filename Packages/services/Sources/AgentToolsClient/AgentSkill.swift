import BrowserAutomationClient
import Foundation

/// The `arx-browser` skill: how to work with Arx's MCP tools efficiently, for agents that
/// load skills from a folder. `arx setup` installs it next to the MCP configuration it writes,
/// with the site skills (``AgentSiteSkill``).
///
/// `Skill/arx-browser/SKILL.md` in this target is the source; ``text`` is the same file,
/// compiled in so the `arx` command needs no resource bundle. `AgentSkillTests` fails when
/// the two differ.
public enum AgentSkill {
	public static let name: String = "arx-browser"

	/// Raise it with every change to the skill, so agents and `arx guide` can tell versions apart.
	public static let version: Int = 21

	/// The skill's folder, relative to the home folder, for agents that load user skills from one.
	/// `nil` for agents without file-based skills: Claude Desktop takes skills through its
	/// own interface, and Cursor reads only the server's instructions.
	///
	/// - Claude Code: https://code.claude.com/docs/en/skills
	/// - Codex: https://developers.openai.com/codex/skills
	public static func relativeFolder(
		for agent: AgentSetup.Agent,
		skill: String = name
	) -> String? {
		switch agent {
		case .claude: ".claude/skills/\(skill)"
		case .codex: ".codex/skills/\(skill)"
		case .claudeDesktop, .cursor: nil
		}
	}

	public static func url(
		for agent: AgentSetup.Agent,
		skill: String = name,
		home: URL
	) -> URL? {
		relativeFolder(for: agent, skill: skill).map { home.appending(path: $0).appending(path: "SKILL.md") }
	}

	/// Every skill Arx installs: this one, then each ``AgentSiteSkill``.
	internal static var installed: [(name: String, text: String)] {
		[(name, text)] + AgentSiteSkill.all.map { ($0.name, $0.text) }
	}

	/// Writes this skill and the site skills for `agent`, replacing earlier versions of Arx's own.
	///
	/// - Returns: Where this skill was written, or `nil` when the agent has no skill folder or the
	///   folder already holds someone else's skill, which is never replaced.
	@discardableResult
	public static func install(
		for agent: AgentSetup.Agent,
		home: URL
	) throws -> URL? {
		var written: URL?
		for skill in installed {
			let url = try write(skill.text, named: skill.name, for: agent, home: home)
			if skill.name == name { written = url }
		}
		return written
	}

	/// Removes Arx's skills for `agent`. Someone else's skill in the same folder stays.
	public static func remove(
		for agent: AgentSetup.Agent,
		home: URL
	) throws {
		for skill in installed {
			try delete(named: skill.name, for: agent, home: home)
		}
	}

	private static func write(
		_ text: String,
		named skill: String,
		for agent: AgentSetup.Agent,
		home: URL
	) throws -> URL? {
		guard let url = url(for: agent, skill: skill, home: home)
		else { return nil }

		try RealHomeGuard.check(url)
		if FileManager.default.fileExists(atPath: url.path), !isArxSkill(at: url, named: skill) {
			return nil
		}
		try FileManager.default.createDirectory(
			at: url.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try Data((text + "\n").utf8).write(to: url, options: .atomic)
		return url
	}

	private static func delete(
		named skill: String,
		for agent: AgentSetup.Agent,
		home: URL
	) throws {
		guard
			let url = url(for: agent, skill: skill, home: home),
			isArxSkill(at: url, named: skill)
		else { return }

		try RealHomeGuard.check(url)
		let folder: URL = url.deletingLastPathComponent()
		try FileManager.default.removeItem(at: url)

		// The folder goes too, unless something else was put in it.
		if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
			try? FileManager.default.removeItem(at: folder)
		}
	}

	/// The installed skill's version, or `nil` when Arx's skill isn't there.
	public static func installedVersion(
		for agent: AgentSetup.Agent,
		skill: String = name,
		home: URL
	) -> Int? {
		guard
			let url = url(for: agent, skill: skill, home: home),
			isArxSkill(at: url, named: skill),
			let text = try? String(contentsOf: url, encoding: .utf8)
		else { return nil }

		return frontmatter(text)["version"].flatMap(Int.init)
	}

	/// The comment that marks a `SKILL.md` as Arx's own, site skills included. A skill someone
	/// else wrote under the same name doesn't carry it, so it's never replaced or removed.
	public static let ownershipMarker: String = "<!-- Installed by Arx (arx-browser-skill)."

	internal static func isArxSkill(
		at url: URL,
		named skill: String = name
	) -> Bool {
		guard let text = try? String(contentsOf: url, encoding: .utf8)
		else { return false }

		return frontmatter(text)["name"] == skill && text.contains(ownershipMarker)
	}

	/// The `key: value` lines between the opening and closing `---`.
	internal static func frontmatter(_ text: String) -> [String: String] {
		let lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
		guard lines.first == "---"
		else { return [:] }

		var fields: [String: String] = [:]
		for line in lines.dropFirst() {
			if line == "---" { break }
			guard let colon = line.firstIndex(of: ":")
			else { continue }

			let key: String = line[..<colon].trimmingCharacters(in: .whitespaces)
			let value: String = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
			fields[key] = value
		}
		return fields
	}
}
