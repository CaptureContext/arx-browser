import FeedbackFeature
import SettingsFeature
import SwiftUI
import _ComposableArchitecture

/// Puts Report a Problem on the main window as a sheet. Escape is Cancel.
internal struct ProblemReportSheetPresentation: ViewModifier {
	@Bindable
	private var store: StoreOf<AppFeature>

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	internal func body(content: Content) -> some View {
		content.sheet(
			isPresented: Binding(
				get: { store.problemReport != nil },
				set: { presented in
					if !presented, store.problemReport != nil {
						store.send(.problemReport(.ui(.close)))
					}
				}
			)
		) {
			if let child = store.scope(state: \.problemReport, action: \.problemReport) {
				ProblemReportView(store: child)
			}
		}
	}
}
