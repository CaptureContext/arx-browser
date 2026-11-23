import BrowserCore
import Foundation
import Testing

internal struct ProfileReleaseTests {
	private let shown: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
	private let idle: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
	private let recent: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!)

	@Test
	internal func onlyAnUnusedProfilePastTheGracePeriodIsReleased() {
		let now = ContinuousClock.now
		let policy = ProfileRelease(gracePeriod: .seconds(60))
		let lastUse: [Profile.ID: ContinuousClock.Instant] = [
			shown: now.advanced(by: .seconds(-600)),
			idle: now.advanced(by: .seconds(-60)),
			recent: now.advanced(by: .seconds(-59)),
		]

		let released = policy.idle(lastUse: lastUse, use: .init(app: [shown]), now: now)

		#expect(released == [idle])
	}

	@Test(arguments: [
		ProfileUse(app: [Self.target]),
		ProfileUse(pages: [Self.target]),
		ProfileUse(downloads: [Self.target]),
		ProfileUse(work: [Self.target]),
	])
	internal func everyKindOfUseKeepsAProfile(_ use: ProfileUse) {
		let now = ContinuousClock.now
		let policy = ProfileRelease(gracePeriod: .seconds(1))

		#expect(use.holds(Self.target))
		#expect(use.all == [Self.target])
		#expect(policy.idle(lastUse: [Self.target: now.advanced(by: .seconds(-3600))], use: use, now: now).isEmpty)
		#expect(policy.idle(lastUse: [Self.target: now.advanced(by: .seconds(-3600))], use: .init(), now: now) == [Self.target])
	}

	@Test
	internal func aProfileThatIsNotLoadedIsNeverReleased() {
		let now = ContinuousClock.now
		let released = ProfileRelease().idle(lastUse: [:], use: .init(), now: now)

		#expect(released.isEmpty)
	}

	@Test
	internal func theSweepRunsFourTimesPerGracePeriodAndAtMostOnceASecond() {
		#expect(ProfileRelease().gracePeriod == .seconds(60))
		#expect(ProfileRelease().sweepInterval == .seconds(15))
		#expect(ProfileRelease(gracePeriod: .seconds(2)).sweepInterval == .seconds(1))
		#expect(ProfileRelease(gracePeriod: .zero).sweepInterval == .seconds(1))
	}

	private static let target: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000009")!)
}
