import AppUI
import BrowserCore
import CustomDump
import Testing

/// Copy ▸'s short titles (DEV-1162): the submenu already says "Copy".
internal struct LinkCopyMenuTitleTests {
	@Test
	internal func aPinnedTabsCopyMenuReadsShort() {
		let sections = LinkCopyMenu.sections(modes: LinkCopyMode.allCases, offersSavedLink: true, sharesProxy: true)

		expectNoDifference(sections.map { $0.map { $0.copyMenuTitle() } }, [
			["Link", "Clean Link", "Markdown", "Proxy Link", "Markdown (Proxy Link)", "Saved Link"],
			["Share Proxy Link"],
		])
	}

	/// Several selected tabs copy all their links; a row's saved address is its own tab's.
	@Test
	internal func severalTabsCountTheirLinks() {
		expectNoDifference(LinkCopyMenu.Item.copy(.original).copyMenuTitle(tabCount: 3), "3 Links")
		expectNoDifference(LinkCopyMenu.Item.copy(.clean).copyMenuTitle(tabCount: 3), "Clean Link")
		expectNoDifference(LinkCopyMenu.Item.copySaved.copyMenuTitle(tabCount: 2, isSavedForTab: true), "Saved Link for This Tab")
	}
}
