import AppKit
import ObjectiveC

/// Offers the front browser window's page to Handoff (DEV-922): its address and title, as a
/// `NSUserActivityTypeBrowsingWeb` activity Safari and other browsers on this person's devices
/// can continue. Private windows, non-web pages and headless runs offer nothing.
@MainActor
internal final class HandoffActivity {
	private var activity: NSUserActivity?

	internal init() {}

	/// Offers `url`, or nothing for nil or a page that isn't http(s).
	internal func update(
		url: URL?,
		title: String
	) {
		guard
			let url,
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme)
		else {
			invalidate()
			return
		}

		let title: String? = title.isEmpty ? nil : title
		if let activity, activity.webpageURL == url, activity.title == title { return }

		let current = activity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
		current.isEligibleForHandoff = true
		current.webpageURL = url
		current.title = title
		activity = current
		current.becomeCurrent()
	}

	internal func invalidate() {
		activity?.invalidate()
		activity = nil
	}

	/// The page another device hands to Arx: a web page's http(s) address, else nil.
	internal static func incomingURL(_ activity: NSUserActivity) -> URL? {
		guard
			activity.activityType == NSUserActivityTypeBrowsingWeb,
			let url = activity.webpageURL,
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme)
		else { return nil }

		return url
	}
}

/// Chromium's AppController continues a Handoff into a Chrome browser window. Chromium asserts
/// that it stays the application delegate, so only `application:continueUserActivity:...` is
/// replaced on its class, as `BrowserDockMenu` does for the Dock menu; other activities keep
/// Chromium's implementation (DEV-922).
@MainActor
internal enum HandoffContinuation {
	private static var installedClasses: Set<ObjectIdentifier> = []
	private static var open: (@MainActor (URL) -> Void)?

	internal static func install(
		on delegate: any NSApplicationDelegate,
		open: @escaping @MainActor (URL) -> Void
	) {
		Self.open = open
		guard
			let type = object_getClass(delegate),
			installedClasses.insert(ObjectIdentifier(type)).inserted
		else { return }

		let selector = #selector(NSApplicationDelegate.application(_:continue:restorationHandler:))
		typealias Original = @convention(c) (AnyObject, Selector, NSApplication, NSUserActivity, AnyObject?) -> Bool
		let original = class_getInstanceMethod(type, selector).map {
			unsafeBitCast(method_getImplementation($0), to: Original.self)
		}
		let block: @MainActor @convention(block) (AnyObject, NSApplication, NSUserActivity, AnyObject?) -> Bool = {
			receiver, application, activity, handler in
			if let url = HandoffActivity.incomingURL(activity), let open = Self.open {
				open(url)
				return true
			}
			return original?(receiver, selector, application, activity, handler) ?? false
		}
		class_replaceMethod(type, selector, imp_implementationWithBlock(block), "B@:@@@?")
	}
}
