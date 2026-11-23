import AppKit
import SwiftUI

internal struct PreviewWindowBackground: NSViewRepresentable {
	internal func makeNSView(context: Context) -> NSVisualEffectView {
		let view = NSVisualEffectView()
		view.material = .underWindowBackground
		view.blendingMode = .behindWindow
		view.state = .active
		return view
	}

	internal func updateNSView(
		_ view: NSVisualEffectView,
		context: Context
	) {
		view.window?.titlebarAppearsTransparent = true
		view.window?.isMovableByWindowBackground = false
	}
}
