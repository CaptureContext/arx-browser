import Foundation

/// View › Zoom In, Zoom Out and Actual Size (DEV-726).
public enum PageZoom: String, Codable, Equatable, Sendable {
	case zoomIn
	case zoomOut

	/// Back to the profile's default zoom.
	case actualSize

	/// Factors closer than this are the same level, so 0.33 matches Chromium's 1/3.
	private static let tolerance: Double = 0.01

	/// The factor this step sets from `current`: the next of Chrome's levels in
	/// `SiteSettings.zoomFactors` and the profile's `default`, as Chrome steps,
	/// `current` itself at either end, or nil for Actual Size, which returns to
	/// the default.
	public func factor(
		from current: Double,
		default defaultFactor: Double = 1
	) -> Double? {
		var levels = SiteSettings.zoomFactors
		if
			SiteSettings.zoomRange.contains(defaultFactor),
			!levels.contains(where: { abs($0 - defaultFactor) <= Self.tolerance })
		{
			levels.append(defaultFactor)
			levels.sort()
		}
		switch self {
		case .zoomIn:
			return levels.first { $0 > current + Self.tolerance } ?? max(current, levels.last ?? current)
		case .zoomOut:
			return levels.last { $0 < current - Self.tolerance } ?? min(current, levels.first ?? current)
		case .actualSize:
			return nil
		}
	}

	/// A factor as a whole percentage, as the zoom badge shows it.
	public static func percent(_ factor: Double) -> Int {
		Int((factor * 100).rounded())
	}
}

extension BrowserCommand {
	/// The page zoom step a zoom command takes.
	public var pageZoom: PageZoom? {
		switch self {
		case .zoomIn: .zoomIn
		case .zoomOut: .zoomOut
		case .actualSize: .actualSize
		default: nil
		}
	}
}
