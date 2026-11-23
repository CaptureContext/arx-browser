import ChromiumBootstrap
import ChromiumBridge
import Darwin
import Foundation

@MainActor
internal enum ChromiumFramework {
	internal static func load(
		at executableURL: URL
	) throws -> (
		api: ArxEngineAPI,
		audioVolume: ChromiumAudioVolumeFunction?,
		releaseProfile: ChromiumReleaseProfileFunction?,
		profileIsLoaded: ChromiumProfileIsLoadedFunction?,
		pageUnloading: ChromiumPageUnloadFunctions?,
		processes: ChromiumProcessFunctions?,
		downloadControls: ChromiumDownloadControlFunctions?,
		networkCapture: ChromiumNetworkCaptureFunctions?,
		navigationState: ChromiumNavigationStateFunctions?,
		pageBadges: ChromiumPageBadgeFunction?
	) {
		guard executableURL.isFileURL else { throw ChromiumError.invalidFileURL }
		guard FileManager.default.fileExists(atPath: executableURL.path)
		else { throw ChromiumError.frameworkMissing(executableURL.path) }

		try verifyBootstrap(ArxVerifyBeforeFrameworkLoad())

		guard let handle = dlopen(executableURL.path, RTLD_NOW | RTLD_LOCAL) else {
			let reason = dlerror().map { String(cString: $0) } ?? "Unknown loader error"
			throw ChromiumError.frameworkLoadFailed(reason)
		}

		try verifyBootstrap(ArxVerifyAfterFrameworkLoad())

		// Chromium registers process-global classes and callbacks. Never dlclose it,
		// including after an ABI mismatch; unloading is not a supported lifecycle.
		guard let symbol = dlsym(handle, "ArxEngineGetAPI")
		else { throw ChromiumError.incompatibleBridge }

		let getAPI = unsafeBitCast(symbol, to: ArxEngineGetAPIFunction.self)
		guard let api = getAPI(UInt32(ARX_ENGINE_ABI_VERSION), MemoryLayout<ArxEngineAPI>.size)
		else { throw ChromiumError.incompatibleBridge }

		let validatedAPI = try validated(api.pointee)

		// DEV-800: an additive export outside the ABI table, so engines built before it still load
		// and only lack per-tab volume.
		let audioVolume = dlsym(handle, ChromiumAudioVolumeSymbol)
			.map { unsafeBitCast($0, to: ChromiumAudioVolumeFunction.self) }

		// DEV-880: the same for idle profile release; without it every profile stays until quit.
		let releaseProfile = dlsym(handle, ChromiumReleaseProfileSymbol)
			.map { unsafeBitCast($0, to: ChromiumReleaseProfileFunction.self) }
		let profileIsLoaded = dlsym(handle, ChromiumProfileIsLoadedSymbol)
			.map { unsafeBitCast($0, to: ChromiumProfileIsLoadedFunction.self) }

		// DEV-873: tab unloading is additive the same way.
		let pageUnloading = ChromiumPageUnloadFunctions.load(from: handle)

		// DEV-898: the Task Manager's process table, likewise additive. Both or neither.
		var processes: ChromiumProcessFunctions?
		if
			let copy = dlsym(handle, ChromiumCopyProcessesSymbol),
			let end = dlsym(handle, ChromiumEndProcessSymbol)
		{
			processes = .init(
				copy: unsafeBitCast(copy, to: ArxEngineCopyProcessesFunction.self),
				end: unsafeBitCast(end, to: ArxEngineEndProcessFunction.self)
			)
		}

		// DEV-892: download pause, resume and removal, likewise additive. All or none.
		var downloadControls: ChromiumDownloadControlFunctions?
		if
			let control = dlsym(handle, ChromiumDownloadControlSymbol),
			let setPaused = dlsym(handle, ChromiumSetDownloadPausedSymbol),
			let remove = dlsym(handle, ChromiumRemoveDownloadSymbol)
		{
			downloadControls = .init(
				control: unsafeBitCast(control, to: ArxEngineDownloadControlFunction.self),
				setPaused: unsafeBitCast(setPaused, to: ArxEngineSetDownloadPausedFunction.self),
				remove: unsafeBitCast(remove, to: ArxEngineRemoveDownloadFunction.self)
			)
		}

		// DEV-924: request details for browser_logs, likewise additive. Both or neither.
		var networkCapture: ChromiumNetworkCaptureFunctions?
		if
			let set = dlsym(handle, ChromiumSetNetworkCaptureSymbol),
			let read = dlsym(handle, ChromiumReadNetworkCaptureSymbol)
		{
			networkCapture = .init(
				set: unsafeBitCast(set, to: ArxEngineSetNetworkCaptureFunction.self),
				read: unsafeBitCast(read, to: ArxEngineReadNetworkCaptureFunction.self)
			)
		}

		// DEV-878: additive too; an older engine reopens tabs without their back/forward history.
		let navigationState: ChromiumNavigationStateFunctions? = {
			guard
				let copy = dlsym(handle, ChromiumNavigationStateFunctions.copySymbol),
				let restore = dlsym(handle, ChromiumNavigationStateFunctions.restoreSymbol),
				let load = dlsym(handle, ChromiumNavigationStateFunctions.loadSymbol)
			else { return nil }

			return .init(
				copy: unsafeBitCast(copy, to: ChromiumNavigationStateFunctions.Copy.self),
				createRestoredPage: unsafeBitCast(restore, to: ChromiumNavigationStateFunctions.CreateRestoredPage.self),
				loadRestoredPage: unsafeBitCast(load, to: ChromiumNavigationStateFunctions.LoadRestoredPage.self)
			)
		}()

		// DEV-907: additive too; an older engine reports no Badging API badges.
		let pageBadges = dlsym(handle, ChromiumPageBadgeSymbol)
			.map { unsafeBitCast($0, to: ChromiumPageBadgeFunction.self) }
		return (
			validatedAPI, audioVolume, releaseProfile, profileIsLoaded, pageUnloading,
			processes, downloadControls, networkCapture, navigationState, pageBadges
		)
	}

