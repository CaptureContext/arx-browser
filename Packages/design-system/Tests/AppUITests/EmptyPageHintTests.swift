@testable import AppUI
import BrowserCore
import Foundation
import Testing

/// The homepage's tips (DEV-1263): about a hundred, each true of Arx today. Commands are checked
/// here; the Settings rows tips name are checked in IntegrationFeatureTests, which sees Settings.
internal struct EmptyPageHintTests {
	@Test
	internal func thereAreAboutAHundredTipsWithTheDefaultKeys() async throws {
		let texts: [String] = EmptyPageHints.texts(bindings: [])

		#expect((99 ... 100).contains(texts.count), "\(texts.count) tips")
	}

	@Test
	internal func noTwoTipsShareAKeyOrWords() async throws {
		let keys: [String] = EmptyPageHints.all.map(\.key)
		let templates: [String] = EmptyPageHints.all.map(\.template)
		let texts: [String] = EmptyPageHints.texts(bindings: [])

		#expect(Set(keys).count == keys.count, "\(Self.repeated(keys))")
		#expect(Set(templates).count == templates.count, "\(Self.repeated(templates))")
		#expect(Set(texts).count == texts.count, "\(Self.repeated(texts))")
		for key in keys {
			#expect(key.hasPrefix("emptyPage.hint"), "\(key)")
		}
	}

	/// Keys come from the command's binding, never from the tip's own words: none spells out ⌘,
	/// ⌥, ⌃ or ⇧.
	@Test
	internal func noTipTypesItsOwnKeys() async throws {
		for hint in EmptyPageHints.all {
			#expect(!hint.template.contains { "⌘⌥⌃⇧".contains($0) }, "\(hint.key): \(hint.template)")
		}
	}

	/// Each tip that shows keys shows the command's current ones, follows a rebinding, and goes
	/// when the command has no keys left.
	@Test
	internal func everyTipShowsItsCommandsCurrentKeys() async throws {
		let modifiers: KeyboardShortcut.Modifiers = [.control, .option, .shift, .command]
		let replacements: [KeyboardShortcut] = [
			.init(key: "f5", modifiers: modifiers),
			.init(key: "f7", modifiers: modifiers),
		]
		for hint in EmptyPageHints.all where !hint.shortcuts.isEmpty {
			let rebound: [ShortcutBinding] = zip(hint.shortcuts, replacements).map { command, shortcut in
				.init(command: command, shortcut: shortcut)
			}
			let text = try #require(hint.text(bindings: rebound), "\(hint.key)")
			for shortcut in replacements.prefix(hint.shortcuts.count) {
				#expect(text.contains(shortcut.display), "\(hint.key): \(text)")
			}

			if let defaultText = hint.text(bindings: []) {
				for command in hint.shortcuts {
					let display = try #require(command.shortcut?.display, "\(hint.key)")
					#expect(defaultText.contains(display), "\(hint.key): \(defaultText)")
				}
			}

			for command in hint.shortcuts {
				#expect(hint.text(bindings: [.init(command: command, shortcut: nil)]) == nil, "\(hint.key)")
			}
		}
	}

	/// A tip that names a command by its title uses the title the menus and the command bar show.
	@Test
	internal func everyNamedCommandKeepsItsTitle() async throws {
		for hint in EmptyPageHints.all {
			for case let .command(command) in hint.needs {
				#expect(hint.template.contains(command.title), "\(hint.key) names \(command.title)")
			}
		}
	}

	/// Nothing a tip describes may wait behind a flag that's off by default.
	@Test
	internal func everyFeatureFlagATipNeedsIsOnByDefault() async throws {
		for hint in EmptyPageHints.all {
			for case let .featureFlag(flag) in hint.needs {
				#expect(flag.isOnByDefault, "\(hint.key) needs \(flag.rawValue)")
			}
		}
	}

	/// A tip that sends the person to Settings names the row it means, which IntegrationFeatureTests
	/// checks.
	@Test
	internal func everyTipThatNamesSettingsNamesItsRow() async throws {
		for hint in EmptyPageHints.all where hint.template.contains("Settings ›") {
			let settings = hint.needs.filter { need in
				if case .setting = need { return true }
				return false
			}
			#expect(!settings.isEmpty, "\(hint.key)")
		}
	}

	private static func repeated(_ values: [String]) -> [String] {
		Dictionary(grouping: values, by: \.self).filter { $0.value.count > 1 }.map(\.key)
	}
}
