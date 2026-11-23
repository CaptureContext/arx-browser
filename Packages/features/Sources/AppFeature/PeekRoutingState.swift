import BrowserCore
import Foundation
import PeekFeature

public struct PeekRequest: Equatable, Sendable {
	public var source: PeekFeature.Source
	public var content: Content

	/// Where the link was clicked, in screen coordinates. Peek opens from and closes toward it.
	public var origin: CGPoint?

	public init(
		source: PeekFeature.Source,
		content: Content,
		origin: CGPoint? = nil
	) {
		self.source = source
		self.content = content
		self.origin = origin
	}

	public enum Content: Equatable, Sendable {
		case url(URL)
		case tab(BrowserCore.Tab.ID)

		/// A page's new tab the engine already made (DEV-1312): Peek shows that page, so its
		/// `window.opener` still reaches the page that opened it. Temporary, like a link's Peek.
		case newContents(BrowserCore.Tab)
	}
}

public enum PeekTransition: Equatable, Sendable {
	case dismiss
	case replace(PeekRequest)
	case promote(PeekDestination)
}