	private static func verifyBootstrap(_ status: ArxBootstrapStatus) throws {
		guard status == ARX_BOOTSTRAP_OK else {
			let description = String(cString: ArxBootstrapStatusDescription(status))
			throw ChromiumError.allocatorBootstrapFailed(description)
		}
	}

	internal static func validated(_ result: ArxEngineAPI) throws -> ArxEngineAPI {
		guard
			result.run != nil,
			result.request_quit != nil,
			result.create_page != nil,
			result.destroy_page != nil,
			result.page_view != nil,
			result.navigate != nil,
			result.go_back != nil,
			result.go_forward != nil,
			result.reload != nil,
			result.stop != nil,
			result.prepare_profile != nil,
			result.request_close != nil,
			result.history_count != nil,
			result.history_entry != nil,
			result.go_to_entry != nil,
			result.prepare_private_profile != nil,
			result.release_private_profile != nil,
			result.clear_cache_and_reload != nil,
			result.observe_downloads != nil,
			result.cancel_download != nil,
			result.active_download_count != nil,
			result.cancel_all_downloads != nil,
			result.capture_viewport != nil,
			result.cancel_capture != nil,
			result.run_with_options != nil,
			result.observe_media != nil,
			result.perform_media != nil,
			result.cancel_media != nil,
			result.private_media_metadata_status != nil,
			result.inspect_extensions != nil,
			result.manage_extension != nil,
			result.cancel_extension_request != nil,
			result.load_extension_fixture != nil,
			result.media_source_is_current != nil,
			result.page_close_generation != nil,
			result.request_authorized_close != nil,
			result.consume_authorized_close != nil,
			result.cancel_authorized_close != nil,
			result.lookup_site_icon != nil,
			result.cancel_site_icon != nil,
			result.inspect_page != nil,
			result.validate_inspection_reference != nil,
			result.cancel_inspection != nil,
			result.revoke_inspection_scope != nil,
			result.inspection_document_is_current != nil,
			result.click_inspection_reference != nil,
			result.cancel_reference_click != nil,
			result.perform_inspection_form_action != nil,
			result.cancel_reference_form_action != nil,
			result.scroll_inspection_reference != nil,
			result.link_context_is_current != nil,
			result.dismiss_link_context != nil,
			result.document_capture_available != nil,
			result.capture_document != nil,
			result.cancel_document_capture != nil,
			result.run_document_capture_fixture != nil
		else { throw ChromiumError.incompatibleBridge }
		return result
	}
}

/// `bool ArxEngineSetPageAudioVolume(uint64_t page, double volume)`: main thread, ordinary pages
/// only. Scales the page's local audio output by `volume` in [0, 1] on top of the page's own
/// volume, for every stream it plays now or later, until set again or the page closes. Muting
/// still wins. False for an unknown, private or closed page or a volume outside [0, 1].
internal typealias ChromiumAudioVolumeFunction = @convention(c) (UInt64, Double) -> Bool

internal let ChromiumAudioVolumeSymbol: String = "ArxEngineSetPageAudioVolume"

/// `bool ArxEngineReleaseProfile(const char* key)`: main thread, ordinary profiles only (DEV-880).
/// Lets an idle loaded profile go: native forgets what it keeps for it and drops its
/// keep-alive, and Chromium unloads it. False, changing nothing, while a page, a download,
/// extension work or a consent prompt uses it, for a profile that isn't loaded, and for
/// Default when it's the parent of private profiles. A later `prepare_profile` loads it again.
internal typealias ChromiumReleaseProfileFunction = @convention(c) (UnsafePointer<CChar>?) -> Bool

internal let ChromiumReleaseProfileSymbol: String = "ArxEngineReleaseProfile"

/// `bool ArxEngineProfileIsLoaded(const char* key)`: main thread (DEV-880). Whether Chromium still
/// has a live profile for the ordinary key: Arx holds it, one Arx released isn't destroyed yet,
/// or ProfileManager has it loaded. False for a private key.
internal typealias ChromiumProfileIsLoadedFunction = @convention(c) (UnsafePointer<CChar>?) -> Bool

