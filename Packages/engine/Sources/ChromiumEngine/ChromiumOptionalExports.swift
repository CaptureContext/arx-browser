import Darwin
import Foundation

/// `void ArxEngineSetContentBlocking(bool enabled, bool block_cookie_banners)` (DEV-884): main
/// thread, safe before the engine runs. Turns Arx's content blocking (Helium's uBlock Origin)
/// on or off in every regular profile, now and as they load, and selects uBlock's cookie notice
/// lists. Exported outside the ABI table, so engines built before it still load and lack it.
internal typealias ChromiumContentBlockingFunction = @convention(c) (Bool, Bool) -> Void

internal let ChromiumContentBlockingSymbol: String = "ArxEngineSetContentBlocking"

/// `bool ArxEngineAppendLinkExtensionItems(uint64_t page, uint64_t token, void* menu)` (DEV-890):
/// main thread, while the app shows its menu for a link token. Appends extensions'
/// `chrome.contextMenus` items for that link to the borrowed `NSMenu`; a chosen one runs at once.
/// False when there are none or the link's menu isn't current. Outside the ABI table too.
internal typealias ChromiumLinkExtensionItemsFunction = @convention(c) (UInt64, UInt64, UnsafeMutableRawPointer?) -> Bool

internal let ChromiumLinkExtensionItemsSymbol: String = "ArxEngineAppendLinkExtensionItems"

/// `uint64_t ArxEngineLostOnQuitDownloadCount(void)` (DEV-1130): main thread. How many transfers
/// in progress, paused ones included, a quit would lose: private ones, and ordinary ones Chromium
/// couldn't continue from their bytes on disk. Read synchronously from the native managers.
internal typealias ChromiumLostOnQuitDownloadCountFunction = @convention(c) () -> UInt64

internal let ChromiumLostOnQuitDownloadCountSymbol: String = "ArxEngineLostOnQuitDownloadCount"

/// `bool ArxEngineEndPictureInPicture(uint64_t page)` (DEV-1128): main thread. Ends the page's
/// video or document picture in picture without unloading it, as closing the window that owns its
/// tab does. True when there was one.
internal typealias ChromiumEndPictureInPictureFunction = @convention(c) (UInt64) -> Bool

internal let ChromiumEndPictureInPictureSymbol: String = "ArxEngineEndPictureInPicture"

/// `size_t ArxEngineCopyExtensionActionIcon(uint64_t page, const char* extension_id, float scale,
/// uint8_t* buffer, size_t capacity)` (DEV-824 follow-up): main thread. The PNG of the icon an
/// enabled extension set for the page's tab with `setIcon` or a declarative rule, at scale 1 or
/// 2. Returns its size, copying it only when `buffer` holds it all; 0 when the extension set none.
internal typealias ChromiumExtensionActionIconFunction = @convention(c) (
	UInt64,
	UnsafePointer<CChar>?,
	Float,
	UnsafeMutablePointer<UInt8>?,
	Int
) -> Int

internal let ChromiumExtensionActionIconSymbol: String = "ArxEngineCopyExtensionActionIcon"

/// `bool ArxEngineFollowsAllShortcutKeys(void)` (DEV-1332): true when the engine reports whether a
/// page used every key combination Arx can bind (⌘ or ⌃ held, or an F-key), not only ⌘ ones.
/// Outside the ABI table: engines built before it lack it, and only ⌘ keys reach a page first.
internal typealias ChromiumFollowsAllShortcutKeysFunction = @convention(c) () -> Bool

internal let ChromiumFollowsAllShortcutKeysSymbol: String = "ArxEngineFollowsAllShortcutKeys"

/// Exports newer than the ABI table, looked up once after loading the framework.
internal struct ChromiumOptionalExports {
	internal var contentBlocking: ChromiumContentBlockingFunction?
	internal var linkExtensionItems: ChromiumLinkExtensionItemsFunction?

	/// DEV-1084.
	internal var formEdits: ChromiumFormEditsFunction?

