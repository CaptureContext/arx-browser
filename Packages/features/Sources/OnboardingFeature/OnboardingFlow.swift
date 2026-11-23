import BrowserCore
import ChatFeature
import MigrationAssistant
import MigrationAssistantFeature
import _Dependencies

/// The order of onboarding pages and the page each step shows.
///
/// This is the one place a page is added or removed. A step listed here without
/// its own page shows ``OnboardingPlaceholder`` until its ticket replaces it.
public enum OnboardingFlow {
	/// Every page of the full flow, in order. The hand-off to the main window follows the last one.
	///
	/// `connectAgent` appears only when this build ships a provider and this run may use
	/// agents, so test, smoke and headless runs never show it.
	public static var steps: [OnboardingStep] {
		@Dependency(\.agentProviders)
		var agentProviders

		return steps(includesConnectAgent: agentProviders.isEnabled && !agentProviders.clients.isEmpty)
	}

	/// The full flow for a first launch that may set Arx up from iCloud (DEV-1215): `iCloud`
	/// follows `welcome` when `offersICloud`, which AppFeature sets only while the first launch's
	/// Default profile is held back for it, so Settings and later runs never list it.
	public static func steps(offersICloud: Bool) -> [OnboardingStep] {
		var flow: [OnboardingStep] = Self.steps
		guard offersICloud else { return flow }

		flow.insert(.iCloud, at: (flow.firstIndex(of: .welcome) ?? -1) + 1)
		return flow
	}

	public static func steps(includesConnectAgent: Bool) -> [OnboardingStep] {
		[
			.welcome,
			.tour,
			.migration,
			includesConnectAgent ? .connectAgent : nil,
			.outsideAgents,
			.defaultBrowser,
		]
		.compactMap(\.self)
	}

	/// The first step of `steps` that hasn't finished, or the first step when all have.
	public static func resumeStep(
		in steps: [OnboardingStep],
		completed: [OnboardingStep]
	) -> OnboardingStep? {
		steps.first { !completed.contains($0) } ?? steps.first
	}

	internal static func page(
		for step: OnboardingStep,
		destination: MigrationDestination?,
		spaceOptions: [MigrationAssistantFeature.SpaceOption],
		existingData: MigrationAssistantFeature.ExistingData?,
		iCloudResolution: OnboardingICloud.Resolution? = nil
	) -> OnboardingFeature.Page {
		switch step {
		case .welcome:
			.welcome(.init())

		case .iCloud:
			// Once decided, going back shows what happened rather than asking again.
			.iCloud(.init(phase: iCloudResolution.map { .finished($0) } ?? .checking))

		case .migration:
			.migration(
				.init(
					destination: destination,
					spaceOptions: spaceOptions,
					existingData: existingData,
					workspaceCameFromICloud: iCloudResolution?.adoptedWorkspace == true
				)
			)

		case .outsideAgents:
			.outsideAgents(.init())

		case .defaultBrowser:
			.defaultBrowser(.init())

		case .tour:
			.tour(.init())

		case .connectAgent:
			.connectAgent(.init())
		}
	}
}
