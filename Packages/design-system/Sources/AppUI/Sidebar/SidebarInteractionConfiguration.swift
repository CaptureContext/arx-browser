import BrowserCore
import SwiftUI

/// Presentation timing is supplied by the feature; cancellation stays with the mounted view.
public struct SidebarInteractionConfiguration: Equatable, Sendable {
	public var edgeRevealDelay: Duration
	public var edgeHideDelay: Duration
	public var spaceHoverDelay: Duration
	public var folderHoverDelay: Duration

	/// How long the pointer rests on a tab or folder before its hover preview opens.
	public var hoverPreviewDelay: Duration

	/// How long a folder's preview stays open after the pointer leaves, so it can reach the list.
	public var hoverPreviewDismissDelay: Duration

	/// Whether Shift opens a hover preview at once and has a tab's card load its page (DEV-1029),
	/// under `ARX_SHIFT_HOVER_PREVIEW`.
	public var shiftOpensPreviews: Bool

	public init(
		edgeRevealDelay: Duration = .milliseconds(120),
		edgeHideDelay: Duration = .milliseconds(300),
		spaceHoverDelay: Duration = .milliseconds(500),
		folderHoverDelay: Duration = .milliseconds(650),
		hoverPreviewDelay: Duration = .seconds(1),
		hoverPreviewDismissDelay: Duration = .milliseconds(250),
		shiftOpensPreviews: Bool = SidebarShiftHoverPreview.isEnabled
	) {
		self.edgeRevealDelay = edgeRevealDelay
		self.edgeHideDelay = edgeHideDelay
		self.spaceHoverDelay = spaceHoverDelay
		self.folderHoverDelay = folderHoverDelay
		self.hoverPreviewDelay = hoverPreviewDelay
		self.hoverPreviewDismissDelay = hoverPreviewDismissDelay
		self.shiftOpensPreviews = shiftOpensPreviews
	}
}

/// Shift-hover previews (DEV-1029), on by default, as every flag is for the beta;
/// `ARX_SHIFT_HOVER_PREVIEW` set to `0`, `false`, `no` or `off` leaves Shift to the hover delay.
public enum SidebarShiftHoverPreview {
	/// Whether Shift opens previews at once. Read once, at launch.
	public static let isEnabled: Bool = FeatureFlag.shiftHoverPreview.isOn()
}

extension EnvironmentValues {
	@Entry
	public var sidebarInteraction: SidebarInteractionConfiguration = .init()
}
