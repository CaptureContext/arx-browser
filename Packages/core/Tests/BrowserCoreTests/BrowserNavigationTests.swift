import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct BrowserNavigationTests {
	@Test
	internal func directionalHistoryIsNearestFirstAndOmitsCurrent() async throws {
		let navigation = BrowserNavigation(history: try (0..<6).map {
			.init(
				id: $0,
				url: try #require(URL(string: "https://capturecontext.dev/\($0)")),
				title: "Entry \($0)",
				isCurrent: $0 == 3
			)
		})
		expectNoDifference(navigation.entries(in: .back).map(\.id), [2, 1, 0])
		expectNoDifference(navigation.entries(in: .forward).map(\.id), [4, 5])
		var invalid = navigation
		invalid.history[3].isCurrent = false
		#expect(invalid.entries(in: .back).isEmpty)
		invalid.history[0].isCurrent = true
		#expect(invalid.entries(in: .back).isEmpty)
		expectNoDifference(invalid.entries(in: .forward).map(\.id), [1, 2, 3, 4, 5])
		invalid.history[5].isCurrent = true
		#expect(invalid.entries(in: .forward).isEmpty)
		invalid = navigation
		invalid.history.append(navigation.history[0])
		#expect(invalid.entries(in: .back).isEmpty)
		#expect(BrowserNavigation().entries(in: .forward).isEmpty)
	}

	@Test
	internal func historyCommandsRespectAvailabilityAndEditableDefaultBindings() async throws {
		let available = BrowserCommandContext(host: .main, hasTab: true, canGoBack: true)
		#expect(BrowserCommand.goBack.isEnabled(in: available))
		#expect(!BrowserCommand.goForward.isEnabled(in: available))
		#expect(!BrowserCommand.goBack.isEnabled(in: .init(host: .main, hasTab: true)))
		#expect(!BrowserCommand.goBack.isEnabled(in: .init(host: .main, hasTab: true, isBusy: true, canGoBack: true)))
		expectNoDifference(BrowserCommand.goBack.shortcut, .init(key: "["))
		expectNoDifference(BrowserCommand.goForward.shortcut, .init(key: "]"))
		try BrowserPreferences().validate()
	}
}
