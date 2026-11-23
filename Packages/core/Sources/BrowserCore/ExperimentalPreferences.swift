import Foundation

/// Opt-in experiments from Settings' Experimental pane. They may change or go away.
///
/// There are none right now. The set stays so a later experiment has a place to live; it
/// decodes from any saved object and ignores keys it doesn't know, such as an earlier build's
/// `chatStyle`.
public struct ExperimentalPreferences: Codable, Equatable, Sendable {
	public init() {}
}