	/// DEV-877.
	internal var setProtectedMediaHandler: ChromiumSetProtectedMediaHandlerFunction?
	internal var copySiteCookies: ChromiumCopySiteCookiesFunction?

	/// DEV-1211.
	internal var setProtectedMediaReasonHandler: ChromiumSetProtectedMediaReasonHandlerFunction?

	/// DEV-915.
	internal var setBatterySaverMode: ChromiumSetBatterySaverModeFunction?
	internal var batterySaverIsActive: ChromiumBatterySaverIsActiveFunction?
	internal var observeBatterySaver: ChromiumObserveBatterySaverFunction?

	/// DEV-1020.
	internal var darkPages: ChromiumDarkPagesFunction?

	/// DEV-905.
	internal var deviceChoosers: ChromiumDeviceChooserFunctions?

	/// DEV-927.
	internal var cast: ChromiumCastFunctions?

	/// DEV-1019.
	internal var elementHiding: ChromiumElementHidingFunctions?

	/// DEV-1130.
	internal var lostOnQuitDownloadCount: ChromiumLostOnQuitDownloadCountFunction?

	/// DEV-1144.
	internal var pageMedia: ChromiumPageMediaFunctions?

	/// DEV-1128.
	internal var endPictureInPicture: ChromiumEndPictureInPictureFunction?

	/// DEV-1172.
	internal var wholePageCapture: ChromiumWholePageCaptureFunctions?

	/// DEV-824 follow-up.
	internal var extensionActionIcon: ChromiumExtensionActionIconFunction?

	/// DEV-1293.
	internal var setPageSharedHistory: ChromiumSetPageSharedHistoryFunction?
	internal var setSharedHistoryHandler: ChromiumSetSharedHistoryHandlerFunction?

	/// DEV-1316.
	internal var setExtensionPopupPresenter: ChromiumSetExtensionPopupPresenterFunction?

	/// DEV-1332.
	internal var followsAllShortcutKeys: ChromiumFollowsAllShortcutKeysFunction?

	internal init(
		contentBlocking: ChromiumContentBlockingFunction? = nil,
		linkExtensionItems: ChromiumLinkExtensionItemsFunction? = nil,
		formEdits: ChromiumFormEditsFunction? = nil,
		setProtectedMediaHandler: ChromiumSetProtectedMediaHandlerFunction? = nil,
		copySiteCookies: ChromiumCopySiteCookiesFunction? = nil,
		setProtectedMediaReasonHandler: ChromiumSetProtectedMediaReasonHandlerFunction? = nil,
		setBatterySaverMode: ChromiumSetBatterySaverModeFunction? = nil,
		batterySaverIsActive: ChromiumBatterySaverIsActiveFunction? = nil,
		observeBatterySaver: ChromiumObserveBatterySaverFunction? = nil,
		darkPages: ChromiumDarkPagesFunction? = nil,
		deviceChoosers: ChromiumDeviceChooserFunctions? = nil,
		cast: ChromiumCastFunctions? = nil,
		elementHiding: ChromiumElementHidingFunctions? = nil,
		lostOnQuitDownloadCount: ChromiumLostOnQuitDownloadCountFunction? = nil,
		pageMedia: ChromiumPageMediaFunctions? = nil,
		endPictureInPicture: ChromiumEndPictureInPictureFunction? = nil,
		wholePageCapture: ChromiumWholePageCaptureFunctions? = nil,
		extensionActionIcon: ChromiumExtensionActionIconFunction? = nil,
		setPageSharedHistory: ChromiumSetPageSharedHistoryFunction? = nil,
		setSharedHistoryHandler: ChromiumSetSharedHistoryHandlerFunction? = nil,
		setExtensionPopupPresenter: ChromiumSetExtensionPopupPresenterFunction? = nil,
		followsAllShortcutKeys: ChromiumFollowsAllShortcutKeysFunction? = nil
	) {
		self.contentBlocking = contentBlocking
		self.linkExtensionItems = linkExtensionItems
		self.formEdits = formEdits
		self.setProtectedMediaHandler = setProtectedMediaHandler
		self.copySiteCookies = copySiteCookies
		self.setProtectedMediaReasonHandler = setProtectedMediaReasonHandler
		self.setBatterySaverMode = setBatterySaverMode
		self.batterySaverIsActive = batterySaverIsActive
		self.observeBatterySaver = observeBatterySaver
		self.darkPages = darkPages
		self.deviceChoosers = deviceChoosers
		self.cast = cast
		self.elementHiding = elementHiding
		self.lostOnQuitDownloadCount = lostOnQuitDownloadCount
		self.pageMedia = pageMedia
		self.endPictureInPicture = endPictureInPicture
		self.wholePageCapture = wholePageCapture
		self.extensionActionIcon = extensionActionIcon
		self.setPageSharedHistory = setPageSharedHistory
		self.setSharedHistoryHandler = setSharedHistoryHandler
		self.setExtensionPopupPresenter = setExtensionPopupPresenter
		self.followsAllShortcutKeys = followsAllShortcutKeys
	}
}

