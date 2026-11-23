@testable import AppFeature
import AppUI
import CoreGraphics
import CustomDump
import Testing

/// Toasts at a window's top-right corner, such as the sidebar's notice, stack below the link
/// toast (DEV-777): the window's own, or a split view pane's that reaches into that corner.
@Suite(.dependencies)
@MainActor
internal struct ToastStackingTests {
	private let width: CGFloat = 1_000
	private let inset: CGFloat = 24

	@Test
	internal func theCornersOwnToastPushesTheNoticeBelowItsHeight() {
		let offset = LinkFeedbackToast.cornerStackOffset(
			ownToast: .init(x: 800, y: inset, width: 176, height: 52),
			paneToast: .init(x: 800, y: 60, width: 176, height: 40),
			contentWidth: width,
			topInset: inset,
			trailingInset: inset
		)
		expectNoDifference(offset, 52 + ArxToastMetrics.stackSpacing)
	}

	@Test
	internal func aTopRightPaneToastPushesTheNoticeBelowItsBottomEdge() {
		// Under the pane's 30 pt header: from 52 to 92 in the window.
		let pane: CGRect = .init(x: 780, y: 52, width: 182, height: 40)
		let offset = LinkFeedbackToast.cornerStackOffset(
			ownToast: nil,
			paneToast: pane,
			contentWidth: width,
			topInset: inset,
			trailingInset: inset
		)
		expectNoDifference(offset, pane.maxY + ArxToastMetrics.stackSpacing - inset)

		// The notice's top then sits below the pane toast's bottom.
		#expect(inset + offset > pane.maxY)
	}

	@Test
	internal func paneToastsAwayFromTheCornerLeaveTheNoticeInPlace() {
		// The left pane's toast, short of where a notice can reach.
		let left = LinkFeedbackToast.cornerStackOffset(
			ownToast: nil,
			paneToast: .init(x: 300, y: 52, width: 182, height: 40),
			contentWidth: width,
			topInset: inset,
			trailingInset: inset
		)

		// The bottom pane's toast in a stacked split.
		let bottom = LinkFeedbackToast.cornerStackOffset(
			ownToast: nil,
			paneToast: .init(x: 780, y: 420, width: 182, height: 40),
			contentWidth: width,
			topInset: inset,
			trailingInset: inset
		)
		let none = LinkFeedbackToast.cornerStackOffset(
			ownToast: nil,
			paneToast: nil,
			contentWidth: width,
			topInset: inset,
			trailingInset: inset
		)
		expectNoDifference([left, bottom, none], [0, 0, 0])
	}
}
