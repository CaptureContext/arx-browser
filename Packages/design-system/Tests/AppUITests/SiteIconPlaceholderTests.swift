import AppKit
@testable import AppUI
import Foundation
import Testing

/// Which icon a site tab draws (DEV-809): its favicon when there is one, the placeholder squircle
/// when a site tab has none, and the existing symbols everywhere else.
@MainActor
@Suite
internal struct SiteIconPlaceholderTests {
	private static let key: SidebarItem.SiteIcon = .init(
		profileID: UUID(),
		pageURL: URL(string: "https://capturecontext.dev")!
	)

	@Test
	internal func aSiteTabWithoutAnIconShowsThePlaceholder() {
		let content = FavoriteSiteIcon.Content(
			image: nil,
			key: Self.key,
			fallback: SidebarItem.siteSymbol,
			showsPlaceholder: true
		)
		#expect(content.kind == .placeholder)
	}

	@Test
	internal func aLiveOrStoredIconWinsOverThePlaceholder() {
		let content = FavoriteSiteIcon.Content(
			image: NSImage(size: .init(width: 16, height: 16)),
			key: Self.key,
			fallback: SidebarItem.siteSymbol,
			showsPlaceholder: true
		)
		#expect(content.kind == .image)
	}

	@Test
	internal func otherIconsKeepTheirSymbols() {
		let chat = FavoriteSiteIcon.Content(
			image: nil,
			key: nil,
			fallback: SidebarItem.assistantSymbol,
			showsPlaceholder: true
		)
		let noPage = FavoriteSiteIcon.Content(
			image: nil,
			key: nil,
			fallback: SidebarItem.siteSymbol,
			showsPlaceholder: true
		)
		let elsewhere = FavoriteSiteIcon.Content(
			image: nil,
			key: Self.key,
			fallback: SidebarItem.siteSymbol,
			showsPlaceholder: false
		)
		let folder = FavoriteSiteIcon.Content(
			image: nil,
			key: Self.key,
			fallback: "folder.fill",
			showsPlaceholder: true
		)
		#expect(chat.kind == .assistant)
		#expect(noPage.kind == .symbol)
		#expect(elsewhere.kind == .symbol)
		#expect(folder.kind == .symbol)
	}
}
