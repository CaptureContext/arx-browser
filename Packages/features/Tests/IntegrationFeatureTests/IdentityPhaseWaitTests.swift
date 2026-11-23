import Foundation
import Testing

@testable import AppFeature

/// DEV-1133: a profile-isolation phase reads only its own navigation, once it has loaded, and
/// gives a new profile's slow first load time while failing soon on a wrong title.
internal struct IdentityPhaseWaitTests {
	private static let url = URL(string: "http://127.0.0.1:8000/identity.html?set=work&phase=ordinary-work-write")!
	private static let earlier = URL(string: "http://127.0.0.1:8000/identity.html?set=&phase=ordinary-work-shared")!

	/// The run that failed: loading for over ten seconds in a new profile, then its own value.
	@Test
	internal func aSlowFirstLoadIsWaitedFor() {
		var wait = IdentityPhaseWait(url: Self.url, title: "work|work")
		for second in 0 ..< 20 {
			#expect(wait.observe(url: Self.url, title: "", isLoading: true, at: .seconds(second)) == .waiting)
		}
		#expect(wait.observe(url: Self.url, title: "work|work", isLoading: false, at: .seconds(20)) == .passed)
	}

	/// The page an earlier phase left, with the very title this one expects, isn't read as this
	/// phase's: not before its navigation starts, nor while it loads.
	@Test
	internal func theEarlierDocumentIsNeverRead() {
		var wait = IdentityPhaseWait(url: Self.url, title: "work|work")
		#expect(wait.observe(url: Self.earlier, title: "work|work", isLoading: false, at: .zero) == .waiting)
		#expect(wait.observe(url: Self.earlier, title: "work|work", isLoading: true, at: .milliseconds(100)) == .waiting)
		#expect(wait.observe(url: Self.url, title: "work|work", isLoading: true, at: .milliseconds(200)) == .waiting)
		#expect(wait.observe(url: Self.url, title: "work|work", isLoading: false, at: .milliseconds(300)) == .passed)
	}

	/// A loaded page with another profile's value is an isolation failure: it fails within the
	/// settled limit, not after the whole loading limit. A title that arrives just after the
	/// load still passes.
	@Test
	internal func aWrongTitleFailsSoon() {
		var wrong = IdentityPhaseWait(url: Self.url, title: "work|work")
		#expect(wrong.observe(url: Self.url, title: "personal|personal", isLoading: false, at: .seconds(1)) == .waiting)
		#expect(wrong.observe(url: Self.url, title: "personal|personal", isLoading: false, at: .milliseconds(2900)) == .waiting)
		#expect(wrong.observe(url: Self.url, title: "personal|personal", isLoading: false, at: .seconds(3)) == .failed)

		var late = IdentityPhaseWait(url: Self.url, title: "work|work")
		#expect(late.observe(url: Self.url, title: "", isLoading: false, at: .seconds(1)) == .waiting)
		#expect(late.observe(url: Self.url, title: "work|work", isLoading: false, at: .milliseconds(1500)) == .passed)
	}

	/// A page that never finishes loading, or never reaches the phase's address, fails at the
	/// loading limit.
	@Test(arguments: [true, false])
	internal func aLoadThatNeverEndsFailsAtTheLimit(reachesTheAddress: Bool) {
		var wait = IdentityPhaseWait(url: Self.url, title: "work|work")
		let shown = reachesTheAddress ? Self.url : Self.earlier
		let limit = IdentityPhaseWait.loadingLimit
		#expect(wait.observe(url: shown, title: "", isLoading: true, at: limit - .milliseconds(100)) == .waiting)
		#expect(wait.observe(url: shown, title: "", isLoading: true, at: limit) == .failed)
	}
}
