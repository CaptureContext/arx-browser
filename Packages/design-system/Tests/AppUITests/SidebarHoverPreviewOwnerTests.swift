@testable import AppUI
import Testing

/// DEV-1288: a window shows one hover preview at a time. Moving the hover from one row to another
/// closes the first preview before the second shows, and a preview in use gives way only to one
/// that has settled.
@MainActor
internal struct SidebarHoverPreviewOwnerTests {
	// MARK: - The rule

	@Test
	internal func aPreviewOverAnotherReplacesIt() {
		var exclusivity = SidebarHoverPreviewExclusivity<String>()
		#expect(exclusivity.request("folder A", isSettled: true) == .open(replacing: nil))
		#expect(exclusivity.request("folder B", isSettled: false) == .open(replacing: "folder A"))
		#expect(exclusivity.current == "folder B")
		#expect(exclusivity.request("folder B", isSettled: false) == .open(replacing: nil))
	}

	@Test
	internal func aHeldPreviewGivesWayOnlyToASettledOne() {
		var exclusivity = SidebarHoverPreviewExclusivity<String>()
		_ = exclusivity.request("folder A", isSettled: true)
		exclusivity.hold("folder A", true)

		// A pointer brushing a row opens its preview at once after another closed: not settled.
		#expect(exclusivity.request("tab", isSettled: false) == .refuse)
		#expect(exclusivity.current == "folder A")

		// Resting on the row for the whole hover delay, or Shift, settles it.
		#expect(exclusivity.request("tab", isSettled: true) == .open(replacing: "folder A"))
		#expect(exclusivity.current == "tab")
		#expect(!exclusivity.isHeld)
	}

	@Test
	internal func onlyTheCurrentPreviewHoldsOrReleases() {
		var exclusivity = SidebarHoverPreviewExclusivity<String>()
		_ = exclusivity.request("folder A", isSettled: true)
		_ = exclusivity.request("folder B", isSettled: true)

		// Folder A's late word, after B replaced it, changes nothing.
		exclusivity.hold("folder A", true)
		#expect(!exclusivity.isHeld)
		exclusivity.release("folder A")
		#expect(exclusivity.current == "folder B")

		exclusivity.hold("folder B", true)
		exclusivity.release("folder B")
		#expect(exclusivity.current == nil)
		#expect(!exclusivity.isHeld)
		#expect(exclusivity.request("tab", isSettled: false) == .open(replacing: nil))
	}

	@Test
	internal func onlyAWarmOpenIsUnsettled() {
		let interaction = SidebarInteractionConfiguration(shiftOpensPreviews: true)
		#expect(SidebarHoverPreviewDelay.isSettled(isShiftDown: false, isWarm: false, interaction: interaction))
		#expect(SidebarHoverPreviewDelay.isSettled(isShiftDown: true, isWarm: true, interaction: interaction))
		#expect(!SidebarHoverPreviewDelay.isSettled(isShiftDown: false, isWarm: true, interaction: interaction))
		#expect(!SidebarHoverPreviewDelay.isSettled(
			isShiftDown: true,
			isWarm: true,
			interaction: .init(shiftOpensPreviews: false)
		))
	}

	// MARK: - The owner

	/// Folder A, then folder B, then a tab, then a Favorite, then the Library's downloads:
	/// one preview on screen at every step, the old one gone before the new one shows.
	@Test
	internal func movingTheHoverShowsOnePreviewAtEveryStep() {
		let screen = Screen()
		let owner = SidebarHoverPreviewOwner()
		let previews = ["folder A", "folder B", "tab", "Favorite", "downloads"].map {
			Preview($0, screen: screen)
		}

		for (index, preview) in previews.enumerated() {
			// Opened at once, as right after another preview closed, without waiting for the first.
			#expect(preview.open(in: owner, isSettled: index == 0))
			#expect(screen.shown == [preview.name])
			#expect(screen.mostAtOnce == 1)
			#expect(owner.shown === preview)
		}
		#expect(previews.dropLast().allSatisfy { $0.wasEvicted })
		#expect(screen.mostAtOnce == 1)
	}

	@Test
	internal func aFolderInUseStaysUntilAnotherRowSettles() {
		let screen = Screen()
		let owner = SidebarHoverPreviewOwner()
		let folder = Preview("folder A", screen: screen)
		let tab = Preview("tab", screen: screen)

		#expect(folder.open(in: owner, isSettled: true))
		// Typing in its search, or the pointer on it, holds it.
		owner.hold(folder, true)

		#expect(!tab.open(in: owner, isSettled: false))
		#expect(screen.shown == ["folder A"])

		#expect(tab.open(in: owner, isSettled: true))
		#expect(screen.shown == ["tab"])
		#expect(folder.wasEvicted)
		#expect(screen.mostAtOnce == 1)
	}

	@Test
	internal func aClosedPreviewLeavesTheWindowFree() {
		let screen = Screen()
		let owner = SidebarHoverPreviewOwner()
		let folder = Preview("folder A", screen: screen)
		let tab = Preview("tab", screen: screen)

		#expect(folder.open(in: owner, isSettled: true))
		owner.hold(folder, true)
		folder.close(in: owner)

		#expect(owner.shown == nil)
		#expect(tab.open(in: owner, isSettled: false))
		#expect(!folder.wasEvicted)
	}

	@Test
	internal func aPreviewThatWentAwayHoldsNothing() {
		let screen = Screen()
		let owner = SidebarHoverPreviewOwner()
		var folder: Preview? = .init("folder A", screen: screen)
		#expect(folder?.open(in: owner, isSettled: true) == true)
		if let folder { owner.hold(folder, true) }
		folder = nil

		let tab = Preview("tab", screen: screen)
		#expect(tab.open(in: owner, isSettled: false))
	}
}

// MARK: - Doubles

/// What the window shows, and the most previews it ever showed at once.
@MainActor
private final class Screen {
	internal private(set) var shown: [String] = []
	internal private(set) var mostAtOnce: Int = 0

	internal func show(_ name: String) {
		shown.append(name)
		mostAtOnce = max(mostAtOnce, shown.count)
	}

	internal func hide(_ name: String) {
		shown.removeAll { $0 == name }
	}
}

/// A preview that orders itself in only once the owner lets it, as the hover panel does.
@MainActor
private final class Preview: SidebarHoverPreviewPresentation {
	internal let name: String
	internal private(set) var wasEvicted: Bool = false
	private let screen: Screen

	internal init(
		_ name: String,
		screen: Screen
	) {
		self.name = name
		self.screen = screen
	}

	internal func open(
		in owner: SidebarHoverPreviewOwner,
		isSettled: Bool
	) -> Bool {
		guard owner.request(self, isSettled: isSettled) else { return false }
		screen.show(name)
		return true
	}

	internal func close(in owner: SidebarHoverPreviewOwner) {
		owner.release(self)
		screen.hide(name)
	}

	internal func evict() {
		wasEvicted = true
		screen.hide(name)
	}
}
