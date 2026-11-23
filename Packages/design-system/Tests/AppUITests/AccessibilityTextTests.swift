@testable import AppUI
import Foundation
import Testing

internal struct AccessibilityTextTests {
	private let tab: SidebarItem = .init(id: .tab(UUID()), title: "Docs")
	private let folder: SidebarItem = .init(id: .folder(UUID()), title: "Work", isExpanded: true)

	@Test
	internal func aTabSaysWhetherItIsSelected() {
		#expect(tab.accessibilityValue(isSelected: false, depth: 0) == String.localized(.appUI.sidebar.tab))
		#expect(tab.accessibilityValue(isSelected: true, depth: 0) == String.localized(.appUI.sidebar.selectedTab))
	}

	@Test
	internal func aFolderSaysWhetherItIsExpanded() {
		var collapsed = folder
		collapsed.isExpanded = false

		#expect(folder.accessibilityValue(isSelected: false, depth: 0) == String.localized(.appUI.sidebar.expandedFolder))
		#expect(collapsed.accessibilityValue(isSelected: true, depth: 0) == String.localized(.appUI.sidebar.collapsedFolder))
	}

	@Test
	internal func nestedRowsSayHowDeepTheyAre() {
		let top = tab.accessibilityValue(isSelected: false, depth: 0)
		let nested = tab.accessibilityValue(isSelected: false, depth: 1)
		let deeper = folder.accessibilityValue(isSelected: false, depth: 2)

		#expect(nested == String.localized(.appUI.sidebar.nestingLevel(String.localized(.appUI.sidebar.tab), 2)))
		#expect(deeper == String.localized(.appUI.sidebar.nestingLevel(String.localized(.appUI.sidebar.expandedFolder), 3)))
		#expect(Set([top, nested, deeper]).count == 3)
	}

	@Test
	internal func aResultNamesWhatReturnDoes() {
		let result = CommandBarResult(id: "1", title: "Docs", actionTitle: "Switch to Tab", symbol: "globe")

		#expect(result.accessibilityLabel == String.localized(.appUI.command.resultAccessibility("Docs", "Switch to Tab")))
		#expect(result.accessibilityLabel.contains("Docs"))
		#expect(result.accessibilityLabel.contains("Switch to Tab"))
	}
}
