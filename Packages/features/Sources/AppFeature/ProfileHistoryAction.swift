import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserHistoryClient
import BrowserPagePreviewClient
import CommandBarFeature
import Foundation
import MainFeature
import PageTextIndexClient
import _ComposableArchitecture

@CasePathable
public enum ProfileHistoryAction: Sendable {
	case received(BrowserHistoryClient.Outcome, epoch: Int)
	case failed(Profile.ID, BrowserHistoryClient.Failure, epoch: Int)
	case removed(Profile.ID, failed: Bool)

	/// The store answered a removal, or gave up on it.
	case removalFinished(Profile.ID, ProfileHistoryState.PendingRemoval)

	/// A tab's read of its visited page's text, nil when there was none to keep, asked while its
	/// profile's history was at `generation` (DEV-1068).
	case pageTextRead(BrowserCore.Tab.ID, Profile.ID, PageText?, generation: Int)

	/// The store took what other Macs synced into these profiles' history (DEV-984), asked for
	/// at these history epochs.
	case syncApplied([BrowserHistoryClient.Outcome], epochs: [Profile.ID: Int])
}
