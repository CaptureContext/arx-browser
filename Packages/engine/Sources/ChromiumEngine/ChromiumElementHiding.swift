import Darwin
import Foundation

/// `void (*)(void* context, const char* json, size_t length)`: a profile's hidden elements as
/// JSON, `{hostname: [filter]}`, borrowed for the call (DEV-1019).
internal typealias ChromiumHiddenElementsCallback = @convention(c) (
	UnsafeMutableRawPointer?,
	UnsafePointer<CChar>?,
	Int
) -> Void

/// `bool ArxEngineStartElementPicker(uint64_t page)` (DEV-1019).
internal typealias ChromiumStartElementPickerFunction = @convention(c) (UInt64) -> Bool

/// `bool ArxEngineCopyHiddenElements(uint64_t page, done, context)` (DEV-1019).
internal typealias ChromiumCopyHiddenElementsFunction = @convention(c) (
	UInt64,
	ChromiumHiddenElementsCallback?,
	UnsafeMutableRawPointer?
) -> Bool

/// `bool ArxEngineCopyElementPickerStatus(uint64_t page, done, context)` (DEV-1019), with the
/// same callback as `ArxEngineCopyHiddenElements`.
internal typealias ChromiumCopyElementPickerStatusFunction = ChromiumCopyHiddenElementsFunction

/// `bool ArxEngineAddFixtureFilters(uint64_t page, const char* filters)` (DEV-1019), the
/// extensions smoke's lines for My filters.
internal typealias ChromiumAddFixtureFiltersFunction = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Bool

/// `bool ArxEngineShowHiddenElement(uint64_t page, const char* filter)` (DEV-1019).
internal typealias ChromiumShowHiddenElementFunction = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Bool

/// `bool ArxEngineHideElement(uint64_t page, const char* filter)` (DEV-1201), the line Arx's
/// own element picker picked.
internal typealias ChromiumHideElementFunction = @convention(c) (UInt64, UnsafePointer<CChar>?) -> Bool

/// Hide Element (DEV-1019): uBlock Origin's element picker on a page, and the elements hidden
/// on sites in a page's profile, from uBlock's My filters. Outside the ABI table: an engine
/// built before it has none of them.
internal struct ChromiumElementHidingFunctions {
	internal var startPicker: ChromiumStartElementPickerFunction
	internal var copyHidden: ChromiumCopyHiddenElementsFunction
	internal var show: ChromiumShowHiddenElementFunction

	/// Only for the extensions smoke; engines built before them have the rest without them.
	internal var copyPickerStatus: ChromiumCopyElementPickerStatusFunction?
	internal var addFixtureFilters: ChromiumAddFixtureFiltersFunction?

	/// Arx's own element picker's (DEV-1201); engines built before it have the rest without it.
	internal var hide: ChromiumHideElementFunction?

	internal init(
		startPicker: ChromiumStartElementPickerFunction,
		copyHidden: ChromiumCopyHiddenElementsFunction,
		show: ChromiumShowHiddenElementFunction,
		copyPickerStatus: ChromiumCopyElementPickerStatusFunction? = nil,
		addFixtureFilters: ChromiumAddFixtureFiltersFunction? = nil,
		hide: ChromiumHideElementFunction? = nil
	) {
		self.startPicker = startPicker
		self.copyHidden = copyHidden
		self.show = show
		self.copyPickerStatus = copyPickerStatus
		self.addFixtureFilters = addFixtureFilters
		self.hide = hide
	}

	internal static func load(_ handle: UnsafeMutableRawPointer) -> Self? {
		guard
			let startPicker = dlsym(handle, "ArxEngineStartElementPicker"),
			let copyHidden = dlsym(handle, "ArxEngineCopyHiddenElements"),
			let show = dlsym(handle, "ArxEngineShowHiddenElement")
		else { return nil }

		return .init(
			startPicker: unsafeBitCast(startPicker, to: ChromiumStartElementPickerFunction.self),
			copyHidden: unsafeBitCast(copyHidden, to: ChromiumCopyHiddenElementsFunction.self),
			show: unsafeBitCast(show, to: ChromiumShowHiddenElementFunction.self),
			copyPickerStatus: dlsym(handle, "ArxEngineCopyElementPickerStatus").map {
				unsafeBitCast($0, to: ChromiumCopyElementPickerStatusFunction.self)
			},
			addFixtureFilters: dlsym(handle, "ArxEngineAddFixtureFilters").map {
				unsafeBitCast($0, to: ChromiumAddFixtureFiltersFunction.self)
			},
			hide: dlsym(handle, "ArxEngineHideElement").map {
				unsafeBitCast($0, to: ChromiumHideElementFunction.self)
			}
		)
	}
}