internal let ChromiumProfileIsLoadedSymbol: String = "ArxEngineProfileIsLoaded"

/// DEV-898: `ArxEngineCopyProcesses` and `ArxEngineEndProcess`, see `ChromiumBridge.h`.
internal struct ChromiumProcessFunctions {
	internal var copy: ArxEngineCopyProcessesFunction
	internal var end: ArxEngineEndProcessFunction

	internal init(
		copy: ArxEngineCopyProcessesFunction,
		end: ArxEngineEndProcessFunction
	) {
		self.copy = copy
		self.end = end
	}
}

internal let ChromiumCopyProcessesSymbol: String = "ArxEngineCopyProcesses"

/// DEV-892: `ArxEngineDownloadControl` and `ArxEngineSetDownloadPaused`, see `ChromiumBridge.h`.
internal struct ChromiumDownloadControlFunctions {
	internal var control: ArxEngineDownloadControlFunction
	internal var setPaused: ArxEngineSetDownloadPausedFunction
	internal var remove: ArxEngineRemoveDownloadFunction

	internal init(
		control: ArxEngineDownloadControlFunction,
		setPaused: ArxEngineSetDownloadPausedFunction,
		remove: ArxEngineRemoveDownloadFunction
	) {
		self.control = control
		self.setPaused = setPaused
		self.remove = remove
	}
}

/// DEV-924: `ArxEngineSetNetworkCapture` and `ArxEngineReadNetworkCapture`, see `ChromiumBridge.h`.
internal struct ChromiumNetworkCaptureFunctions {
	internal var set: ArxEngineSetNetworkCaptureFunction
	internal var read: ArxEngineReadNetworkCaptureFunction

	internal init(
		set: ArxEngineSetNetworkCaptureFunction,
		read: ArxEngineReadNetworkCaptureFunction
	) {
		self.set = set
		self.read = read
	}
}

internal let ChromiumSetNetworkCaptureSymbol: String = "ArxEngineSetNetworkCapture"
internal let ChromiumReadNetworkCaptureSymbol: String = "ArxEngineReadNetworkCapture"

internal let ChromiumDownloadControlSymbol: String = "ArxEngineDownloadControl"
internal let ChromiumSetDownloadPausedSymbol: String = "ArxEngineSetDownloadPaused"
internal let ChromiumRemoveDownloadSymbol: String = "ArxEngineRemoveDownload"
internal let ChromiumEndProcessSymbol: String = "ArxEngineEndProcess"

/// DEV-878: a page's back/forward history, from two exports outside the ABI table.
internal struct ChromiumNavigationStateFunctions {
	/// `size_t ArxEngineCopyNavigationState(uint64_t page, const uint8_t **bytes)`: main thread.
	/// The page's entries around the current one, borrowed until the next call, or 0 for a
	/// private, unknown or empty page.
	internal typealias Copy = @convention(c) (UInt64, UnsafeMutablePointer<UnsafePointer<UInt8>?>?) -> Int

	/// `uint64_t ArxEngineCreateRestoredPage(const char *profile_key, const char *expected_url,
	/// const uint8_t *bytes, size_t size)`: main thread. A new ordinary page holding these
	/// entries, or 0 when they're unreadable or the selected page isn't `expected_url`. Nothing
	/// loads before `LoadRestoredPage`.
	internal typealias CreateRestoredPage = @convention(c) (
		UnsafePointer<CChar>?,
		UnsafePointer<CChar>?,
		UnsafePointer<UInt8>?,
		Int
	) -> UInt64

	/// `bool ArxEngineLoadRestoredPage(uint64_t page)`: main thread. Loads a restored page's
	/// selected entry, once.
	internal typealias LoadRestoredPage = @convention(c) (UInt64) -> Bool

	internal static let copySymbol: String = "ArxEngineCopyNavigationState"
	internal static let restoreSymbol: String = "ArxEngineCreateRestoredPage"
	internal static let loadSymbol: String = "ArxEngineLoadRestoredPage"

	internal let copy: Copy
	internal let createRestoredPage: CreateRestoredPage
	internal let loadRestoredPage: LoadRestoredPage

	internal init(
		copy: Copy,
		createRestoredPage: CreateRestoredPage,
		loadRestoredPage: LoadRestoredPage
	) {
		self.copy = copy
		self.createRestoredPage = createRestoredPage
		self.loadRestoredPage = loadRestoredPage
	}
}

/// DEV-907: `void ArxEngineSetPageBadgeHandler(void (*handler)(void *context, uint64_t page,
/// int32_t kind, uint64_t count), void *context)`: main thread. The handler hears each page's
/// Badging API reports: kind 0 clears, 1 is a badge without a number, 2 a count.
internal typealias ChromiumPageBadgeFunction = @convention(c) (
	(@convention(c) (UnsafeMutableRawPointer?, UInt64, Int32, UInt64) -> Void)?,
	UnsafeMutableRawPointer?
) -> Void

internal let ChromiumPageBadgeSymbol: String = "ArxEngineSetPageBadgeHandler"
