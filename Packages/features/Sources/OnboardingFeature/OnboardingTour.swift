import _ComposableArchitecture

/// The tour: short pages for Peek, Split View, the command bar, chats and Little Arx, each with a
/// looping demo.
///
/// The demos play on their own timelines in the view, so this feature only knows which page
/// is showing. OnboardingFeature moves through the pages with Continue and Back, and the step
/// counts as finished once Continue leaves the last one. Skip leaves the whole tour.
@Reducer
public struct OnboardingTour {
	@ObservableState
	public struct State: Equatable, Sendable {
		/// The tour's pages, in order.
		public var pages: [Page]

		/// The index of the visible page in `pages`.
		public var index: Int

		public init(
			pages: [Page] = Page.allCases,
			index: Int = 0
		) {
			self.pages = pages
			self.index = index
		}

		/// The visible page.
		public var page: Page? {
			pages.indices.contains(index) ? pages[index] : nil
		}

		public var isOnFirstPage: Bool { index <= 0 }

		public var isOnLastPage: Bool { index >= pages.count - 1 }

		/// Shows the next page, or returns `false` on the last one.
		public mutating func showNext() -> Bool {
			guard !isOnLastPage else { return false }

			index += 1
			return true
		}

		/// Shows the previous page, or returns `false` on the first one.
		public mutating func showPrevious() -> Bool {
			guard !isOnFirstPage else { return false }

			index -= 1
			return true
		}

		/// Shows the last page, for coming back to the tour from the step after it.
		public mutating func showLast() {
			index = max(0, pages.count - 1)
		}
	}

	/// A tour page, named after the part of Arx its demo shows.
	public enum Page: String, CaseIterable, Equatable, Sendable {
		case peek
		case splitView
		case commandBar
		case chats
		case littleArx
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {}

		@CasePathable
		public enum Event: Sendable {}

		@CasePathable
		public enum Delegate: Sendable {}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		EmptyReducer()
	}
}
