import AppKit
import AppUI
import BrowserCore
import Foundation
import _ComposableArchitecture

// The calculator and quick-create rows (DEV-895). Both come from pure functions in
// BrowserCore over the typed text, with no network.

extension CommandBarFeature.State {
	/// The calculator's result for the typed text: Return copies it.
	internal func calculatorEntry(_ text: String) -> CommandBarFeature.Entry? {
		guard let result = CommandCalculator.evaluate(text) else { return nil }

		return .init(
			presentation: .init(
				id: Self.calculatorEntryID,
				title: String.localized(.appUI.command.calculatorResult(result.text)),
				subtitle: String.localized(.appUI.command.calculator),
				actionTitle: String.localized(.appUI.command.copyResult),
				symbol: "equal.circle"
			),
			intent: .copyText(result.text)
		)
	}

	/// What "new doc", "create sheet" or a bare `.new` domain can create, as pages to open.
	internal func quickCreateEntries(_ text: String) -> [CommandBarFeature.Entry] {
		QuickCreate.targets(for: text).map { target in
			.init(
				presentation: .init(
					id: "create-" + target.host,
					title: target.localizedTitle,
					subtitle: target.host,
					actionTitle: String.localized(.appUI.command.quickCreate),
					symbol: target.symbol
				),
				intent: .open(target.url)
			)
		}
	}

	internal static let calculatorEntryID: String = "calculator"
}

/// Where the calculator's Return puts its result.
public struct CommandBarClipboard: Sendable {
	public var copy: @MainActor @Sendable (String) -> Void

	public init(copy: @escaping @MainActor @Sendable (String) -> Void) {
		self.copy = copy
	}
}

extension CommandBarClipboard: DependencyKey {
	public static var liveValue: Self {
		.init { text in
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
		}
	}

	public static var testValue: Self {
		.init(copy: unimplemented("CommandBarClipboard.copy"))
	}
}

extension DependencyValues {
	public var commandBarClipboard: CommandBarClipboard {
		get { self[CommandBarClipboard.self] }
		set { self[CommandBarClipboard.self] = newValue }
	}
}

extension QuickCreate.Target {
	/// "New Google Docs Document": one catalog title per target, so no language has to put an
	/// English name into "New %@" and make the adjective agree with it (DEV-1291).
	fileprivate var localizedTitle: String {
		switch host {
		case "docs.new": String.localized(.appUI.command.quickCreateTarget.docs)
		case "sheets.new": String.localized(.appUI.command.quickCreateTarget.sheets)
		case "slides.new": String.localized(.appUI.command.quickCreateTarget.slides)
		case "forms.new": String.localized(.appUI.command.quickCreateTarget.forms)
		case "meet.new": String.localized(.appUI.command.quickCreateTarget.meet)
		case "cal.new": String.localized(.appUI.command.quickCreateTarget.cal)
		case "notion.new": String.localized(.appUI.command.quickCreateTarget.notion)
		case "linear.new": String.localized(.appUI.command.quickCreateTarget.linear)
		case "jira.new": String.localized(.appUI.command.quickCreateTarget.jira)
		case "confluence.new": String.localized(.appUI.command.quickCreateTarget.confluence)
		case "gist.new": String.localized(.appUI.command.quickCreateTarget.gist)
		case "repo.new": String.localized(.appUI.command.quickCreateTarget.repo)
		case "figma.new": String.localized(.appUI.command.quickCreateTarget.figma)
		case "figjam.new": String.localized(.appUI.command.quickCreateTarget.figjam)
		case "word.new": String.localized(.appUI.command.quickCreateTarget.word)
		case "excel.new": String.localized(.appUI.command.quickCreateTarget.excel)
		case "powerpoint.new": String.localized(.appUI.command.quickCreateTarget.powerpoint)
		default: title
		}
	}
}
