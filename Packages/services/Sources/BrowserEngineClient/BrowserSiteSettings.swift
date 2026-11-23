import BrowserCore

extension BrowserEngineClient {
	public typealias SiteSettingsRead = @MainActor @Sendable (
		Profile.ID
	) async throws(SiteSettingsFailure) -> SiteSettings

	public typealias ChangeSiteSettings = @MainActor @Sendable (
		Profile.ID,
		SiteSettingsEdit
	) async throws(SiteSettingsFailure) -> SiteSettings
}
