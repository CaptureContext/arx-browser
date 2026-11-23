@testable import AppFeature
import AppKit
import CoreServices.AE
import CustomDump
import Testing

@Suite(.dependencies, .serialized)
@MainActor
internal struct IncomingURLHandlerTests {
	@Test(arguments: [NSApplication.willFinishLaunchingNotification, NSApplication.didFinishLaunchingNotification])
	func launchPhaseReclaimsTheScalarHandlerWithoutLosingOrderOrDuplicates(phase: Notification.Name) throws {
		let notifications = NotificationCenter()
		let events = NSAppleEventManager.shared()
		var received: [URL] = []
		let handler = IncomingURLHandler(notifications: notifications, events: events) { received.append($0) }
		defer { handler.stop() }

		let replacement = ReplacementHandler()
		events.setEventHandler(
			replacement,
			andSelector: #selector(ReplacementHandler.handle(_:withReplyEvent:)),
			forEventClass: AEEventClass(kInternetEventClass),
			andEventID: AEEventID(kAEGetURL)
		)
		try dispatch("https://ignored.example.test")
		#expect(replacement.receipts == 1)
		#expect(received.isEmpty)

		notifications.post(name: phase, object: nil)
		let urls = [
			URL(string: "https://example.test/a?value=%E6%9D%B1%E4%BA%AC%2F100%25#first")!,
			URL(string: "https://other.example.test/b?value=two%20words%26more#second")!,
			URL(string: "https://example.test/a?value=%E6%9D%B1%E4%BA%AC%2F100%25#first")!,
		]
		for url in urls { try dispatch(url.absoluteString) }
		expectNoDifference(received, urls)
		#expect(replacement.receipts == 1)
	}

	@Test
	func rejectsUnsupportedSchemesAndDoesNotReinstallAfterStopping() throws {
		let notifications = NotificationCenter()
		let events = NSAppleEventManager.shared()
		var received: [URL] = []
		let handler = IncomingURLHandler(notifications: notifications, events: events) { received.append($0) }
		defer { handler.stop() }
		for value in ["file:///tmp/unowned.html", "javascript:alert(1)", "mailto:test@example.test"] {
			try dispatch(value)
		}
		#expect(received.isEmpty)

		handler.stop()
		let replacement = ReplacementHandler()
		events.setEventHandler(
			replacement,
			andSelector: #selector(ReplacementHandler.handle(_:withReplyEvent:)),
			forEventClass: AEEventClass(kInternetEventClass),
			andEventID: AEEventID(kAEGetURL)
		)
		notifications.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
		notifications.post(name: NSApplication.didFinishLaunchingNotification, object: nil)
		try dispatch("https://example.test/after-stop")
		#expect(replacement.receipts == 1)
		#expect(received.isEmpty)
	}

	/// DEV-987: Finder's Open With, `open -a`, a Dock drop and other apps send local files as
	/// the open-documents event. Each file reaches routing in order; anything else in the
	/// event doesn't, and an event with no file is left unhandled.
	@Test
	func openDocumentsRoutesLocalFilesInOrder() throws {
		let notifications = NotificationCenter()
		var received: [URL] = []
		let handler = IncomingURLHandler(notifications: notifications, events: .shared()) { received.append($0) }
		defer { handler.stop() }

		let files = [
			URL(fileURLWithPath: "/tmp/arx-local-reports/index.html"),
			URL(fileURLWithPath: "/tmp/arx local reports/second report.html"),
		]
		let list = NSAppleEventDescriptor.list()
		list.insert(NSAppleEventDescriptor(fileURL: files[0]), at: 0)
		list.insert(NSAppleEventDescriptor(string: "https://example.test/not-a-document"), at: 0)
		list.insert(NSAppleEventDescriptor(fileURL: files[1]), at: 0)
		expectNoDifference(try dispatchOpenDocuments(list), OSStatus(noErr))
		expectNoDifference(received, files)

		received = []
		let single = URL(fileURLWithPath: "/tmp/arx-local-reports/single.html")
		expectNoDifference(try dispatchOpenDocuments(NSAppleEventDescriptor(fileURL: single)), OSStatus(noErr))
		expectNoDifference(received, [single])

		received = []
		let unhandled = try dispatchOpenDocuments(NSAppleEventDescriptor(string: "https://example.test/a"))
		expectNoDifference(unhandled, OSStatus(errAEEventNotHandled))
		#expect(received.isEmpty)
	}

	@Test
	func launchPhaseReclaimsTheOpenDocumentsHandler() throws {
		let notifications = NotificationCenter()
		let events = NSAppleEventManager.shared()
		var received: [URL] = []
		let handler = IncomingURLHandler(notifications: notifications, events: events) { received.append($0) }
		defer { handler.stop() }

		let replacement = ReplacementHandler()
		events.setEventHandler(
			replacement,
			andSelector: #selector(ReplacementHandler.handle(_:withReplyEvent:)),
			forEventClass: AEEventClass(kCoreEventClass),
			andEventID: AEEventID(kAEOpenDocuments)
		)
		let file = URL(fileURLWithPath: "/tmp/arx-local-reports/index.html")
		_ = try dispatchOpenDocuments(NSAppleEventDescriptor(fileURL: file))
		#expect(replacement.receipts == 1)
		#expect(received.isEmpty)

		notifications.post(name: NSApplication.willFinishLaunchingNotification, object: nil)
		_ = try dispatchOpenDocuments(NSAppleEventDescriptor(fileURL: file))
		expectNoDifference(received, [file])
		#expect(replacement.receipts == 1)
	}

