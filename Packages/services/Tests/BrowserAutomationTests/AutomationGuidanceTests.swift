import BrowserCore
import BrowserMCPServer
import Foundation
import Testing

/// The `arx-browser` skill, the site skills and the server's instructions name only tools the server has,
/// so a renamed or removed tool fails here until both are updated.
internal struct AutomationGuidanceTests {
	private static var toolNames: Set<String> {
		let all: AutomationGrantSummary = .init(capabilities: AutomationCapability.allCases)
		return Set(AutomationTools.definitions(for: all).map(\.name)).union([AutomationTools.moreToolsName])
	}

	private static func mentionedTools(in text: String) -> Set<String> {
		Set(
			text
				.split(whereSeparator: { !($0.isLetter || $0 == "_") })
				.map(String.init)
				.filter { $0.hasPrefix("browser_") && $0.count > "browser_".count }
		)
	}

	@Test
	internal func theSkillNamesOnlyToolsTheServerHas() throws {
		let file: URL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appending(path: "Sources/AgentToolsClient/Skill/arx-browser/SKILL.md")
		let mentioned: Set<String> = Self.mentionedTools(in: try String(contentsOf: file, encoding: .utf8))
		let unknown: Set<String> = mentioned.subtracting(Self.toolNames)
		#expect(unknown.isEmpty, "Unknown tools in SKILL.md: \(unknown.sorted())")
		#expect(mentioned.count > 20)
	}

	@Test
	internal func theSiteSkillsNameOnlyToolsTheServerHas() throws {
		let folder: URL = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.appending(path: "Sources/AgentToolsClient/Skill")
		let names: [String] = try FileManager.default.contentsOfDirectory(atPath: folder.path)
			.filter { $0.hasPrefix("arx-") && $0 != "arx-browser" }
		#expect(names.count >= 6)
		for name in names {
			let file: URL = folder.appending(path: name).appending(path: "SKILL.md")
			let mentioned: Set<String> = Self.mentionedTools(in: try String(contentsOf: file, encoding: .utf8))
			let unknown: Set<String> = mentioned.subtracting(Self.toolNames)
			#expect(unknown.isEmpty, "Unknown tools in \(name): \(unknown.sorted())")
			#expect(!mentioned.isEmpty, "\(name) names no tools")
		}
	}

	@Test
	internal func theInstructionsNameOnlyToolsTheServerHas() {
		let mentioned: Set<String> = Self.mentionedTools(in: AutomationTools.instructions)
		let unknown: Set<String> = mentioned.subtracting(Self.toolNames)
		#expect(unknown.isEmpty, "Unknown tools in the instructions: \(unknown.sorted())")
		#expect(mentioned.contains("browser_inventory"))
	}

	@Test
	internal func theInstructionsStayCompact() {
		// Clients put the instructions in every conversation; the skill holds the rest.
		#expect(AutomationTools.instructions.utf8.count < 4096)
	}
}
