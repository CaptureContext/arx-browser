import CustomDump
import Foundation
import Testing
@testable import BrowserCore

internal struct AutomationPasswordSignInTests {
	/// Preferences saved before DEV-708 have no sites, and none are allowed.
	@Test
	internal func olderPreferencesAllowNoSite() throws {
		let data = Data(#"{"isEnabled":true,"clients":[]}"#.utf8)
		let preferences = try JSONDecoder().decode(AutomationPreferences.self, from: data)
		#expect(preferences.agentSignInSites.isEmpty)
		#expect(!preferences.allowsAgentSignIn(profileID: .init(rawValue: UUID()), origin: "https://example.com"))
	}

	/// A site allowed in one profile stays off in every other profile.
	@Test
	internal func sitesArePerProfileAndRoundTrip() throws {
		let profile = Profile.ID(rawValue: UUID())
		let other = Profile.ID(rawValue: UUID())
		let preferences = AutomationPreferences(agentSignInSites: [.init(profileID: profile, origin: "https://example.com")])
		#expect(preferences.allowsAgentSignIn(profileID: profile, origin: "https://example.com"))
		#expect(!preferences.allowsAgentSignIn(profileID: other, origin: "https://example.com"))
		#expect(!preferences.allowsAgentSignIn(profileID: profile, origin: "https://www.example.com"))
		try preferences.validate()

		let decoded = try JSONDecoder().decode(AutomationPreferences.self, from: JSONEncoder().encode(preferences))
		expectNoDifference(decoded, preferences)

		// Revoking clients' grants never turns the user's per-site choice on or off.
		expectNoDifference(preferences.revokingGrants().agentSignInSites, preferences.agentSignInSites)
	}

	@Test
	internal func inexactSitesAreInvalid() {
		let preferences = AutomationPreferences(agentSignInSites: [
			.init(
				profileID: .init(rawValue: UUID()),
				origin: "https://example.com/login"
			),
		])
		#expect(throws: AutomationFailure.invalidRequest) { try preferences.validate() }
	}

	/// The tabs a filled-but-not-signed-in document is closed to.
	@Test
	internal func pageTargetsCoverReadsCapturesAndActions() {
		let tab = UUID()
		let revision = String(repeating: "c", count: 64)
		#expect(AutomationOperation.capture(.init(targetID: tab, expectedRevision: revision, mode: .viewport)).pageTargets == [tab])
		#expect(AutomationOperation.passwordSignIn(.init(
			operationID: UUID(),
			targetID: tab,
			expectedRevision: revision,
			origin: "https://example.com"
		)).pageTargets.isEmpty)
		#expect(AutomationOperation.inventory(cursor: nil, limit: 10).pageTargets.isEmpty)
	}
}
