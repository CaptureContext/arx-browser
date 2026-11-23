import BrowserAutomationClient
import Foundation
import Testing

@testable import AgentToolsClient

/// Every skill is written in a temporary home folder, never the person's own.
internal struct AgentSkillTests {
	@Test
	internal func theCompiledTextMatchesTheSkillFile() throws {
		let file: URL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appending(path: "Sources/AgentToolsClient/Skill/arx-browser/SKILL.md")
		let source: String = try String(contentsOf: file, encoding: .utf8)
		#expect(
			source.trimmingCharacters(in: .newlines) == AgentSkill.text,
			"Copy Skill/arx-browser/SKILL.md into AgentSkillText.swift verbatim."
		)
	}

	@Test
	internal func theFrontmatterNamesTheSkillAndItsVersion() {
		let fields: [String: String] = AgentSkill.frontmatter(AgentSkill.text)
		#expect(fields["name"] == AgentSkill.name)
		#expect(fields["version"] == String(AgentSkill.version))
		#expect(fields["description"]?.isEmpty == false)
		#expect(AgentSkill.text.contains(AgentSkill.ownershipMarker))
	}

	/// Skill loaders parse the frontmatter as YAML. Plain scalars break on ": " and " #", and on
	/// a leading indicator character, so every value stays clear of them.
	@Test
	internal func theFrontmatterIsPlainYAML() {
		for (key, value) in AgentSkill.frontmatter(AgentSkill.text) {
			#expect(!value.contains(": "), "\(key) contains ': '")
			#expect(!value.contains(" #"), "\(key) contains ' #'")
			#expect(value.first.map { !"-?:,[]{}#&*!|>'\"%@`".contains($0) } ?? false, "\(key) starts with an indicator")
		}
	}

	@Test(arguments: [AgentSetup.Agent.claude, .codex])
	internal func installWritesAndRemoveTakesItAway(agent: AgentSetup.Agent) throws {
		let home: URL = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }

		let url = try #require(try AgentSkill.install(for: agent, home: home))
		#expect(url == AgentSkill.url(for: agent, home: home))
		#expect(try String(contentsOf: url, encoding: .utf8) == AgentSkill.text + "\n")
		#expect(AgentSkill.installedVersion(for: agent, home: home) == AgentSkill.version)

		// Installing again replaces Arx's own copy.
		try "---\nname: arx-browser\nversion: 0\n---\n\(AgentSkill.ownershipMarker) -->\nold\n".write(
			to: url,
			atomically: true,
			encoding: .utf8
		)
		#expect(AgentSkill.installedVersion(for: agent, home: home) == 0)
		try AgentSkill.install(for: agent, home: home)
		#expect(AgentSkill.installedVersion(for: agent, home: home) == AgentSkill.version)

		try AgentSkill.remove(for: agent, home: home)
		#expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
		#expect(AgentSkill.installedVersion(for: agent, home: home) == nil)
		// Removing again is a no-op.
		try AgentSkill.remove(for: agent, home: home)
	}

	@Test(arguments: ["---\nname: something-else\n---\nmine\n", "---\nname: arx-browser\n---\nmy own arx notes\n"])
	internal func someoneElsesSkillIsNeverReplacedOrRemoved(theirs: String) throws {
		let home: URL = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let url = try #require(AgentSkill.url(for: .claude, home: home))
		try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
		try theirs.write(to: url, atomically: true, encoding: .utf8)

		#expect(try AgentSkill.install(for: .claude, home: home) == nil)
		try AgentSkill.remove(for: .claude, home: home)

		#expect(try String(contentsOf: url, encoding: .utf8) == theirs)
	}

	@Test
	internal func removeKeepsOtherFilesInTheFolder() throws {
		let home: URL = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }
		let url = try #require(try AgentSkill.install(for: .codex, home: home))
		let notes: URL = url.deletingLastPathComponent().appending(path: "notes.md")
		try "keep".write(to: notes, atomically: true, encoding: .utf8)

		try AgentSkill.remove(for: .codex, home: home)

		#expect(!FileManager.default.fileExists(atPath: url.path))
		#expect(FileManager.default.fileExists(atPath: notes.path))
	}

	@Test(arguments: [AgentSetup.Agent.claudeDesktop, .cursor])
	internal func agentsWithoutSkillFoldersGetNothing(agent: AgentSetup.Agent) throws {
		let home: URL = try temporaryHome()
		defer { try? FileManager.default.removeItem(at: home) }

		#expect(AgentSkill.relativeFolder(for: agent) == nil)
		#expect(try AgentSkill.install(for: agent, home: home) == nil)
		#expect(try FileManager.default.contentsOfDirectory(atPath: home.path).isEmpty)
	}

	@Test
	internal func connectingFromTheAppInstallsTheSkill() async throws {
		let world: AppsWorld = try .init()
		defer { world.remove() }

		try await world.client().add(.codex)

		#expect(AgentSkill.installedVersion(for: .codex, home: world.home) == AgentSkill.version)
	}

	private func temporaryHome() throws -> URL {
		let home: URL = FileManager.default.temporaryDirectory
			.appending(path: "arx-skill-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
		return home
	}
}
