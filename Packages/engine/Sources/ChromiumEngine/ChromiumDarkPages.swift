import Foundation

/// `bool ArxEngineSetPageDarkPages(uint64_t page, bool enabled, const char* const* off_sites,
/// size_t count)` (DEV-1020): main thread, once the engine runs. Page 0 sets the default for pages
/// created later; any other page, ordinary or private, gets its own. A darkened page's sites are
/// forced dark by Blink unless they have a dark theme of their own; `off_sites` (lowercased hosts
/// without `www.`, subdomains included) are left as the site draws them. Outside the ABI table,
/// like the other optional exports.
internal typealias ChromiumDarkPagesFunction = @convention(c) (
	UInt64,
	Bool,
	UnsafePointer<UnsafePointer<CChar>?>?,
	Int
) -> Bool

internal let ChromiumDarkPagesSymbol: String = "ArxEngineSetPageDarkPages"

extension ChromiumRuntime {
	/// Whether this engine can darken pages (DEV-1020).
	public var supportsDarkPages: Bool {
		optionalExports.darkPages != nil
	}

	/// Sets whether pages created from now on start dark, before the app sets their own.
	@discardableResult
	public func setDefaultDarkPages(enabled: Bool) -> Bool {
		guard state == .running, let set = optionalExports.darkPages
		else { return false }

		return set(0, enabled, nil, 0)
	}

	/// Sets `page`'s dark pages: on or off, and the sites it stays off on. Applies to the page's
	/// current document and to every later navigation.
	@discardableResult
	public func setDarkPages(
		_ page: ChromiumPage,
		enabled: Bool,
		offSites: [String]
	) -> Bool {
		guard
			state == .running,
			let set = optionalExports.darkPages,
			pages[page.id] === page,
			!page.isClosed
		else { return false }

		let strings: [UnsafeMutablePointer<CChar>?] = offSites.map { strdup($0) }
		defer { strings.forEach { free($0) } }
		let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } }
		return pointers.withUnsafeBufferPointer { buffer in
			set(page.id, enabled, buffer.baseAddress, buffer.count)
		}
	}
}
