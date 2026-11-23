import BrowserAutomationClient
import Foundation
import Testing

@testable import AgentToolsClient

/// Every skill is written in a temporary home folder, never the person's own.
internal struct AgentSiteSkillTests {
	private static var skillFolder: URL {
		URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appending(path: "Sources/AgentToolsClient/Skill")
	}

	@Test
	internal func theCompiledTextsMatchTheSkillFiles() throws {
		let names: [String] = try FileManager.default.contentsOfDirectory(atPath: Self.skillFolder.path)
			.filter { $0 != AgentSkill.name && !$0.hasPrefix(".") }
			.sorted()
		#expect(names == AgentSiteSkill.all.map(\.name).sorted(), "Add each Skill folder to AgentSiteSkillText.swift.")

		for skill in AgentSiteSkill.all {
			let file: URL = Self.skillFolder.appending(path: skill.name).appending(path: "SKILL.md")
			let source: String = try String(contentsOf: file, encoding: .utf8)
			#expect(
				source.trimmingCharacters(in: .newlines) == skill.text,
				"Copy Skill/\(skill.name)/SKILL.md into AgentSiteSkillText.swift verbatim."
			)
		}
	}

	@Test(arguments: AgentSiteSkill.all.map(\.name))
	internal func theFrontmatterNamesTheSkillItsVersionAndSites(name: String) throws {
		let skill = try #require(AgentSiteSkill.named(name))
		#expect(skill.name.hasPrefix("arx-"))
		#expect(skill.version >= 1)
		#expect(!skill.description.isEmpty)
		#expect(!skill.sites.isEmpty)
		#expect(skill.text.contains(AgentSkill.ownershipMarker))
		#expect(AgentSiteSkill.all.filter { $0.name == skill.name }.count == 1)
	}

	/// Skill loaders parse the frontmatter as YAML. Plain scalars break on ": " and " #", and on
	/// a leading indicator character, so every value stays clear of them.
	@Test(arguments: AgentSiteSkill.all.map(\.name))
	internal func theFrontmatterIsPlainYAML(name: String) throws {
		let skill = try #require(AgentSiteSkill.named(name))
		for (key, value) in AgentSkill.frontmatter(skill.text) {
			#expect(!value.contains(": "), "\(skill.name) \(key) contains ': '")
			#expect(!value.contains(" #"), "\(skill.name) \(key) contains ' #'")
			#expect(
				value.first.map { !"-?:,[]{}#&*!|>'\"%@`".contains($0) } ?? false,
				"\(skill.name) \(key) starts with an indicator"
			)
		}
	}

	@Test(arguments: [
		("https://docs.google.com/spreadsheets/d/abc/edit", "arx-google-sheets"),
		("https://docs.google.com/spreadsheets/u/1/d/abc/gviz/tq", "arx-google-sheets"),
		("https://docs.google.com/spreadsheets", "arx-google-sheets"),
		("https://docs.google.com/document/d/abc/mobilebasic", "arx-google-docs"),
		("https://mail.google.com/mail/u/0/", "arx-gmail"),
		("https://linear.app/capturecontext/issue/DEV-1", "arx-linear"),
		("https://linear.new/", "arx-linear"),
		("https://github.com/capturecontext/arx-browser/pull/1", "arx-github"),
		("https://gist.github.com/someone/1", "arx-github"),
		("https://www.notion.so/team/Plan-0123456789abcdef0123456789abcdef", "arx-notion"),
		("https://someone.notion.site/Page", "arx-notion"),
		("https://WWW.Notion.SO/Page", "arx-notion"),
	])
	internal func aPageMatchesItsSitesSkill(address: String, name: String) throws {
		let url = try #require(URL(string: address))
		#expect(AgentSiteSkill.matching(url).map(\.name) == [name])
	}

	@Test(arguments: [
		"https://docs.google.com/presentation/d/abc/edit",
		"https://docs.google.com/spreadsheetsx/d/abc",
		"https://docs.google.com/",
		"https://notgithub.com/a/b",
		"https://github.com.example.com/a",
		"https://example.com/mail.google.com",
		"file:///Users/someone/github.com",
	])
	internal func otherPagesMatchNothing(address: String) throws {
		let url = try #require(URL(string: address))
		#expect(AgentSiteSkill.matching(url).isEmpty)
	}

	@Test(arguments: [AgentSetup.Agent.claude, .codex])
	internal func installWritesEverySiteSkillAndRemoveTakesThemAway(agent: AgentSetup.Agent) throws {
		let home: URL = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }

		try AgentSkill.install(for: agent, home: home)
		for skill in AgentSiteSkill.all {
			let url = try #require(AgentSkill.url(for: agent, skill: skill.name, home: home))
			#expect(try String(contentsOf: url, encoding: .utf8) == skill.text + "\n")
			#expect(AgentSkill.installedVersion(for: agent, skill: skill.name, home: home) == skill.version)
		}

		try AgentSkill.remove(for: agent, home: home)
		for skill in AgentSiteSkill.all {
			let url = try #require(AgentSkill.url(for: agent, skill: skill.name, home: home))
			#expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
		}
	}

	@Test
	internal func someoneElsesSkillUnderASiteSkillsNameStays() throws {
		let home: URL = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let url = try #require(AgentSkill.url(for: .claude, skill: "arx-gmail", home: home))
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		let theirs: String = "---\nname: arx-gmail\n---\nmy own gmail notes\n"
		try theirs.write(to: url, atomically: true, encoding: .utf8)

		#expect(try AgentSkill.install(for: .claude, home: home) == AgentSkill.url(for: .claude, home: home))
		#expect(try String(contentsOf: url, encoding: .utf8) == theirs)

		try AgentSkill.remove(for: .claude, home: home)
		#expect(try String(contentsOf: url, encoding: .utf8) == theirs)
	}

	private func temporaryHome() throws -> URL {
		let home: URL = FileManager.default.temporaryDirectory
			.appending(path: "arx-site-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		return home
	}
}
