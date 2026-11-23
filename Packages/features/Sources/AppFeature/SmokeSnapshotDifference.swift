#if DEBUG
import BrowserCore
import Foundation

/// How a page's snapshot differs from one an app smoke took before a step that mustn't change the
/// page, leaving aside the colors the page reports.
///
/// Chromium reports a page's colors from the frames it draws (`DidChangeThemeColor`,
/// `OnBackgroundColorChanged`), and the engine passes them on as the navigation's `colors` without
/// a new revision, so they can arrive after a page has loaded, or again after it's resized. A
/// cross-profile move doesn't count them either (DEV-1030). Everything else must be as it was: the
/// page, its profile, document, address, history, title and loading.
///
/// - Capture Page beyond the viewport (DEV-1172) lays the page out at its whole height for one
///   frame and back, so the page sees a resize; its revision moves with what it reports about its
///   size, and the smoke leaves the revision aside too (`ignoringRevision`).
/// - Moving a folder through MCP keeps the page's session, revision included.
internal enum SmokeSnapshotDifference: Equatable {
	case none

	/// Only the page's reported colors differ.
	case colors(String)

	/// Something else differs: the fields that do, with the navigation's own named.
	case changed(String)

	@MainActor
	internal static func between(
		_ original: BrowserSessionSnapshot?,
		_ current: BrowserSessionSnapshot?,
		ignoringRevision: Bool = false
	) -> Self {
		guard let original, var current else {
			return original == nil && current == nil
			? .none
			: .changed("snapshot \(original == nil ? "none" : "some")->\(current == nil ? "none" : "some")")
		}

		if ignoringRevision { current.revision = original.revision }
		guard current != original else { return .none }

		var recolored = current
		recolored.navigation.colors = original.navigation.colors
		guard recolored == original else {
			return .changed(SmokeDiagnostics.snapshotChanges(from: original, to: current))
		}

		return .colors(SmokeDiagnostics.changes(from: original.navigation.colors, to: current.navigation.colors))
	}

	/// Logs colors that stayed changed, so a page whose chrome tint a step really changed still
	/// shows in the log, and says whether the page is otherwise as it was.
	@MainActor
	internal func isUnchanged(check: String) -> Bool {
		switch self {
		case .none:
			return true
		case let .colors(fields):
			FileHandle.standardError.write(Data("ARX_SMOKE_COLORS_CHANGED check=\(check) colors=\(fields)\n".utf8))
			return true
		case .changed:
			return false
		}
	}
}
#endif
