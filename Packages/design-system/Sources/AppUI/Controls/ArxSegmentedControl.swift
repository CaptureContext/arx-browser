import SwiftUI

/// One segment of an ``ArxSegmentedControl``: an icon, with its title as the tooltip and what
/// VoiceOver reads, or its title as a text label, with a tooltip only when it has a hint.
public struct ArxSegment<Value: Hashable>: Identifiable {
	public let value: Value
	public let title: String
	public let systemImage: String?
	public let hint: String?

	public var id: Value { value }

	/// An icon segment: `title` is its tooltip and what VoiceOver reads.
	public init(
		_ value: Value,
		title: String,
		systemImage: String
	) {
		self.value = value
		self.title = title
		self.systemImage = systemImage
		self.hint = nil
	}

	/// A text segment, labeled with `title` (DEV-1308). `hint` is its tooltip and VoiceOver's
	/// hint, for a segment that needs a word more than its name; without one it shows no tooltip,
	/// since its label already says what it is.
	public init(
		_ value: Value,
		title: String,
		hint: String? = nil
	) {
		self.value = value
		self.title = title
		self.systemImage = nil
		self.hint = hint
	}

	/// What the tooltip under the segment says, if anything.
	internal var tooltip: String? {
		systemImage == nil ? hint : title
	}
}

/// A switcher of segments (DEV-797): a glassy squircle
/// container whose selected segment is a darker inset squircle, which stays while it's the
/// selection. A segment is an icon, whose title shows in a small tooltip under it on hover, or a
/// text label, such as Send Feedback's kinds (DEV-1308), which shows a tooltip only for a hint.
///
/// The tooltip hangs below the control over whatever's there, so give the row holding it a
/// `zIndex` above the views under it.
///
/// ```swift
/// ArxSegmentedControl(
///     [
///         ArxSegment(.all, title: "All", systemImage: "tray"),
///         ArxSegment(.archived, title: "Archived", systemImage: "archivebox"),
///     ],
///     selection: $filter
/// )
///
/// ArxSegmentedControl(
///     [
///         ArxSegment(.bug, title: "Bug Report"),
///         ArxSegment(.vulnerability, title: "Vulnerability", hint: "Marked urgent and kept private"),
///     ],
///     selection: $kind
/// )
/// ```
public struct ArxSegmentedControl<Value: Hashable>: View {
	private let segments: [ArxSegment<Value>]
	private let selection: Value
	private let select: (Value) -> Void

	@SwiftUI.State
	private var hovered: Value?

	@SwiftUI.State
	private var tooltip: Value?

	/// `select` runs when a segment is clicked, for a selection kept elsewhere, such as a store.
	public init(
		_ segments: [ArxSegment<Value>],
		selection: Value,
		select: @escaping (Value) -> Void
	) {
		self.init(segments, selection: selection, tooltip: nil, select: select)
	}

	public init(
		_ segments: [ArxSegment<Value>],
		selection: Binding<Value>
	) {
		self.init(segments, selection: selection.wrappedValue) { selection.wrappedValue = $0 }
	}

	/// `tooltip` shows that segment's tooltip from the start, as a snapshot does.
	internal init(
		_ segments: [ArxSegment<Value>],
		selection: Value,
		tooltip: Value?,
		select: @escaping (Value) -> Void
	) {
		self.segments = segments
		self.selection = selection
		self.select = select
		self._tooltip = .init(initialValue: tooltip)
	}

	public var body: some View {
		ArxRaisedGroup {
			ForEach(segments) { segment in
				let isSelected = segment.value == selection
				Button { select(segment.value) } label: {
					label(segment)
				}
				.buttonStyle(.arxRaised(.item, isSelected: isSelected, isSquare: segment.systemImage != nil))
				.focusEffectDisabled()
				.accessibilityLabel(Text(verbatim: segment.title))
				.accessibilityHint(segment.hint.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
				.accessibilityAddTraits(isSelected ? .isSelected : [])
				.onHover { isHovering in
					if isHovering, segment.tooltip != nil {
						hovered = segment.value
					} else if hovered == segment.value {
						hovered = nil
					}
				}
				.overlay(alignment: tooltipAlignment(segment)) {
					if tooltip == segment.value, let text = segment.tooltip {
						ArxTooltip(text)

							// Its top edge sits a little below the control's bottom edge.
							.offset(y: ArxTooltip.offset)
							.transition(.opacity)
					}
				}
			}
		}
		.arxTooltipTiming(hovered: hovered, tooltip: $tooltip)
	}

	@ViewBuilder
	private func label(_ segment: ArxSegment<Value>) -> some View {
		if let systemImage = segment.systemImage {
			Image(systemName: systemImage)
		} else {
			// A text label leaves the room a button's text has inside its fill.
			Text(verbatim: segment.title)
				.padding(.horizontal, ArxSegmentMetrics.textPadding)
		}
	}

	/// The end segments' tooltips line up with the control's edge, so they never reach past it;
	/// the others center under their segment.
	private func tooltipAlignment(_ segment: ArxSegment<Value>) -> Alignment {
		ArxTooltip.alignment(
			index: segments.firstIndex { $0.value == segment.value } ?? 0,
			count: segments.count
		)
	}
}

internal enum ArxSegmentMetrics {
	/// Added to a raised item's own padding on each side of a text label.
	internal static let textPadding: CGFloat = 6
}
