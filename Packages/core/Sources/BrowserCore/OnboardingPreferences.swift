import Foundation

/// Persisted onboarding history.
///
/// Dismissing the introduction and completing a setup step are recorded separately:
/// closing the window must never be read as a finished migration or setup.
public struct OnboardingPreferences: Codable, Equatable, Sendable {
	/// The user reached the end of onboarding, skipped it or closed its window at least once.
	/// AppFeature presents it automatically only while this is `false`; quitting with the
	/// window open leaves it `false`, so the next launch resumes at the first unfinished step.
	public var introductionDismissed: Bool

	/// Setup steps that actually finished. Dismissal never adds entries.
	public var completedSteps: [OnboardingStep]

	/// The stand-in profile a first launch made, until onboarding ends (DEV-841).
	/// Saved here so a relaunch partway through onboarding still knows it's provisional.
	public var provisionalProfile: ProvisionalProfile?

	/// The first launch's Default profile while it's kept on this Mac for onboarding's
	/// "Sync with iCloud" step (DEV-1215): it doesn't upload when that step turns sync on, and
	/// it's removed when iCloud's workspace is adopted. Any other outcome, and onboarding ending
	/// before the step decides, syncs it again. The step is in the flow only while this is set.
	public var heldForICloud: Profile.ID?

	/// The workspace came from iCloud in this onboarding (DEV-1215), so a relaunch partway through
	/// still offers only what iCloud doesn't sync and no clearing. Cleared when onboarding ends.
	public var adoptedICloudWorkspace: Bool

	public init(
		introductionDismissed: Bool = false,
		completedSteps: [OnboardingStep] = [],
		provisionalProfile: ProvisionalProfile? = nil,
		heldForICloud: Profile.ID? = nil,
		adoptedICloudWorkspace: Bool = false
	) {
		self.introductionDismissed = introductionDismissed
		self.completedSteps = completedSteps
		self.provisionalProfile = provisionalProfile
		self.heldForICloud = heldForICloud
		self.adoptedICloudWorkspace = adoptedICloudWorkspace
	}

	public init(from decoder: any Decoder) throws {
		let values = try decoder.container(keyedBy: CodingKeys.self)
		self.introductionDismissed = try values.decodeIfPresent(Bool.self, forKey: .introductionDismissed) ?? false

		// Steps a later version retired (such as `crashReports`, DEV-887) are dropped, not an error.
		let stored: [String] = try values.decodeIfPresent([String].self, forKey: .completedSteps) ?? []
		self.completedSteps = stored.compactMap(OnboardingStep.init(rawValue:))
		self.provisionalProfile = try values.decodeIfPresent(ProvisionalProfile.self, forKey: .provisionalProfile)
		self.heldForICloud = try values.decodeIfPresent(Profile.ID.self, forKey: .heldForICloud)
		self.adoptedICloudWorkspace = try values.decodeIfPresent(Bool.self, forKey: .adoptedICloudWorkspace) ?? false
	}

	public func isCompleted(_ step: OnboardingStep) -> Bool {
		completedSteps.contains(step)
	}

	/// Records a finished step once, keeping the stored order stable.
	public mutating func complete(_ step: OnboardingStep) {
		guard !completedSteps.contains(step) else { return }
		completedSteps.append(step)
	}
}

/// Onboarding pages whose completion is persisted independently of the introduction.
///
/// Raw values are stored in preferences, so keep existing ones when renaming a case. A stored
/// value without a case is dropped when decoding.
/// OnboardingFeature decides which of these the flow shows and in what order.
public enum OnboardingStep: String, Codable, CaseIterable, Sendable {
	/// The welcome page, finished by Get Started.
	case welcome

	/// Setting Arx up from iCloud before the first profile is used (DEV-1215). Finishes when
	/// iCloud's workspace was adopted, iCloud turned out empty, or the person went on without
	/// waiting; Not now doesn't finish it.
	case iCloud

	/// Demos of Peek, Split View, the command bar and Little Arx.
	case tour

	/// Importing data with MigrationAssistant ("Make it yours").
	/// Only a fully completed import records it.
	case migration

	/// Connecting a built-in agent on the user's own plan.
	case connectAgent

	/// Installing the `arx` command-line tool, MCP and agent app setup.
	case outsideAgents

	/// Making Arx the browser for web links.
	case defaultBrowser
}