	/// AppKit installs its own open-documents handler at launch, outside NSAppleEventManager,
	/// which raises if asked to remove one it didn't install. Stopping leaves it in place.
	@Test
	func stoppingLeavesAnotherOwnersOpenDocumentsHandler() throws {
		let handler = IncomingURLHandler(notifications: NotificationCenter(), events: .shared()) { _ in }
		let foreign: AEEventHandlerUPP = { _, _, _ in OSErr(noErr) }
		#expect(AEInstallEventHandler(
			AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments), foreign, nil, false
		) == noErr)
		defer { AERemoveEventHandler(AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments), foreign, false) }

		handler.stop()
		var current: AEEventHandlerUPP?
		var reference: UnsafeMutableRawPointer?
		#expect(AEGetEventHandler(
			AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments), &current, &reference, false
		) == noErr)
		let installed = try #require(current)
		#expect(unsafeBitCast(installed, to: UnsafeRawPointer.self) == unsafeBitCast(foreign, to: UnsafeRawPointer.self))
	}

	/// DEV-987: URLs AppKit hands the application delegate reach Arx's routing; the
	/// delegate's own `application:openURLs:`, which in Chromium opens a browser window,
	/// never runs.
	@Test
	func theDelegatesOpenURLsReachesRoutingInsteadOfChromium() throws {
		var received: [URL] = []
		let handler = IncomingURLHandler(notifications: NotificationCenter(), events: .shared()) { received.append($0) }
		defer { handler.stop() }

		let delegate = ChromiumLikeDelegate()
		IncomingURLHandler.routeDelegateOpenURLs(on: delegate)
		IncomingURLHandler.routeDelegateOpenURLs(on: delegate)
		let urls = [
			URL(fileURLWithPath: "/tmp/arx-local-reports/index.html"),
			URL(string: "https://example.test/a")!,
			URL(string: "javascript:alert(1)")!,
			URL(string: "arx://open?url=https%3A%2F%2Fexample.test")!,
		]
		(delegate as any NSApplicationDelegate).application?(NSApplication.shared, open: urls)
		expectNoDifference(received, [urls[0], urls[1], urls[3]])
		#expect(delegate.opened.isEmpty)
	}

	private func dispatchOpenDocuments(_ object: NSAppleEventDescriptor) throws -> OSStatus {
		let event = NSAppleEventDescriptor.appleEvent(
			withEventClass: AEEventClass(kCoreEventClass),
			eventID: AEEventID(kAEOpenDocuments),
			targetDescriptor: nil,
			returnID: AEReturnID(kAutoGenerateReturnID),
			transactionID: AETransactionID(kAnyTransactionID)
		)
		event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
		var callback: AEEventHandlerUPP?
		var reference: UnsafeMutableRawPointer?
		let lookup = AEGetEventHandler(
			AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments),
			&callback, &reference, false
		)
		#expect(lookup == noErr)
		let dispatch = try #require(callback)

		// A reply record, as a sender that waits gets.
		var reply = AppleEvent()
		#expect(AECreateList(nil, 0, true, &reply) == noErr)
		defer { AEDisposeDesc(&reply) }

		// AppKit returns a refusal the handler put in the reply.
		let dispatched = dispatch(event.aeDesc, &reply, reference)
		guard dispatched == noErr else { return OSStatus(dispatched) }

		var error: Int32 = 0
		var type = DescType()
		var size = 0
		let status = AEGetParamPtr(
			&reply, AEKeyword(keyErrorNumber), DescType(typeSInt32), &type, &error, MemoryLayout<Int32>.size, &size
		)
		return status == noErr ? error : OSStatus(noErr)
	}

	private func dispatch(_ value: String) throws {
		let event = NSAppleEventDescriptor.appleEvent(
			withEventClass: AEEventClass(kInternetEventClass),
			eventID: AEEventID(kAEGetURL),
			targetDescriptor: nil,
			returnID: AEReturnID(kAutoGenerateReturnID),
			transactionID: AETransactionID(kAnyTransactionID)
		)
		event.setParam(NSAppleEventDescriptor(string: value), forKeyword: AEKeyword(keyDirectObject))
		var callback: AEEventHandlerUPP?
		var reference: UnsafeMutableRawPointer?
		let lookup = AEGetEventHandler(
			AEEventClass(kInternetEventClass), AEEventID(kAEGetURL),
			&callback, &reference, false
		)
		#expect(lookup == noErr)
		let dispatch = try #require(callback)
		var reply = AppleEvent()
		defer { AEDisposeDesc(&reply) }
		#expect(dispatch(event.aeDesc, &reply, reference) == noErr)
	}
}

@MainActor
private final class ReplacementHandler: NSObject {
	internal var receipts: Int = 0

	@objc
	internal func handle(
		_ event: NSAppleEventDescriptor,
		withReplyEvent reply: NSAppleEventDescriptor
	) {
		receipts += 1
	}
}

/// Stands in for Chromium's AppController, which answers `application:openURLs:` itself.
@MainActor
private final class ChromiumLikeDelegate: NSObject, NSApplicationDelegate {
	internal var opened: [URL] = []

	internal func application(_ application: NSApplication, open urls: [URL]) {
		opened += urls
	}
}
