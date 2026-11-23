import AppKit

@MainActor
internal final class WeakHost {
	internal weak var view: NSView?

	internal init(_ view: NSView) {
		self.view = view
	}
}
