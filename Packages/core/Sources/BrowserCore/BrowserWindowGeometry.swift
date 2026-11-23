import Foundation
import CoreGraphics

/// The windowed frame stays intact while a window is full screen.
public struct BrowserWindowGeometry: Codable, Equatable, Sendable {
	public var frame: CGRect
	public var displayID: UInt32?
	public var isFullScreen: Bool

	public init(
		frame: CGRect,
		displayID: UInt32? = nil,
		isFullScreen: Bool = false
	) {
		self.frame = frame
		self.displayID = displayID
		self.isFullScreen = isFullScreen
	}

	/// A disconnected display or changed resolution must never strand a title bar offscreen.
	public func restoredFrame(
		on displays: [Display],
		minimumSize: CGSize
	) -> CGRect? {
		guard Self.isValid(frame), !displays.isEmpty else { return nil }
		let display = displays.first { $0.id == displayID }
		?? displays.first { $0.visibleFrame.intersects(frame) }
		?? displays[0]
		let visible = display.visibleFrame
		guard Self.isValid(visible) else { return nil }
		let width = min(max(frame.width, minimumSize.width), visible.width)
		let height = min(max(frame.height, minimumSize.height), visible.height)
		return .init(
			x: min(max(frame.minX, visible.minX), visible.maxX - width),
			y: min(max(frame.minY, visible.minY), visible.maxY - height),
			width: width,
			height: height
		)
	}

	private static func isValid(_ frame: CGRect) -> Bool {
		[frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
		&& frame.width > 0 && frame.height > 0
	}

	public struct Display: Equatable, Sendable {
		public var id: UInt32
		public var visibleFrame: CGRect

		public init(
			id: UInt32,
			visibleFrame: CGRect
		) {
			self.id = id
			self.visibleFrame = visibleFrame
		}
	}
}
