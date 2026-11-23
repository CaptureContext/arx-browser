import SwiftUI

/// The list rule in `.agents/DESIGN.md` › Lists (DEV-1289), for the lists a highlight moves
/// through: the command bar's results, ⌘K's actions, the Runway's profiles and a folder card's tabs.
///
/// - Rows touch: the stack has no spacing, and the gap between two highlights is padding inside
///   each row, half of it above the highlight and half below (`arxListRow(gap:)`).
/// - The list's inset is padding on the scrolled content, inside the scroll view, so the first
///   and last rows keep it when the list is scrolled to its top or end.
/// - Scrolling to a row brings it in with the list's inset on both sides
///   (`arxListRowAnchor(_:top:bottom:)`), so no highlight is cut by the list's edge, and at the end
///   with the room a floating control reserves there.
internal enum ArxListLayout {
	/// The content padding at an end of a list whose highlight sits `inset` from the list's edge,
	/// in rows whose gap is `gap`: the row's own half gap makes up the rest.
	internal static func contentPadding(
		inset: CGFloat,
		gap: CGFloat
	) -> CGFloat {
		max(0, inset - gap / 2)
	}

	/// The room a control floating over a list's end takes: the last highlight stops above a
	/// control `height` tall, floating `floatingInset` in from the container's edge, by the
	/// control's own offset from the content the list sits on (`floatingGap`). `contentInset` is
	/// how far the list itself sits in from that edge, and `rowGap` the list's gap between rows.
	/// The command bar's Actions ⌘K: 36 + 12 + 8 − 4 − 1 = 51 (DEV-1318).
	internal static func floatingReserve(
		height: CGFloat,
		floatingInset: CGFloat,
		contentInset: CGFloat,
		rowGap: CGFloat
	) -> CGFloat {
		let gap = floatingGap(floatingInset: floatingInset, contentInset: contentInset)
		return max(0, height + floatingInset + gap - contentInset - rowGap / 2)
	}

	/// Between the last highlight and a floating control above it: as far as the control sits in
	/// from the content the list sits on, so the gaps above and below the control match
	/// (DEV-1318). The command bar's Actions ⌘K: 12 from the panel's edge, less its 4-point
	/// bezel, is 8.
	internal static func floatingGap(
		floatingInset: CGFloat,
		contentInset: CGFloat
	) -> CGFloat {
		max(0, floatingInset - contentInset)
	}
}

/// What `ScrollViewProxy.scrollTo` reaches for a list row: the frame `arxListRowAnchor(_:top:bottom:)`
/// draws around it. Its own type, so it never matches the row's `ForEach` identity, which is the
/// row's bare frame.
internal struct ArxListRowAnchor<ID: Hashable>: Hashable {
	internal let id: ID

	internal init(_ id: ID) {
		self.id = id
	}
}

extension ScrollViewProxy {
	/// Scrolls the list row `id` in whole, with the list's inset around it (DESIGN.md › Lists).
	internal func scrollToListRow(_ id: some Hashable) {
		scrollTo(ArxListRowAnchor(id))
	}
}

extension View {
	/// A list row whose highlight sits `gap / 2` in from its top and bottom, so rows stacked with
	/// no spacing keep their highlights `gap` apart.
	internal func arxListRow(gap: CGFloat) -> some View {
		padding(.vertical, gap / 2)
	}

	/// The row's anchor for `ScrollViewProxy.scrollToListRow`, a frame that reaches `top` above the
	/// row and `bottom` below it: the list's content padding at each end. Scrolling to the row then
	/// brings in its own padding and the list's inset with it, and at the end, the room a floating
	/// control reserves, so the control never covers a highlight the keyboard moved to.
	///
	/// Only for rows of a non-lazy stack: a lazy stack builds a row's background only once it
	/// shows, so a far row would have no identity to scroll to.
	internal func arxListRowAnchor(
		_ id: some Hashable,
		top: CGFloat,
		bottom: CGFloat
	) -> some View {
		background {
			Color.clear
				.id(ArxListRowAnchor(id))
				.padding(.top, -top)
				.padding(.bottom, -bottom)
				.allowsHitTesting(false)
				.accessibilityHidden(true)
		}
	}
}
