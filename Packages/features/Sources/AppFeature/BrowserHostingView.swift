import SwiftUI

@MainActor
internal protocol BrowserWindowContent: AnyObject {
	func setMinimumSize(_ size: NSSize)
}

/// Express limits in SwiftUI so NSHostingView publishes them to AppKit's layout system.
@MainActor
internal final class BrowserHostingView<Content: View>: NSHostingView<BrowserWindowRoot<Content>>, BrowserWindowContent {
	internal convenience init(
		rootView: Content,
		minimumSize: NSSize
	) {
		self.init(rootView: .init(content: rootView, minimumSize: minimumSize))
	}

	internal required init(rootView: BrowserWindowRoot<Content>) {
		super.init(rootView: rootView)
		self.sizingOptions = [.minSize]
	}

	@available(*, unavailable)
	internal required init?(coder: NSCoder) {
		fatalError("Browser window hosts are created programmatically")
	}

	internal func setMinimumSize(_ size: NSSize) {
		rootView.minimumSize = size
	}
}

internal struct BrowserWindowRoot<Content: View>: View {
	internal var content: Content
	internal var minimumSize: NSSize

	internal init(
		content: Content,
		minimumSize: NSSize
	) {
		self.content = content
		self.minimumSize = minimumSize
	}

	internal var body: some View {
		content.frame(minWidth: minimumSize.width, minHeight: minimumSize.height)
	}
}
