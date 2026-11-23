@testable import AppUI
import CustomDump
import Foundation
import Testing

/// What a split pane's header shows for a page (DEV-993): the whole address without its
/// scheme, split into the host, always shown, and the rest.
internal struct PaneAddressTests {
	@Test
	internal func aPageShowsItsHostThenEverythingAfterIt() {
		let url = URL(string: "https://rezka.ag/ua/films/drama/3311-babaduk-2014.html?season=1#player")!
		let (host, rest) = PaneAddress.parts(for: url)
		expectNoDifference(host, "rezka.ag")
		expectNoDifference(rest, "/ua/films/drama/3311-babaduk-2014.html?season=1#player")
	}

	@Test
	internal func aFrontPageIsItsHostAlone() {
		expectNoDifference(PaneAddress.parts(for: URL(string: "https://figma.com/")!).host, "figma.com")
		expectNoDifference(PaneAddress.parts(for: URL(string: "https://figma.com/")!).rest, "")
		expectNoDifference(PaneAddress.parts(for: URL(string: "https://figma.com")!).rest, "")

		// A query on the front page keeps its slash.
		expectNoDifference(PaneAddress.parts(for: URL(string: "https://figma.com/?a=1")!).rest, "/?a=1")
	}

	@Test
	internal func aPortStaysWithTheRest() {
		let (host, rest) = PaneAddress.parts(for: URL(string: "http://localhost:3000/admin")!)
		expectNoDifference(host, "localhost")
		expectNoDifference(rest, ":3000/admin")
	}

	@Test
	internal func anIPv6HostKeepsItsBrackets() {
		let (host, rest) = PaneAddress.parts(for: URL(string: "http://[::1]:3000/admin")!)
		expectNoDifference(host, "[::1]")
		expectNoDifference(rest, ":3000/admin")
	}

	@Test
	internal func addressesWithoutAHostAreShownWhole() {
		expectNoDifference(PaneAddress.parts(for: URL(string: "about:blank")!).host, "blank")
		let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: "reports/index.html")
		expectNoDifference(PaneAddress.parts(for: file).host, "~/reports/index.html")
		expectNoDifference(PaneAddress.parts(for: file).rest, "")
	}
}
