import AppKit
import BrowserCore
import CoreServices.AE
import ObjectiveC

/// Keeps Arx's scalar URL route installed while AppKit configures its launch handlers.
///
/// DEV-987: local files arrive as the open-documents event (Finder's Open With, `open -a`, a
/// drop on the Dock icon, another app opening a file with Arx). Arx takes that event too, so
/// AppKit never hands the files to Chromium's application delegate, whose `application:openURLs:`
/// opens them in a Chromium browser window. That method is replaced as well
/// (``routeDelegateOpenURLs(on:)``), so nothing AppKit gives the delegate opens one.
@MainActor
internal final class IncomingURLHandler: NSObject {
	private let notifications: NotificationCenter
	private let events: NSAppleEventManager
	private let receive: @MainActor (URL) -> Void

	internal init(
		notifications: NotificationCenter = .default,
		events: NSAppleEventManager = .shared(),
		receive: @escaping @MainActor (URL) -> Void
	) {
		self.notifications = notifications
		self.events = events
		self.receive = receive
		super.init()

		// AppKit may replace an earlier registration before delivering cold-launch URLs.
		// The Chromium readiness callback can precede or follow didFinishLaunching.
		for name in [NSApplication.willFinishLaunchingNotification, NSApplication.didFinishLaunchingNotification] {
			self.notifications.addObserver(
				self,
				selector: #selector(applicationLaunchPhase(_:)),
				name: name,
				object: nil
			)
		}
		self.install()
	}

	internal func install() {
		events.setEventHandler(
			self,
			andSelector: #selector(handle(_:withReplyEvent:)),
			forEventClass: AEEventClass(kInternetEventClass),
			andEventID: AEEventID(kAEGetURL)
		)
		events.setEventHandler(
			self,
			andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
			forEventClass: AEEventClass(kCoreEventClass),
			andEventID: AEEventID(kAEOpenDocuments)
		)
		installed = Self.registration(AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments))
		Self.current = self
	}

	internal func stop() {
		notifications.removeObserver(self)
		events.removeEventHandler(
			forEventClass: AEEventClass(kInternetEventClass),
			andEventID: AEEventID(kAEGetURL)
		)

		// AppKit installs its own open-documents handler at launch, outside NSAppleEventManager,
		// which can't remove it (it raises). Remove only the registration installed here.
		if let installed, Self.registration(AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments)) == installed {
			events.removeEventHandler(
				forEventClass: AEEventClass(kCoreEventClass),
				andEventID: AEEventID(kAEOpenDocuments)
			)
		}
		installed = nil
		if Self.current === self { Self.current = nil }
	}

	/// The open-documents registration `install()` made.
	private var installed: Registration?

	private struct Registration: Equatable {
		internal let handler: UnsafeRawPointer
		internal let reference: UnsafeMutableRawPointer?
	}

	/// The handler and reference the process's Apple Event table holds for an event, if any.
	private static func registration(_ eventClass: AEEventClass, _ eventID: AEEventID) -> Registration? {
		var handler: AEEventHandlerUPP?
		var reference: UnsafeMutableRawPointer?
		guard AEGetEventHandler(eventClass, eventID, &handler, &reference, false) == noErr, let handler
		else { return nil }

		return .init(handler: unsafeBitCast(handler, to: UnsafeRawPointer.self), reference: reference)
	}

	/// The handler the application delegate's `application:openURLs:` reaches.
	private static weak var current: IncomingURLHandler?
	private static var routedDelegateClasses: Set<ObjectIdentifier> = []

	/// DEV-987. Replaces `application:openURLs:` on the delegate's own class, as
	/// `BrowserDockMenu` replaces the Dock menu, so the URLs AppKit hands Chromium's
	/// AppController reach Arx's routing; Chromium's implementation, which opens a browser
	/// window of its own, never runs. Other classes and the delegate object stay as they are.
	internal static func routeDelegateOpenURLs(on delegate: any NSApplicationDelegate) {
		guard
			let type = object_getClass(delegate),
			routedDelegateClasses.insert(ObjectIdentifier(type)).inserted
		else { return }

		let selector = #selector(NSApplicationDelegate.application(_:open:))
		let block: @MainActor @convention(block) (AnyObject, NSApplication, NSArray) -> Void = { _, _, urls in
			current?.open(urls.compactMap { $0 as? URL })
		}
		class_replaceMethod(type, selector, imp_implementationWithBlock(block), "v@:@@")
	}

	/// Routes what Arx opens from outside: http(s) and arx:// links, arc:// links while
	/// `ARX_BROWSER_LINKS` is on (DEV-1193), and local files. Whatever else is dropped.
	/// Returns whether anything was taken.
	@discardableResult
	internal func open(_ urls: [URL]) -> Bool {
		let accepted = urls.filter { url in
			url.isFileURL || Self.takesLink(url)
		}
		for url in accepted { receive(url) }
		return !accepted.isEmpty
	}

	/// Whether Arx takes this link from another app: a web or `arx://` address, or an `arc://`
	/// one while `browserLinks` is on (DEV-1193). Never another browser's own scheme, such as
	/// `chrome://`: whoever opens one from Terminal means that browser.
	internal static func takesLink(
		_ url: URL,
		browserLinks: Bool = FeatureFlag.browserLinks.isOn()
	) -> Bool {
		switch url.scheme?.lowercased() {
		case "arx"?: true
		case "arc"?: browserLinks
		default: url.hasWebScheme
		}
	}

	/// The local files an open-documents event names, in its order.
	internal static func documentURLs(_ event: NSAppleEventDescriptor) -> [URL] {
		guard let object = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) else { return [] }

		let items: [NSAppleEventDescriptor] = object.descriptorType == typeAEList
		? (0..<max(object.numberOfItems, 0)).compactMap { object.atIndex($0 + 1) }
		: [object]
		return items.compactMap { item in

			// Only a file reference: text would coerce too, read as an HFS path.
			guard
				fileReferenceTypes.contains(item.descriptorType),
				let url = item.coerce(toDescriptorType: typeFileURL)?.fileURLValue,
				url.isFileURL
			else { return nil }

			return url
		}
	}

	/// How senders name a file: a file URL, an alias, an FSRef or a bookmark.
	private static let fileReferenceTypes: Set<DescType> = [
		DescType(typeFileURL), DescType(typeAlias), DescType(typeFSRef), DescType(typeBookmarkData),
	]

	@objc
	private func applicationLaunchPhase(_ notification: Notification) {
		install()
	}

	/// Local files from Finder, `open -a`, the Dock or another app (DEV-987).
	@objc
	private func handleOpenDocuments(
		_ event: NSAppleEventDescriptor,
		withReplyEvent reply: NSAppleEventDescriptor
	) {
		guard !open(Self.documentURLs(event)), reply.descriptorType != typeNull else { return }

		reply.setParam(
			NSAppleEventDescriptor(int32: Int32(errAEEventNotHandled)),
			forKeyword: AEKeyword(keyErrorNumber)
		)
	}

	@objc
	private func handle(
		_ event: NSAppleEventDescriptor,
		withReplyEvent reply: NSAppleEventDescriptor
	) {
		guard
			let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
			let url = URL(string: value),
			// arx:// automation links too (DEV-929); ArxURLCommand admits only its own verbs.
			// arc:// ones too (DEV-1193).
			Self.takesLink(url)
		else {
			guard reply.descriptorType != typeNull else { return }
			reply.setParam(
				NSAppleEventDescriptor(int32: Int32(errAEEventNotHandled)),
				forKeyword: AEKeyword(keyErrorNumber)
			)
			return
		}
		receive(url)
	}
}
