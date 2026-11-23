import BrowserCore
import Foundation

extension BrowserEngineClient {
	/// Counts what clearing those kinds since a moment (nil for all time) would remove
	/// from what the engine stores. Kinds the engine doesn't count stay nil.
	public typealias CountBrowsingData = @MainActor @Sendable (
		Profile.ID,
		Set<BrowsingDataKind>,
		Date?
	) async throws(ProfileDataFailure) -> BrowsingDataCounts

	/// Clears those kinds since a moment (nil for all time) from what the engine
	/// stores, and returns the kinds it couldn't fully clear.
	public typealias ClearBrowsingData = @MainActor @Sendable (
		Profile.ID,
		Set<BrowsingDataKind>,
		Date?
	) async throws(ProfileDataFailure) -> Set<BrowsingDataKind>

	/// The site whose data `clearSiteData` removes for a page's address (DEV-633): its
	/// registrable domain, all subdomains included, such as `example.co.uk`.
	public typealias SiteDataScope = @MainActor @Sendable (
		Profile.ID,
		URL
	) async throws(ProfileDataFailure) -> String

	/// Clears one site's `.cookies` (with its site storage) and/or `.cache`, all time,
	/// and returns the kinds the engine couldn't fully clear.
	public typealias ClearSiteData = @MainActor @Sendable (
		Profile.ID,
		URL,
		Set<BrowsingDataKind>
	) async throws(ProfileDataFailure) -> Set<BrowsingDataKind>

	public typealias DownloadSettingsRead = @MainActor @Sendable (
		Profile.ID
	) async throws(ProfileDataFailure) -> DownloadSettings

	/// A folder (nil keeps the current one) and whether to ask where to save each file.
	public typealias ChangeDownloadSettings = @MainActor @Sendable (
		Profile.ID,
		URL?,
		Bool
	) async throws(ProfileDataFailure) -> DownloadSettings
}
