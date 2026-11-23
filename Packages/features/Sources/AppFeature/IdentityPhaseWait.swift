import Foundation

/// When a profile-isolation phase of the app smoke may read the identity page it navigated to
/// (DEV-1133). Only its own navigation counts: the page must show the phase's own address,
/// which no earlier phase used, and have finished loading. A page's first load in a new profile
/// opens that profile's storage, which can take a while on a busy machine, so a page still
/// loading is waited for longer than one that finished with the wrong title, which is an
/// isolation failure and fails soon.
internal struct IdentityPhaseWait: Equatable, Sendable {
	internal enum Verdict: Equatable, Sendable {
		case waiting
		case passed
		case failed
	}

	/// How long the phase's navigation may take to load.
	internal static let loadingLimit: Duration = .seconds(30)

	/// How long a loaded page may take to show its title, once its script has run.
	internal static let settledLimit: Duration = .seconds(2)

	internal let url: URL
	internal let title: String

	/// When the page was first seen loaded at `url` with another title.
	private var settledSince: Duration?

	internal init(
		url: URL,
		title: String
	) {
		self.url = url
		self.title = title
	}

	/// The verdict for the page as it is `elapsed` after the phase navigated.
	internal mutating func observe(
		url current: URL?,
		title shown: String,
		isLoading: Bool,
		at elapsed: Duration
	) -> Verdict {
		guard current == url, !isLoading else {
			settledSince = nil
			return elapsed < Self.loadingLimit ? .waiting : .failed
		}
		if shown == title { return .passed }

		let since = settledSince ?? elapsed
		settledSince = since
		return elapsed - since < Self.settledLimit && elapsed < Self.loadingLimit ? .waiting : .failed
	}
}
