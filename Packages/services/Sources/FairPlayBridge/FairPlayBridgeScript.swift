import Foundation

/// The page script the engine's page media bridge runs in FairPlay sites (DEV-1144):
/// `Resources/FairPlayBridge.js`, an expression that evaluates to `function (send) { …; return
/// receive; }`.
public enum FairPlayBridgeScript {
	/// The script's source, or nil when the resource is missing from the build.
	public static let source: String? = Bundle.module
		.url(forResource: "FairPlayBridge", withExtension: "js")
		.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
}