extension ChromiumFramework {
	/// The optional exports of the framework `load(at:)` already opened.
	internal static func optionalExports(at executableURL: URL) -> ChromiumOptionalExports {
		// The framework is loaded and never closed; NOLOAD only finds that handle.
		guard let handle = dlopen(executableURL.path, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD)
		else { return .init() }

		return .init(
			contentBlocking: dlsym(handle, ChromiumContentBlockingSymbol)
				.map { unsafeBitCast($0, to: ChromiumContentBlockingFunction.self) },
			linkExtensionItems: dlsym(handle, ChromiumLinkExtensionItemsSymbol)
				.map { unsafeBitCast($0, to: ChromiumLinkExtensionItemsFunction.self) },
			formEdits: dlsym(handle, ChromiumFormEditsSymbol)
				.map { unsafeBitCast($0, to: ChromiumFormEditsFunction.self) },
			setProtectedMediaHandler: dlsym(handle, ChromiumSetProtectedMediaHandlerSymbol)
				.map { unsafeBitCast($0, to: ChromiumSetProtectedMediaHandlerFunction.self) },
			copySiteCookies: dlsym(handle, ChromiumCopySiteCookiesSymbol)
				.map { unsafeBitCast($0, to: ChromiumCopySiteCookiesFunction.self) },
			setProtectedMediaReasonHandler: dlsym(handle, ChromiumSetProtectedMediaReasonHandlerSymbol)
				.map { unsafeBitCast($0, to: ChromiumSetProtectedMediaReasonHandlerFunction.self) },
			setBatterySaverMode: dlsym(handle, ChromiumSetBatterySaverModeSymbol)
				.map { unsafeBitCast($0, to: ChromiumSetBatterySaverModeFunction.self) },
			batterySaverIsActive: dlsym(handle, ChromiumBatterySaverIsActiveSymbol)
				.map { unsafeBitCast($0, to: ChromiumBatterySaverIsActiveFunction.self) },
			observeBatterySaver: dlsym(handle, ChromiumObserveBatterySaverSymbol)
				.map { unsafeBitCast($0, to: ChromiumObserveBatterySaverFunction.self) },
			darkPages: dlsym(handle, ChromiumDarkPagesSymbol)
				.map { unsafeBitCast($0, to: ChromiumDarkPagesFunction.self) },
			deviceChoosers: ChromiumDeviceChooserFunctions.load(handle),
			cast: ChromiumCastFunctions.load(handle),
			elementHiding: ChromiumElementHidingFunctions.load(handle),
			lostOnQuitDownloadCount: dlsym(handle, ChromiumLostOnQuitDownloadCountSymbol)
				.map { unsafeBitCast($0, to: ChromiumLostOnQuitDownloadCountFunction.self) },
			pageMedia: ChromiumPageMediaFunctions.load(handle),
			endPictureInPicture: dlsym(handle, ChromiumEndPictureInPictureSymbol)
				.map { unsafeBitCast($0, to: ChromiumEndPictureInPictureFunction.self) },
			wholePageCapture: ChromiumWholePageCaptureFunctions.load(handle),
			extensionActionIcon: dlsym(handle, ChromiumExtensionActionIconSymbol)
				.map { unsafeBitCast($0, to: ChromiumExtensionActionIconFunction.self) },
			setPageSharedHistory: dlsym(handle, ChromiumSetPageSharedHistorySymbol)
				.map { unsafeBitCast($0, to: ChromiumSetPageSharedHistoryFunction.self) },
			setSharedHistoryHandler: dlsym(handle, ChromiumSetSharedHistoryHandlerSymbol)
				.map { unsafeBitCast($0, to: ChromiumSetSharedHistoryHandlerFunction.self) },
			setExtensionPopupPresenter: dlsym(handle, ChromiumSetExtensionPopupPresenterSymbol)
				.map { unsafeBitCast($0, to: ChromiumSetExtensionPopupPresenterFunction.self) },
			followsAllShortcutKeys: dlsym(handle, ChromiumFollowsAllShortcutKeysSymbol)
				.map { unsafeBitCast($0, to: ChromiumFollowsAllShortcutKeysFunction.self) }
		)
	}
}

