import AgentClient
import BrowserCore
import Foundation
import Testing

@testable import ChatFeature

/// DEV-760: the panel's chat list filters and month sections, and where the + menu lists each
/// tab or folder.
internal struct ChatPanelPartsTests {
	@Test
	internal func aListFilterIsReachedByToggling() {
		var state = ChatFeature.State(id: ChatWorld.profileID)
		#expect(ChatListFilter(state) == .all)
		for target in [ChatListFilter.unread, .archived, .all, .archived, .unread, .all] {
			for action in target.actions(from: ChatListFilter(state)) {
				switch action {
				case .unreadOnlyToggled: state.showsUnreadOnly.toggle()
				case .archivedToggled: state.showsArchived.toggle()
				default: Issue.record("unexpected \(action)")
				}
			}
			#expect(ChatListFilter(state) == target)
			#expect(!(state.showsUnreadOnly && state.showsArchived))
		}
	}

	@Test
	internal func theTimelineGroupsByWeekMonthAndCalendarMonth() throws {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
		calendar.locale = Locale(identifier: "en_US")
		let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12)))
		let day: TimeInterval = 24 * 60 * 60
		let ages: [TimeInterval] = [0.1, 2, 6, 20, 45, 50, 120, 400]
		let conversations = ages.enumerated().map { index, age in
			AgentConversation(
				id: .init(rawValue: UUID(index)),
				profileID: ChatWorld.profileID,
				provider: .claude,
				title: "\(index)",
				createdAt: now.addingTimeInterval(-age * day),
				updatedAt: now.addingTimeInterval(-age * day)
			)
		}
		let sections = ChatTimelineSection.sections(conversations.reversed(), now: now, calendar: calendar)
		#expect(sections.map { $0.conversations.map(\.title) } == [["0"], ["1", "2"], ["3"], ["4", "5"], ["6"], ["7"]])
		#expect(sections.prefix(3).map(\.period) == [.today, .week, .month])
		#expect(sections[3].title == "September")
		#expect(sections[4].title == "July")
		#expect(sections[5].title.contains("2025"))
	}

	@Test
	internal func attachablesSortIntoTheTabFoldersAndTabs() {
		let tab = AgentContextAttachment.Tab(title: "A", url: "https://a.example")
		#expect(ChatAttachable(id: ChatAttachable.currentID, title: "A", symbol: "macwindow", tabs: [tab]).kind == .current)
		#expect(ChatAttachable(id: "f", title: "Folder", symbol: "folder", tabs: [tab]).kind == .folder)
		#expect(ChatAttachable(id: "t", title: "A", symbol: "globe", tabs: [tab]).kind == .tab)
	}
}