/// The elements hidden on sites in a profile, by hostname: each a line of uBlock's My filters,
/// such as `example.com##.banner` (DEV-1019).
public struct ChromiumHiddenElements: Equatable, Sendable {
	public var sites: [String: [String]]

	public init(sites: [String: [String]] = [:]) {
		self.sites = sites
	}

	/// Reads arx.js's `arxHiddenElements` JSON; anything that isn't `{string: [string]}` is left out.
	internal static func decode(_ data: Data) -> Self {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return .init() }

		var sites: [String: [String]] = [:]
		for (host, value) in object {
			guard let filters = value as? [String] else { continue }
			let kept = filters.filter { !$0.isEmpty && !$0.contains("\n") }
			if !kept.isEmpty { sites[host.lowercased()] = kept }
		}
		return .init(sites: sites)
	}
}

/// Holds a continuation while the engine reads, released by its one callback.
private final class StoredObjectReply {
	internal let continuation: CheckedContinuation<Data, Never>

	internal init(_ continuation: CheckedContinuation<Data, Never>) {
		self.continuation = continuation
	}
}

extension ChromiumRuntime {
	/// Whether this engine can hide elements with uBlock Origin (DEV-1019).
	public var supportsElementHiding: Bool { optionalExports.elementHiding != nil }

	/// Opens uBlock Origin's element picker on `page`, an ordinary http(s) page whose profile
	/// has content blocking on. False when it can't.
	public func startElementPicker(on page: ChromiumPage) -> Bool {
		guard let start = optionalExports.elementHiding?.startPicker
		else { return false }

		return performIfOpen(on: page) { _, id in start(id) } ?? false
	}

	/// The elements hidden on sites in `page`'s profile. Nil when the engine can't read them.
	public func hiddenElements(on page: ChromiumPage) async -> ChromiumHiddenElements? {
		guard let copy = optionalExports.elementHiding?.copyHidden
		else { return nil }

		return await storedObject(on: page, copy: copy).map(ChromiumHiddenElements.decode)
	}

	/// What uBlock Origin made of the last element picker ask in `page`'s profile, as arx.js
	/// writes `arxElementPickerStatus`: `{request, tabId, outcome, …}`, or an empty object
	/// before any. Nil when the engine can't read it. For the extensions smoke (DEV-1019).
	public func elementPickerStatus(on page: ChromiumPage) async -> [String: Any]? {
		guard let copy = optionalExports.elementHiding?.copyPickerStatus
		else { return nil }

		return await storedObject(on: page, copy: copy).map { data in
			(try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
		}
	}

	/// Adds `filters` to My filters in `page`'s profile, for the extensions smoke's check that
	/// site-specific hiding and scriptlets reach a page (DEV-1019). The engine takes them only in
	/// the extension fixture run. False when it doesn't.
	public func addFixtureFiltersForTesting(
		_ filters: [String],
		on page: ChromiumPage
	) -> Bool {
		guard
			let add = optionalExports.elementHiding?.addFixtureFilters,
			!filters.isEmpty,
			!filters.contains(where: { $0.contains("\n") })
		else { return false }

		return performIfOpen(on: page) { _, id in
			filters.joined(separator: "\n").withCString { add(id, $0) }
		} ?? false
	}

	/// One of arx.js's objects in uBlock's storage, as JSON. Nil when the engine doesn't read it.
	private func storedObject(
		on page: ChromiumPage,
		copy: ChromiumCopyHiddenElementsFunction
	) async -> Data? {
		guard
			state == .running,
			pages[page.identifier] === page
		else { return nil }

		let pageID = page.identifier
		var started = false
		let data = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
			let reply = Unmanaged.passRetained(StoredObjectReply(continuation))
			started = copy(
				pageID,
				{ context, json, length in
					guard let context else { return }
					let reply = Unmanaged<StoredObjectReply>.fromOpaque(context).takeRetainedValue()
					reply.continuation.resume(returning: json.map { Data(bytes: $0, count: length) } ?? Data())
				},
				reply.toOpaque()
			)
			if !started {
				reply.release()
				continuation.resume(returning: Data())
			}
		}
		return started ? data : nil
	}

	/// Takes `filter`, one of `hiddenElements(on:)`'s lines, out of My filters in `page`'s
	/// profile. The element shows once the page reloads. False when it can't.
	public func showHiddenElement(
		_ filter: String,
		on page: ChromiumPage
	) -> Bool {
		guard let show = optionalExports.elementHiding?.show
		else { return false }

		return performIfOpen(on: page) { _, id in
			filter.withCString { show(id, $0) }
		} ?? false
	}
}