extension ChromiumRuntime {
	/// Whether this engine can turn content blocking on and off (DEV-884).
	public var supportsContentBlocking: Bool { optionalExports.contentBlocking != nil }

	/// Arx's content blocking for every regular profile. Safe before the engine starts.
	public func setContentBlocking(
		enabled: Bool,
		blockCookieBanners: Bool
	) {
		optionalExports.contentBlocking?(enabled, blockCookieBanners)
	}

	/// Adds extensions' items for a still-current link menu to `menu`, an `NSMenu` (DEV-890).
	public func appendLinkExtensionItems(
		_ context: ChromiumLinkContext,
		on page: ChromiumPage,
		to menu: AnyObject
	) -> Bool {
		guard
			let append = optionalExports.linkExtensionItems,
			linkContextIsCurrent(context, on: page)
		else { return false }

		let pointer = Unmanaged.passUnretained(menu).toOpaque()
		return performIfOpen(on: page) { _, id in append(id, context.token, pointer) } ?? false
	}

	/// The PNG of the icon an extension set for the page's tab with `setIcon` or a declarative
	/// rule, at scale 1 or 2 (DEV-824 follow-up). Nil when it set none, or with an engine built
	/// before the export; the tile then draws the action's or manifest's icon from disk.
	public func extensionActionIcon(
		_ extensionID: String,
		on page: ChromiumPage,
		scale: Float
	) -> Data? {
		guard
			let copy = optionalExports.extensionActionIcon,
			scale == 1 || scale == 2,
			ChromiumExtension.validID(extensionID)
		else { return nil }

		return performIfOpen(on: page) { _, id in
			Self.copyExtensionActionIcon(copy, page: id, extensionID: extensionID, scale: scale)
		} ?? nil
	}

	/// The engine's PNG, read once its size is known. Rejects an empty or oversized icon, and one
	/// that changed size between the calls.
	internal static func copyExtensionActionIcon(
		_ copy: ChromiumExtensionActionIconFunction,
		page: UInt64,
		extensionID: String,
		scale: Float
	) -> Data? {
		extensionID.withCString { extensionID in
			let size = copy(page, extensionID, scale, nil, 0)
			guard (1...maximumExtensionActionIconBytes).contains(size) else { return nil }

			var data = Data(count: size)
			let copied = data.withUnsafeMutableBytes { buffer in
				copy(page, extensionID, scale, buffer.bindMemory(to: UInt8.self).baseAddress, size)
			}
			return copied == size ? data : nil
		}
	}

	/// A 512-pixel PNG fits well under this; the engine refuses larger bitmaps.
	internal static let maximumExtensionActionIconBytes: Int = 2 * 1024 * 1024
}
