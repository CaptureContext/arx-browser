import BrowserCore

extension OnboardingStep {
	/// The step's name, as listed in Settings.
	public var title: String {
		switch self {
		case .welcome: String.localized(.appUI.onboarding.step.welcome)
		case .iCloud: String.localized(.appUI.onboarding.step.iCloud)
		case .tour: String.localized(.appUI.onboarding.step.tour)
		case .migration: String.localized(.appUI.onboarding.step.migration)
		case .connectAgent: String.localized(.appUI.onboarding.step.connectAgent)
		case .outsideAgents: String.localized(.appUI.onboarding.step.outsideAgents)
		case .defaultBrowser: String.localized(.appUI.onboarding.step.defaultBrowser)
		}
	}

	/// The page's headline.
	public var headline: String {
		switch self {
		case .welcome: String.localized(.appUI.onboarding.title)
		case .iCloud: String.localized(.appUI.onboarding.headline.iCloud)
		case .tour: String.localized(.appUI.onboarding.headline.tour)
		case .migration: String.localized(.appUI.onboarding.headline.migration)
		case .connectAgent: String.localized(.appUI.onboarding.headline.connectAgent)
		case .outsideAgents: String.localized(.appUI.onboarding.headline.outsideAgents)
		case .defaultBrowser: String.localized(.appUI.onboarding.headline.defaultBrowser)
		}
	}

	/// The one-line message under the headline.
	public var message: String {
		switch self {
		case .welcome: String.localized(.appUI.onboarding.welcome.tagline)
		case .iCloud: String.localized(.appUI.onboarding.message.iCloud)
		case .tour: String.localized(.appUI.onboarding.message.tour)
		case .migration: String.localized(.appUI.onboarding.message.migration)
		case .connectAgent: String.localized(.appUI.onboarding.message.connectAgent)
		case .outsideAgents: String.localized(.appUI.onboarding.message.outsideAgents)
		case .defaultBrowser: String.localized(.appUI.onboarding.message.defaultBrowser)
		}
	}
}
