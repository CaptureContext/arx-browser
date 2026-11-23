import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct CommandAliasTests {
	@Test
	internal func aliasesAreTrimmedAndLowercased() {
		#expect(CommandAlias.normalized("  Pin ") == "pin")
		#expect(CommandAlias.normalized("   ") == nil)
	}

	@Test
	internal func preferencesFromBeforeAliasesHaveNone() throws {
		let old = Data(#"{"grainEnabled":true,"grainIntensity":0.35,"grainSize":1,"searchShortcuts":[]}"#.utf8)
		let preferences = try JSONDecoder().decode(BrowserPreferences.self, from: old)
		expectNoDifference(preferences.commandAliases, [])
	}

	@Test
	internal func aliasesRoundTripAndFindTheirCommand() throws {
		var preferences = BrowserPreferences()
		preferences.commandAliases.setAlias("pin", for: .pinTab)
		preferences.commandAliases.setAlias("dup", for: .duplicateTab)
		try preferences.validate()
		let decoded = try JSONDecoder().decode(BrowserPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded, preferences)
		#expect(decoded.commandAliases.command(forAlias: " PIN") == .pinTab)
		#expect(decoded.commandAliases.alias(for: .duplicateTab) == "dup")

		preferences.commandAliases.setAlias(nil, for: .pinTab)
		#expect(preferences.commandAliases.alias(for: .pinTab) == nil)
	}

	@Test(arguments: ["", "two words", "!gh", "Pin"])
	internal func invalidAliasesAreRejected(alias: String) {
		var preferences = BrowserPreferences()
		preferences.commandAliases = [.init(command: .pinTab, alias: alias)]
		#expect(throws: CommandAlias.Failure.invalidAlias) { try preferences.validate() }
	}

	@Test
	internal func twoCommandsCantShareAnAlias() {
		var preferences = BrowserPreferences()
		preferences.commandAliases = [
			.init(command: .pinTab, alias: "p"),
			.init(command: .duplicateTab, alias: "p"),
		]
		#expect(throws: CommandAlias.Failure.duplicateAlias) { try preferences.validate() }
	}
}
