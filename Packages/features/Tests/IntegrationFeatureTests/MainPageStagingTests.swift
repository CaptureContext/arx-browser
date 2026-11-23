import AppKit
import BrowserCore
import BrowserSurfaceClient
import CustomDump
import Foundation
@testable import MainFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// A press on a hovered tab gets its page ready on the stage over the page card, which stays
/// transparent: it never changes what the viewer shows (DEV-787). A hover alone stages
/// nothing, so Chromium never sees a merely hovered page as shown (DEV-941).
@MainActor
@Suite(.renderTurn, .dependencies, .serialized)
internal struct MainPageStagingTests {
	@Test
	internal func hoverAfterLandingOnASpaceShowingTheSameFavoriteNeverShowsTheStage() async throws {
		let organization = Self.organization(secondSpaceSelects: Self.favorite)
		let fixture = try Fixture(organization: organization)
		defer { fixture.close() }

		// A swipe lands on the other space, whose selected Favorite the card already shows.
		fixture.staging.reveal(organization.spaces[1].id.rawValue, isLanding: true)
		fixture.staging.spaceSelected(organization.spaces[1].id)
		#expect(fixture.stage.alphaValue == 0)

		fixture.staging.hover(Self.hovered.rawValue)
		fixture.staging.pressHoveredTab()
		try await fixture.waitUntilStaged(Self.hovered)
		#expect(fixture.stage.alphaValue == 0)

		// The engine keeps the hovered page on the stage a moment after the hover ends.
		fixture.staging.hover(nil)
		expectNoDifference(fixture.staged.last, .some(nil))
		#expect(fixture.stage.subviews.count == 1)
		#expect(fixture.stage.alphaValue == 0)
	}

	@Test
	internal func aLandingThatAnotherSelectionReplacedIsNotShownByALaterHover() async throws {
		let organization = Self.organization(secondSpaceSelects: Self.hovered)
		let fixture = try Fixture(organization: organization)
		defer { fixture.close() }

		// A swipe lands on the second space, then the first is selected again before any hover.
		fixture.staging.reveal(organization.spaces[1].id.rawValue, isLanding: true)
		#expect(fixture.stage.alphaValue == 1)
		fixture.staging.spaceSelected(organization.spaces[0].id)
		#expect(fixture.stage.alphaValue == 0)

		fixture.staging.hover(Self.hovered.rawValue)
		fixture.staging.pressHoveredTab()
		try await fixture.waitUntilStaged(Self.hovered)
		fixture.staging.hover(nil)
		#expect(fixture.stage.alphaValue == 0)
	}

	@Test
	internal func aHoverAloneStagesNothingUntilItsTabIsPressed() async throws {
		let fixture = try Fixture(organization: Self.organization(secondSpaceSelects: Self.favorite))
		defer { fixture.close() }

		// A sweep crosses tabs, and the pointer then rests on one: nothing is staged.
		fixture.staging.hover(Self.favorite.rawValue)
		fixture.staging.hover(Self.hovered.rawValue)
		try await Task.sleep(for: .milliseconds(200))
		expectNoDifference(fixture.staged.compactMap { $0 }, [])
		#expect(fixture.stage.subviews.isEmpty)

		fixture.staging.pressHoveredTab()
		let pressed = fixture.staged.count
		expectNoDifference(fixture.staged.last, .some(Self.hovered))

		// A press on the same tab again changes nothing; moving on lets the page go.
		fixture.staging.pressHoveredTab()
		#expect(fixture.staged.count == pressed)
		fixture.staging.hover(Self.favorite.rawValue)
		expectNoDifference(fixture.staged.last, .some(nil))
		fixture.staging.hover(nil)
		#expect(fixture.staged.count == pressed + 1)
	}

	@Test
	internal func onlyALandingPageTheCardHasNotTakenIsPresented() {
		let landing = BrowserCore.Tab.ID(rawValue: UUID(20))
		func staged(
			revealed: BrowserCore.Tab.ID?,
			isLanding: Bool,
			pressed: BrowserCore.Tab.ID?,
			isSplit: Bool = false
		) -> (id: BrowserCore.Tab.ID?, isPresented: Bool) {
			MainPageStaging.stagedTab(
				isSplit: isSplit,
				revealed: revealed,
				isLanding: isLanding,
				pressed: pressed,
				shown: Self.favorite
			)
		}

		#expect(staged(revealed: landing, isLanding: true, pressed: Self.hovered) == (landing, true))
		#expect(staged(revealed: landing, isLanding: false, pressed: Self.hovered) == (landing, false))
		#expect(staged(revealed: Self.favorite, isLanding: true, pressed: Self.hovered) == (Self.hovered, false))
		#expect(staged(revealed: Self.favorite, isLanding: true, pressed: nil) == (nil, false))
		#expect(staged(revealed: nil, isLanding: false, pressed: Self.hovered) == (Self.hovered, false))
		#expect(staged(revealed: nil, isLanding: false, pressed: Self.favorite) == (nil, false))
		#expect(staged(revealed: landing, isLanding: true, pressed: nil, isSplit: true) == (nil, false))
	}

	private static let favorite: BrowserCore.Tab.ID = .init(rawValue: UUID(3))
	private static let hovered: BrowserCore.Tab.ID = .init(rawValue: UUID(4))

	private static func organization(secondSpaceSelects selected: BrowserCore.Tab.ID) -> BrowserOrganization {
		var organization = IntegrationFeatureTests().fixture()
		organization.spaces[1].selectedTabID = selected
		return organization
	}
}

@MainActor
private final class Fixture {
	let store: StoreOf<MainFeature>
	let staging: MainPageStaging
	let window: NSWindow
	let stage: NSView
	private(set) var staged: [BrowserCore.Tab.ID?]
	private var pages: [BrowserCore.Tab.ID: NSView]

	init(organization: BrowserOrganization) throws {
		var state = MainFeature.State(organization: organization, spaceID: organization.spaces[0].id)
		state.viewer.item.tab = organization.tabs[0]
		let store = Store(initialState: state) { MainFeature() }
		self.store = store
		self.staged = []
		self.pages = [:]
		var host: NSView?
		var onStage: ((BrowserCore.Tab.ID?, NSView) -> Void)?
		let client = BrowserSurfaceClient(
			attach: { _, _ in },
			detach: { _ in },
			stage: { id, view in
				host = view
				onStage?(id, view)
			}
		)
		self.staging = .init(store: store, surface: client)
		self.window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 400, height: 300),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		let content = NSHostingView(rootView: MainPageStage(staging: staging))
		window.contentView = content
		content.layoutSubtreeIfNeeded()
		window.update()
		self.stage = try #require(host)
		onStage = { [unowned self] id, view in self.record(id, in: view) }
	}

	/// Like the engine: a page joins the stage at once and leaves it only later.
	private func record(
		_ id: BrowserCore.Tab.ID?,
		in view: NSView
	) {
		staged.append(id)
		guard let id, id != store.viewer.item.tab?.id else { return }
		let page = pages[id] ?? NSView()
		pages[id] = page
		if page.superview !== view { view.addSubview(page) }
	}

	func waitUntilStaged(_ id: BrowserCore.Tab.ID) async throws {
		await waitWhile { staged.last != .some(id) }
		expectNoDifference(staged.last, .some(id))
	}

	func close() {
		window.contentView = nil
		window.close()
	}
}
