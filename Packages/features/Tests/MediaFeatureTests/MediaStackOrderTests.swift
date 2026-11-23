import BrowserCore
import CustomDump
import Foundation
import MediaFeature
import Testing
import _TestSupport

internal struct MediaStackOrderTests {
	private let first = BrowserCore.Tab.ID(rawValue: UUID(1))
	private let second = BrowserCore.Tab.ID(rawValue: UUID(2))
	private let third = BrowserCore.Tab.ID(rawValue: UUID(3))

	@Test
	internal func newTabsTakeTheNextPlacesInTheOrderTheyCome() {
		var order = MediaStackOrder()
		order.update(listing: [second, first])
		order.update(listing: [third, first, second])

		expectNoDifference(order.sorted(sources([first, third, second])).map(\.id.tabID), [second, first, third])
	}

	@Test
	internal func aTabKeepsItsPlaceWhateverOrderTheEngineListsItIn() {
		var order = MediaStackOrder()
		order.update(listing: [first, second, third])
		order.update(listing: [third, second, first])

		expectNoDifference(order.sorted(sources([third, second, first])).map(\.id.tabID), [first, second, third])
	}

	@Test
	internal func aTabThatLeavesGoesToTheEndWhenItComesBack() {
		var order = MediaStackOrder()
		order.update(listing: [first, second, third])
		order.update(listing: [second, third])
		order.update(listing: [first, second, third])

		expectNoDifference(order.sorted(sources([first, second, third])).map(\.id.tabID), [second, third, first])
	}

	@Test
	internal func aSourceNotListedYetGoesLastInTheOrderGiven() {
		var order = MediaStackOrder()
		order.update(listing: [second])

		expectNoDifference(order.sorted(sources([third, first, second])).map(\.id.tabID), [second, third, first])
	}

	private func sources(_ tabs: [BrowserCore.Tab.ID]) -> [BrowserMediaSource] {
		tabs.map { tabID in
			.init(
				id: .init(tabID: tabID, profileID: .init(rawValue: UUID(9)), generation: 1),
				revision: 1,
				title: "",
				site: nil,
				playback: .playing
			)
		}
	}
}
