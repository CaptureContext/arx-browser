import AppUI
import SidebarFeature
import SwiftUI
import _ComposableArchitecture

/// The sidebar's notice (`sidebar.notice`) as a toast at the top-right corner over the page,
/// below the copy-link result when that shows too. ``SidebarNotices`` times it.
internal struct SidebarNoticeToast: ViewModifier {
	internal let store: StoreOf<MainFeature>

	internal init(store: StoreOf<MainFeature>) {
		self.store = store
	}

	internal func body(content: Content) -> some View {
		let notice: SidebarNotice? = store.sidebar.notice
		content.arxToast(
			isPresented: notice != nil,
			topInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
			trailingInset: BrowserMetrics.PageCard.inset + ArxToastMetrics.edgeInset,
			onHover: { store.send(.ui(.noticeHovered($0))) }
		) {
			if let notice {
				ArxToast(notice.text, systemImage: "exclamationmark.circle")

					// Notices are whole sentences: they wrap instead of spanning the page.
					.frame(maxWidth: ArxToastMetrics.maximumWidth, alignment: .trailing)

					// Again for each notice, even the same text again, so it gets its full time.
					.task(id: notice.id) { store.send(.ui(.noticeShown(notice.id))) }

					// A replacement keeps the toast, and its hover; only leaving the window ends it.
					.onDisappear { store.send(.ui(.noticeRemoved(notice.id))) }
			}
		}
	}
}
