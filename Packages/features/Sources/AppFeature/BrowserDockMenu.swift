import AppKit
import ObjectiveC

/// Chromium asserts that its shared AppController remains NSApp.delegate. Install only
/// the Dock-menu selector on that same class, preserving its implementation as fallback.
@MainActor
internal enum BrowserDockMenu {
	private static var installedClasses: Set<ObjectIdentifier> = []

	internal static func install(
		on delegate: any NSApplicationDelegate,
		menu: @escaping @MainActor () -> NSMenu?
	) {
		guard let type = object_getClass(delegate) else { return }
		guard installedClasses.insert(ObjectIdentifier(type)).inserted else { return }
		let selector = #selector(NSApplicationDelegate.applicationDockMenu(_:))
		typealias Original = @convention(c) (AnyObject, Selector, NSApplication) -> Unmanaged<NSMenu>?
		let original = class_getInstanceMethod(type, selector).map {
			unsafeBitCast(method_getImplementation($0), to: Original.self)
		}
		let block: @MainActor @convention(block) (AnyObject, NSApplication) -> NSMenu? = { receiver, application in
			menu() ?? original?(receiver, selector, application)?.takeUnretainedValue()
		}

		// class_replaceMethod adds a local override when the selector is inherited, so no
		// superclass or other delegate classes are changed.
		class_replaceMethod(type, selector, imp_implementationWithBlock(block), "@@:@")
	}
}
