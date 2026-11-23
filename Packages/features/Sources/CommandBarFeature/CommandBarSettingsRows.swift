import Foundation
import _ComposableArchitecture

/// The Settings rows a window's command bar finds (DEV-1015), each an entry whose intent is
/// `openSettings` with the row's destination ID.
///
/// Settings' own search index supplies them, but this module doesn't know Settings, so the app
/// sets the live value: AppFeature's `CommandBarSettingsRows.settingsIndex`. Rows are read when
/// the bar opens, so a toggle's state is current.
public struct CommandBarSettingsRows: Sendable {
	public var entries: @MainActor @Sendable () -> [CommandBarFeature.Entry]

	public init(entries: @escaping @MainActor @Sendable () -> [CommandBarFeature.Entry]) {
		self.entries = entries
	}

	/// No Settings rows, as in Little Arx or a test that doesn't ask for them.
	public static let none: Self = .init { [] }
}

extension CommandBarSettingsRows: DependencyKey {
	public static var liveValue: Self { .none }
	public static var testValue: Self { .none }
	public static var previewValue: Self { .none }
}

extension DependencyValues {
	public var commandBarSettingsRows: CommandBarSettingsRows {
		get { self[CommandBarSettingsRows.self] }
		set { self[CommandBarSettingsRows.self] = newValue }
	}
}
