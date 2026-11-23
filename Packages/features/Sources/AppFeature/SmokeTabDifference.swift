#if DEBUG
import BrowserCore
import Foundation

/// How a workspace tab differs from one an app smoke kept before a step that mustn't change it,
/// leaving aside its restoration: the title and address its page last reported.
///
/// A page's load finishing, or its title arriving, saves the restoration after the smoke's own
/// wait (`MainFeature` saves only finished loads), and moves and Undo already treat it as browsing,
/// not structure (`BrowserOrganization.hasSameMoveStructure`). Whether the page itself stayed is
/// the snapshot's to say (`SmokeSnapshotDifference`). Everything else must be as it was: the tab,
/// its profile, saved destination, custom title and client (engine batch 8 saw a bare
/// `tabUnchanged` after a folder move).
internal enum SmokeTabDifference: Equatable {
	case none

	/// Only the restoration differs: its fields that do.
	case restoration(String)

	/// Something else differs: the fields that do, with the saved destination's and restoration's
	/// own named.
	case changed(String)

	@MainActor
	internal static func between(
		_ original: BrowserCore.Tab?,
		_ current: BrowserCore.Tab?
	) -> Self {
		guard let original, let current else {
			return original == nil && current == nil
			? .none
			: .changed("tab \(original == nil ? "none" : "some")->\(current == nil ? "none" : "some")")
		}
		guard current != original else { return .none }

		var restored = current
		restored.restoration = original.restoration
		guard restored == original else { return .changed(changes(from: original, to: current)) }

		return .restoration(SmokeDiagnostics.changes(from: original.restoration, to: current.restoration))
	}

	/// Logs a restoration that changed, so a page that really moved still shows in the log, and
	/// says whether the tab is otherwise as it was.
	@MainActor
	internal func isUnchanged(check: String) -> Bool {
		switch self {
		case .none:
			return true
		case let .restoration(fields):
			FileHandle.standardError.write(Data("ARX_SMOKE_TAB_RESTORATION_CHANGED check=\(check) restoration=\(fields)\n".utf8))
			return true
		case .changed:
			return false
		}
	}

	/// The tab's fields that differ, naming the saved destination's and restoration's own, as
	/// `savedDestination(iconURL),customTitle`. Names only, never titles or addresses.
	@MainActor
	private static func changes(
		from original: BrowserCore.Tab,
		to current: BrowserCore.Tab
	) -> String {
		SmokeDiagnostics.changes(from: original, to: current)
			.split(separator: ",")
			.map { field -> String in
				switch field {
				case "savedDestination":
					"savedDestination(\(SmokeDiagnostics.changes(from: original.savedDestination, to: current.savedDestination)))"
				case "restoration":
					"restoration(\(SmokeDiagnostics.changes(from: original.restoration, to: current.restoration)))"
				default:
					String(field)
				}
			}
			.joined(separator: ",")
	}
}
#endif
