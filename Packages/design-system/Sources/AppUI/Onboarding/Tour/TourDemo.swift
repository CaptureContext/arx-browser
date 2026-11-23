import SwiftUI

/// One of the onboarding tour's looping demos.
///
/// A demo is a pure function of time: ``TourDemoScene`` draws the same frame for the same
/// time, so the onboarding page, the snapshots and the website videos all show the same thing.
public enum TourDemo: String, CaseIterable, Hashable, Sendable {
	case peek
	case splitView
	case commandBar
	case chats
	case littleArx

	/// The size every demo is drawn at; pages scale it to fit and videos render it at a multiple.
	public static let canvasSize: CGSize = .init(width: 640, height: 360)

	/// The length of one loop, in seconds.
	public var duration: TimeInterval { 8 }

	/// The moment that best shows the demo, drawn under Reduce Motion and in snapshots.
	public var keyFrame: TimeInterval {
		switch self {
		case .peek: 3.2
		case .splitView: 4
		case .commandBar: 3.4
		case .chats: 5.8
		case .littleArx: 3.4
		}
	}

	/// The page headline.
	public var headline: String {
		switch self {
		case .peek: String.localized(.appUI.onboarding.tour.peek.headline)
		case .splitView: String.localized(.appUI.onboarding.tour.splitView.headline)
		case .commandBar: String.localized(.appUI.onboarding.tour.commandBar.headline)
		case .chats: String.localized(.appUI.onboarding.tour.chats.headline)
		case .littleArx: String.localized(.appUI.onboarding.tour.littleArx.headline)
		}
	}

	/// The one line under the headline.
	public var message: String {
		switch self {
		case .peek: String.localized(.appUI.onboarding.tour.peek.message)
		case .splitView: String.localized(.appUI.onboarding.tour.splitView.message)
		case .commandBar: String.localized(.appUI.onboarding.tour.commandBar.message)
		case .chats: String.localized(.appUI.onboarding.tour.chats.message)
		case .littleArx: String.localized(.appUI.onboarding.tour.littleArx.message)
		}
	}

	/// What the demo shows, read by VoiceOver in place of the animation.
	public var accessibilityDescription: String {
		switch self {
		case .peek: String.localized(.appUI.onboarding.tour.peek.description)
		case .splitView: String.localized(.appUI.onboarding.tour.splitView.description)
		case .commandBar: String.localized(.appUI.onboarding.tour.commandBar.description)
		case .chats: String.localized(.appUI.onboarding.tour.chats.description)
		case .littleArx: String.localized(.appUI.onboarding.tour.littleArx.description)
		}
	}

	/// The exported video's base name, such as `split-view`.
	public var fileName: String {
		switch self {
		case .peek: "peek"
		case .splitView: "split-view"
		case .commandBar: "command-bar"
		case .chats: "chats"
		case .littleArx: "little-arx"
		}
	}
}
