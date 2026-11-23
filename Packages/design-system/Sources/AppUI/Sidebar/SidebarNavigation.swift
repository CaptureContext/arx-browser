import BrowserCore

public struct SidebarNavigation {
	public var canGoBack: Bool
	public var canGoForward: Bool
	public var isLoading: Bool
	public var isAvailable: Bool
	public var history: BrowserNavigation
	public var selectHistory: (Int) -> Void
	public var back: () -> Void
	public var forward: () -> Void
	public var reloadOrStop: () -> Void

	public init(
		canGoBack: Bool = false,
		canGoForward: Bool = false,
		isLoading: Bool = false,
		isAvailable: Bool = false,
		history: BrowserNavigation = .init(),
		selectHistory: @escaping (Int) -> Void = { _ in },
		back: @escaping () -> Void = {},
		forward: @escaping () -> Void = {},
		reloadOrStop: @escaping () -> Void = {}
	) {
		self.history = history
		self.selectHistory = selectHistory
		self.canGoBack = canGoBack
		self.canGoForward = canGoForward
		self.isLoading = isLoading
		self.isAvailable = isAvailable
		self.back = back
		self.forward = forward
		self.reloadOrStop = reloadOrStop
	}
}
