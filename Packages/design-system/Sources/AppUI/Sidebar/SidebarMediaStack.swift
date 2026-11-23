import BrowserCore
import SwiftUI

/// Every media item of the window at the bottom of the sidebar (DEV-1245). At rest it shows one,
/// `restingID`; hovering expands it into the whole stack, in the order given, scrolling once it
/// holds more than about three and a half items.
///
/// The rows live in one scroll view at all times, so the row under the pointer keeps its identity
/// and its own hover as the stack expands around it; the caller rests on the last row that plays,
/// so the stack mostly grows upward from it, and a long stack opens scrolled to it. The scroll view's height follows its rows
/// and clips them, so a row that arrives shows only inside the frame as it grows (DEV-1244).
public struct SidebarMediaStack<Row: View>: View {
	private let ids: [BrowserMediaSource.ID]
	private let restingID: BrowserMediaSource.ID
	private let row: (BrowserMediaSource.ID) -> Row

	@SwiftUI.State
	private var isPointerInside: Bool

	@Environment(\.sidebarMediaStackHover)
	private var hoverOverride

	@SwiftUI.State
	private var contentHeight: CGFloat

	/// The row the scroll view keeps at its bottom edge: the resting one, where the pointer is.
	@SwiftUI.State
	private var scrolledID: BrowserMediaSource.ID?

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// VoiceOver doesn't hover, so it gets the whole stack at all times.
	@Environment(\.accessibilityVoiceOverEnabled)
	private var voiceOver

	/// About three and a half resting rows, so a cut row hints that the stack scrolls.
	private static var maxHeight: CGFloat { 140 }

	private static var spacing: CGFloat { 4 }

	public init(
		ids: [BrowserMediaSource.ID],
		restingID: BrowserMediaSource.ID,
		@ViewBuilder row: @escaping (BrowserMediaSource.ID) -> Row
	) {
		self.ids = ids
		self.restingID = restingID
		self.row = row
		self._isPointerInside = .init(initialValue: false)
		self._contentHeight = .init(initialValue: 0)
		self._scrolledID = .init(initialValue: restingID)
	}

	public var body: some View {
		ScrollView(.vertical) {
			VStack(spacing: Self.spacing) {
				ForEach(shownIDs, id: \.self) { id in
					row(id)
						.transition(.opacity)
				}
			}
			.scrollTargetLayout()
			.onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
				withAnimation(animation) { contentHeight = height }
			}
		}
		.scrollDisabled(contentHeight <= Self.maxHeight)
		.scrollBounceBehavior(.basedOnSize)
		.defaultScrollAnchor(.bottom)

		// A long stack opens scrolled to the resting row, so the rows that arrive go around it
		// rather than under the pointer.
		.scrollPosition(id: $scrolledID, anchor: .bottom)
		.onChange(of: hovered) { scrolledID = restingID }
		.frame(height: min(max(contentHeight, 1), Self.maxHeight))
		.clipped()
		.onHover { isHovered in
			withAnimation(animation) { isPointerInside = isHovered }
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.media.stack))
	}

	private var hovered: Bool {
		hoverOverride ?? isPointerInside
	}

	/// The resting item alone, or every item while the stack is hovered or VoiceOver is on.
	private var shownIDs: [BrowserMediaSource.ID] {
		guard !hovered, !voiceOver, ids.contains(restingID) else { return ids }
		return [restingID]
	}

	private var animation: Animation? {
		reduceMotion ? nil : .snappy(duration: 0.2)
	}
}

extension EnvironmentValues {
	/// Holds the sidebar's media stack expanded, or not, whatever the pointer does, for offscreen
	/// snapshots. Nil follows the pointer.
	@Entry
	internal var sidebarMediaStackHover: Bool? = nil

	/// Holds the stack's rows hovered, or not, the same way.
	@Entry
	internal var sidebarMediaHover: Bool? = nil
}
