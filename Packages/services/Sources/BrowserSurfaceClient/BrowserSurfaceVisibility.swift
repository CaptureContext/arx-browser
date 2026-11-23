import BrowserCore
import Foundation

/// A source-bound native host observation. Nil visibility means detached or still attaching.
public struct BrowserSurfaceVisibility: Equatable, Sendable {
	public let hostID: UUID
	public let tabID: BrowserCore.Tab.ID
	public let isVisible: Bool?

	public init(
		hostID: UUID,
		tabID: BrowserCore.Tab.ID,
		isVisible: Bool?
	) {
		self.hostID = hostID
		self.tabID = tabID
		self.isVisible = isVisible
	}
}

/// Keeps the environment value structural rather than storing a raw closure in @Entry.
public struct BrowserSurfaceVisibilityObserver: Sendable {
	private let report: @MainActor @Sendable (BrowserSurfaceVisibility) -> Void

	public init(report: @escaping @MainActor @Sendable (BrowserSurfaceVisibility) -> Void) {
		self.report = report
	}

	@MainActor
	public func callAsFunction(_ value: BrowserSurfaceVisibility) {
		report(value)
	}
}
