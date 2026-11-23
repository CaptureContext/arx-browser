import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import MainFeature
import PeekFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct NativeContentsPresentationTests {
	@Test(arguments: [false, true])
	internal func revokedInitialOptionsClosesOnlyItsLittleArxAndRestoresFocus(metadataChanged: Bool) throws {
		var (state, child) = fixture(disposition: .window)
		let offer = optionsOffer(child.tab)
		let viewer = state.main.viewer
		let workspace = state.workspace
		state.focusedWindowID = UUID(999)
		applyOptions(offer, to: &state)
		let littleID = try #require(state.littleWindows.last?.id)

		if metadataChanged {
			state.littleWindows[id: littleID]?.tab.restoration.title = "Loaded options"
		}

		_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.extensionOptionsRevoked(offer)))

		#expect(state.littleWindows.isEmpty)
		#expect(state.focusedWindowID == UUID(999))
		#expect(state.initialExtensionOptions.isEmpty)
		expectNoDifference(state.workspace, workspace)
		expectNoDifference(state.main.viewer, viewer)

		let settled = state
		_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.extensionOptionsRevoked(offer)))
		expectNoDifference(state, settled)
	}

	@Test(arguments: ["settled", "profile", "extension", "repurposed"])
	internal func rollbackCannotRemoveAnUnrelatedOrSettledOptionsSession(caseName: String) throws {
		var (state, child) = fixture(disposition: .window)
		let offer = optionsOffer(child.tab)
		applyOptions(offer, to: &state)
		let littleID = try #require(state.littleWindows.last?.id)

		if caseName == "settled" {
			_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.extensionOptionsSettled(offer)))
		}
		if caseName == "repurposed" {
			state.littleWindows[id: littleID]?.tab.restoration.url = URL(string: "https://replacement.example/")!
		}

		var before = state
		let revoked = BrowserExtensionViewOffer(
			profileID: caseName == "profile" ? .init(rawValue: UUID(999)) : offer.profileID,
			extensionID: caseName == "extension" ? String(repeating: "b", count: 32) : offer.extensionID,
			tab: offer.tab
		)
		_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.extensionOptionsRevoked(revoked)))

		// A repurposed page loses its rollback authority, and its Little Arx stays.
		if caseName == "repurposed" { before.initialExtensionOptions = [:] }
		expectNoDifference(state, before)
	}

	@Test
	internal func rollbackKeepsALittleArxThatNoLongerShowsTheOptions() throws {
		var (state, child) = fixture(disposition: .window)
		let offer = optionsOffer(child.tab)
		let original = state.workspace.tabs[0]
		applyOptions(offer, to: &state)
		let littleID = try #require(state.littleWindows.last?.id)
		state.littleWindows[id: littleID]?.tab = original

		_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.extensionOptionsRevoked(offer)))

		#expect(state.littleWindows[id: littleID]?.tab.id == original.id)
		#expect(state.initialExtensionOptions.isEmpty)
	}

	@Test
	internal func extensionOptionsOpenInLittleArxOnTheirProfilesSpace() throws {
		var (state, child) = fixture(disposition: .window)
		let offer = optionsOffer(child.tab)
		let viewer = state.main.viewer
		let workspace = state.workspace
		let windows = state.windows
		state.focusedWindowID = UUID(999)
		applyOptions(offer, to: &state)

		let little = try #require(state.littleWindows.last)
		#expect(state.littleWindows.count == 1)
		#expect(little.tab == offer.tab)
		#expect(little.spaceID == state.workspace.spaces[0].id)
		#expect(!little.isCommandOnly)
		#expect(state.focusedWindowID == little.id)
		#expect(state.initialExtensionOptions[offer.tab.id]?.windowID == little.id)
		#expect(state.initialExtensionOptions[offer.tab.id]?.previousFocus == UUID(999))
		// Nothing goes into a space, and no window opens for it (DEV-1185).
		expectNoDifference(state.workspace, workspace)
		expectNoDifference(state.windows, windows)
		expectNoDifference(state.main.viewer, viewer)
	}

	@Test
	internal func extensionOptionsOpenOnTheFocusedWindowsSpaceInTheirProfile() throws {
		var (state, child) = fixture(disposition: .window)
		let offer = optionsOffer(child.tab)
		let second = state.workspace.spaces[1].id
		state.main.sidebar.selectSpace(second)
		state.focusedWindowID = state.main.id
		applyOptions(offer, to: &state)

		let little = try #require(state.littleWindows.last)
		#expect(little.spaceID == second)
		#expect(state.focusedWindowID == little.id)
	}

	@Test(arguments: ["profile", "origin", "child", "quit", "duplicate", "little"])
	internal func refusedOptionsCannotLeaveAnyWindowOrOrganizationRow(failure: String) {
		var (state, child) = fixture(disposition: .window)
		let tab = optionsOffer(child.tab).tab

		if failure == "quit" { state.shouldQuit = true }
		if failure == "duplicate" { state.workspace.tabs.append(tab) }
		if failure == "little" {
			state.littleWindows.append(.init(id: UUID(500), spaceID: state.workspace.spaces[0].id, tab: tab))
		}

		let offer = BrowserExtensionViewOffer(
			profileID: failure == "profile" ? .init(rawValue: UUID(999)) : tab.profileID,
			extensionID: String(repeating: failure == "origin" ? "b" : "a", count: 32),
			tab: tab
		)
		let before = state
		applyOptions(offer, to: &state, missingChild: failure == "child")
		expectNoDifference(state, before)
	}

	/// A Little Arx's children go to a new Little Arx instead (LittleArxLinkRoutingTests).
	@Test
	internal func backgroundChildPreservesItsOpenerDespiteFocusChanging() throws {
		var (state, offer) = fixture(disposition: .backgroundTab)
		state.focusedWindowID = UUID(999)
		let main = state.main.viewer
		let little = state.littleWindows
		let windows = state.windows
		apply(offer, to: &state)

		#expect(state.workspace.tabs.contains(offer.tab))
		#expect(state.workspace.spaces[0].unpinnedTabs.contains(offer.tab.id))
		expectNoDifference(state.main.viewer, main)
		expectNoDifference(state.littleWindows, little)
		expectNoDifference(state.windows, windows)
		expectNoDifference(state.focusedWindowID, UUID(999))
		expectNoDifference(state.unsavedOrganization, state.workspace)
		try state.workspace.validate()
	}

	/// Shift-click asks Chromium for a new window: that one is still a window. A page's popup isn't
	/// (DEV-1186).
	@Test
	internal func nativeChildGetsItsOwnWindowWithoutReplacingOpener() throws {
		var (state, offer) = fixture(disposition: .window)
		let main = state.main.viewer
		apply(offer, to: &state)

		let childHost = try #require(state.windows.last)
		#expect(childHost.sidebar.selectedTab?.id == offer.tab.id)
		#expect(childHost.sidebar.space.profileID == offer.tab.profileID)
		#expect(state.focusedWindowID == childHost.id)
		expectNoDifference(state.main.viewer, main)
		try state.workspace.validate()
	}

	/// A page's popup, as "Sign in with Google" opens, goes into a new Little Arx from a window,
	/// another window or Peek (DEV-1186): never a new main window or a tab in the space. It's the
	/// engine's own page, so `window.opener` and `postMessage` still reach the source, and the
	/// keyboard goes back to the source's window when the popup closes itself.
	@Test(arguments: PopupSource.allCases)
	internal func aPopupOpensInANewLittleArxWithItsOpener(from source: PopupSource) throws {
		var (state, offer) = fixture(disposition: .popup)
		let opener: UUID
		switch source {
		case .mainWindow:
			opener = state.main.id

		case .otherWindow:
			var window = MainFeature.State(
				organization: state.workspace,
				spaceID: state.workspace.spaces[0].id,
				id: UUID(71)
			)
			window.viewer.item.tab = state.main.viewer.item.tab
			state.main.viewer.item.tab = nil
			state.windows.append(window)
			opener = window.id

		case .peek:
			let page = BrowserCore.Tab(
				id: .init(rawValue: UUID(72)),
				profileID: offer.tab.profileID,
				restoration: .init(title: "Peek", url: URL(string: "https://peek.example/")!)
			)
			var peek = PeekFeature.State(
				id: UUID(73),
				source: .init(
					windowID: state.main.id,
					paneID: state.main.viewer.activePaneID,
					tabID: state.main.viewer.item.tab?.id,
					spaceID: state.main.sidebar.spaceID,
					profileID: offer.tab.profileID,
					identity: "Peek"
				),
				tab: page,
				isTemporary: true
			)
			peek.viewer.tab = page
			state.peeks.append(peek)
			offer = .init(
				sourceTabID: page.id,
				sourceSessionRevision: offer.sourceSessionRevision,
				sourceDocumentRevision: offer.sourceDocumentRevision,
				tab: offer.tab,
				disposition: .popup
			)
			opener = state.main.id
		}
		state.focusedWindowID = opener
		let before = state
		apply(offer, to: &state)

		let little = try #require(state.littleWindows.first)
		#expect(state.littleWindows.count == 1)
		expectNoDifference(little.tab, offer.tab)
		expectNoDifference(little.openerWindowID, opener)
		expectNoDifference(little.spaceID, state.workspace.spaces[0].id)
		#expect(!little.isCommandOnly)
		expectNoDifference(state.focusedWindowID, little.id)
		expectNoDifference(state.workspace, before.workspace)
		#expect(state.unsavedOrganization == nil)
		expectNoDifference(state.main, before.main)
		expectNoDifference(state.windows, before.windows)
		expectNoDifference(state.peeks, before.peeks)

		// It closes itself: the source's window takes the keyboard back while it's open. Closing
		// removes the Little Arx before asking, as `LittleArxWindows` does.
		state.littleWindows.remove(id: little.id)
		expectNoDifference(state.focusAfterClosingLittleArx(little), opener)

		// Not when it's on another macOS desktop Space: that would switch Spaces (DEV-931).
		_ = LittleArxWindows()._reduce(
			into: &state,
			action: .event(.desktopSpaceChanged(littleWindowsElsewhere: [], windowsElsewhere: [opener, UUID(404)]))
		)
		expectNoDifference(state.windowsOnOtherDesktopSpaces, [opener])
		expectNoDifference(state.focusAfterClosingLittleArx(little), nil)
		_ = LittleArxWindows()._reduce(into: &state, action: .event(.desktopSpaceChanged(littleWindowsElsewhere: [])))
		expectNoDifference(state.focusAfterClosingLittleArx(little), opener)
		if opener == state.main.id {
			state.windowIsOpen = false
		} else {
			state.windows.remove(id: opener)
		}
		expectNoDifference(state.focusAfterClosingLittleArx(little), nil)
	}

	internal enum PopupSource: CaseIterable, Sendable {
		case mainWindow
		case otherWindow
		case peek
	}

	@Test(arguments: [BrowserNewContents.Disposition.popup, .window, .foregroundTab, .backgroundTab])
	internal func privateChildrenStayEphemeralAndKeepTheOriginalContext(disposition: BrowserNewContents.Disposition) throws {
		var (state, ordinaryOffer) = fixture(disposition: disposition)
		var source = MainFeature.State(
			organization: state.workspace,
			spaceID: state.workspace.spaces[0].id,
			isPrivate: true,
			id: UUID(70)
		)
		source.privateOpenerProfileID = state.workspace.profiles[0].id
		source.viewer.item.tab = state.workspace.tabs[0]
		state.main.viewer.item.tab = nil
		state.windows.append(source)
		let offer = BrowserNewContents(
			sourceTabID: ordinaryOffer.sourceTabID,
			sourceSessionRevision: ordinaryOffer.sourceSessionRevision,
			sourceDocumentRevision: ordinaryOffer.sourceDocumentRevision,
			tab: ordinaryOffer.tab,
			disposition: disposition,
			isPrivate: true
		)
		let workspace = state.workspace
		let originalViewer = source.viewer
		apply(offer, to: &state)

		expectNoDifference(state.workspace, workspace)
		#expect(state.unsavedOrganization == nil)
		expectNoDifference(state.windows[id: source.id]?.viewer, originalViewer)
		let owner = try #require(state.windows.first(where: { $0.sidebar.organization.tabs.contains(offer.tab) }))
		#expect(owner.isPrivate)
		#expect(owner.sidebar.space.profileID == offer.tab.profileID)
		// DEV-956: a child window shares the context, so it shows the same opener's extensions.
		#expect(owner.privateOpenerProfileID == state.workspace.profiles[0].id)
		if disposition == .popup || disposition == .window {
			#expect(owner.id != source.id)
			#expect(owner.sidebar.organization.tabs == [offer.tab])
		} else {
			#expect(owner.id == source.id)
		}
	}

	@Test(arguments: ["session", "document", "child", "profile", "closed", "ambiguous", "duplicate"])
	internal func refusedOfferCannotLeaveAnOrganizationOrWindowRow(failure: String) {
		var (state, offer) = fixture(disposition: .popup)

		switch failure {
		case "profile":
			state.main.viewer.item.tab = .init(
				id: offer.sourceTabID,
				profileID: .init(rawValue: UUID(88)),
				restoration: offer.tab.restoration
			)

		case "closed":
			state.windowIsOpen = false

		case "ambiguous":
			var second = MainFeature.State(
				organization: state.workspace,
				spaceID: state.workspace.spaces[0].id,
				id: UUID(89)
			)
			second.viewer.item.tab = state.main.viewer.item.tab
			state.windows.append(second)

		case "duplicate":
			state.workspace.tabs.append(offer.tab)

		default:
			break
		}

		let before = state
		apply(offer, to: &state, failure: failure)
		expectNoDifference(state, before)
	}

	private func optionsOffer(_ tab: BrowserCore.Tab) -> BrowserExtensionViewOffer {
		var tab = tab
		tab.restoration = .init(
			title: "Extension options",
			url: URL(string: "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/options.html")!
		)
		return .init(
			profileID: tab.profileID,
			extensionID: String(repeating: "a", count: 32),
			tab: tab
		)
	}

	private func applyOptions(
		_ offer: BrowserExtensionViewOffer,
		to state: inout AppFeature.State,
		missingChild: Bool = false
	) {
		withDependencies {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				id == offer.tab.id && !missingChild ? .init(navigation: .init(), revision: 1) : nil
			}
		} operation: {
			_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.extensionViewCreated(offer)))
		}
	}

	private func fixture(disposition: BrowserNewContents.Disposition) -> (AppFeature.State, BrowserNewContents) {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(
			main: .init(
				organization: organization,
				spaceID: organization.spaces[0].id
			)
		)
		state.main.viewer.item.tab = organization.tabs[0]
		let offer = BrowserNewContents(
			sourceTabID: organization.tabs[0].id,
			sourceSessionRevision: 3,
			sourceDocumentRevision: 7,
			tab: .init(
				id: .init(rawValue: UUID(90)),
				profileID: organization.tabs[0].profileID,
				restoration: .init(title: "Native child", url: URL(string: "https://child.example/")!)
			),
			disposition: disposition
		)
		return (state, offer)
	}

	private func apply(
		_ offer: BrowserNewContents,
		to state: inout AppFeature.State,
		failure: String = ""
	) {
		withDependencies {
			$0.uuid = .incrementing
			$0.browserEngine.snapshot = { id in
				if id == offer.sourceTabID {
					return .init(
						navigation: .init(),
						revision: failure == "session" ? 4 : 3,
						documentRevision: failure == "document" ? 8 : 7
					)
				}

				return id == offer.tab.id && failure != "child" ? .init(navigation: .init(), revision: 1) : nil
			}
		} operation: {
			_ = NativeContentsPresentation()._reduce(into: &state, action: .event(.browserNewContents(offer)))
		}
	}
}
