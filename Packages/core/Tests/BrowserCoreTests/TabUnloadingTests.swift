import BrowserCore
import CustomDump
import Foundation
import Testing

internal struct TabUnloadingTests {
	private static let now: Date = .init(timeIntervalSinceReferenceDate: 1_000_000)

	private static func id(_ value: Int) -> Tab.ID {
		.init(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!)
	}

	private static func hidden(
		_ value: Int,
		for interval: TimeInterval?,
		facts: TabUnloadEligibility.Facts = .hiddenAndLoaded
	) -> TabUnloadPolicy.Candidate {
		.init(id: id(value), facts: facts, hiddenSince: interval.map { now.addingTimeInterval(-$0) })
	}

	// MARK: - Eligibility

	@Test
	internal func aLoadedHiddenTabNobodyUsesHasNoExemption() {
		#expect(TabUnloadEligibility.exemption(.hiddenAndLoaded) == nil)
	}

	@Test
	internal func eachAppFactKeepsATabLoaded() {
		let facts: [(WritableKeyPath<TabUnloadEligibility.Facts, Bool>, Bool, TabUnloadEligibility.Exemption)] = [
			(\.isLoaded, false, .notLoaded),
			(\.isChat, true, .chat),
			(\.isOnScreen, true, .onScreen),
			(\.isSelectedInSpace, true, .selectedInSpace),
			(\.isInAgentUse, true, .agentUse),
			(\.isKeptLoaded, true, .keptLoaded),
		]
		for (fact, value, exemption) in facts {
			var tab: TabUnloadEligibility.Facts = .hiddenAndLoaded
			tab[keyPath: fact] = value
			#expect(TabUnloadEligibility.exemption(tab) == exemption)
		}
	}

	@Test
	internal func aTabThatIsntLoadedIsNeverAskedForWhateverElseHolds() {
		let facts = TabUnloadEligibility.Facts(
			isLoaded: false,
			isOnScreen: true,
			isSelectedInSpace: true,
			isInAgentUse: true,
			isChat: false
		)
		#expect(TabUnloadEligibility.exemption(facts) == .notLoaded)
	}

	/// DEV-932: a site its profile keeps loaded never unloads, on the timer or under pressure.
	@Test(arguments: [TabUnloadReason.inactive, .memoryPressure])
	internal func aKeptLoadedTabNeverUnloads(reason: TabUnloadReason) {
		var kept: TabUnloadEligibility.Facts = .hiddenAndLoaded
		kept.isKeptLoaded = true
		let due = TabUnloadPolicy.dueTabs(
			[Self.hidden(1, for: 24 * 60 * 60, facts: kept), Self.hidden(2, for: 24 * 60 * 60)],
			delay: .oneHour,
			pressureGrace: .thirtySeconds,
			reason: reason,
			now: Self.now
		)
		#expect(due == [Self.id(2)])
	}

	// MARK: - Timeout

	@Test
	internal func inactiveTabsUnloadOnceHiddenForTheDelayLongestHiddenFirst() {
		let candidates: [TabUnloadPolicy.Candidate] = [
			Self.hidden(1, for: 4 * 60 * 60),
			Self.hidden(2, for: 2 * 60 * 60 - 1),
			Self.hidden(3, for: 9 * 60 * 60),
			Self.hidden(4, for: 2 * 60 * 60),
		]

		let due = TabUnloadPolicy.dueTabs(
			candidates,
			delay: .twoHours,
			pressureGrace: .provisionalDefault,
			reason: .inactive,
			now: Self.now
		)

		#expect(due == [Self.id(3), Self.id(1), Self.id(4)])
	}

	@Test
	internal func aTabWhoseClockHasntStartedIsntDue() {
		let due = TabUnloadPolicy.dueTabs(
			[Self.hidden(1, for: nil)],
			delay: .oneHour,
			pressureGrace: .provisionalDefault,
			reason: .memoryPressure,
			now: Self.now
		)
		#expect(due.isEmpty)
	}

	@Test
	internal func neverKeepsEveryTabLoadedUntilMemoryPressure() {
		let candidates = [Self.hidden(1, for: 30 * 24 * 60 * 60)]

		let due = { (reason: TabUnloadReason) in
			TabUnloadPolicy.dueTabs(
				candidates,
				delay: .never,
				pressureGrace: .oneMinute,
				reason: reason,
				now: Self.now
			)
		}

		#expect(due(.inactive).isEmpty)
		#expect(due(.memoryPressure) == [Self.id(1)])
	}

	@Test
	internal func exemptTabsAreNeverDue() {
		var selected = TabUnloadEligibility.Facts.hiddenAndLoaded
		selected.isSelectedInSpace = true
		var agent = TabUnloadEligibility.Facts.hiddenAndLoaded
		agent.isInAgentUse = true
		let candidates = [
			Self.hidden(1, for: 24 * 60 * 60, facts: selected),
			Self.hidden(2, for: 24 * 60 * 60, facts: agent),
			Self.hidden(3, for: 24 * 60 * 60),
		]

		for reason in [TabUnloadReason.inactive, .memoryPressure] {
			let due = TabUnloadPolicy.dueTabs(
				candidates,
				delay: .oneHour,
				pressureGrace: .provisionalDefault,
				reason: reason,
				now: Self.now
			)
			#expect(due == [Self.id(3)])
		}
	}

	@Test
	internal func theDelaysAreIncreasingAndTheProvisionalDefaultUnloads() {
		let durations = TabUnloadDelay.allCases.compactMap(\.duration)
		#expect(durations == durations.sorted())
		#expect(durations.count == TabUnloadDelay.allCases.count - 1)
		#expect(TabUnloadDelay.provisionalDefault.duration != nil)
	}

	/// DEV-1326: 1, 2, 3, 6 and 12 hours or only under memory pressure, three hours by default,
	/// half the archive default so a tab unloads before it's archived.
	@Test
	internal func delaysDefaultToThreeHoursBeforeTheArchiveDefault() throws {
		let hours: [TimeInterval?] = [1, 2, 3, 6, 12].map { $0 * 3_600 } + [nil]
		expectNoDifference(TabUnloadDelay.allCases.map(\.duration), hours)
		expectNoDifference(TabUnloadDelay.provisionalDefault, .threeHours)
		let archive = try #require(TabArchiveInterval.default.duration)
		#expect(try #require(TabUnloadDelay.provisionalDefault.duration) < archive)
	}

	// MARK: - Memory pressure

	@Test
	internal func criticalPressureUnloadsEveryHiddenTabPastAShortGrace() {
		let grace = TabUnloadPressureGrace.provisionalDefault.duration
		let candidates = [
			Self.hidden(1, for: grace - 1),
			Self.hidden(2, for: grace),
			Self.hidden(3, for: 10 * 60),
		]

		let due = TabUnloadPolicy.dueTabs(
			candidates,
			delay: .twelveHours,
			pressureGrace: .provisionalDefault,
			reason: .memoryPressure,
			now: Self.now
		)

		#expect(due == [Self.id(3), Self.id(2)])
	}

	/// DEV-873: Settings › Advanced › Memory chooses the grace; a shorter delay still wins.
	@Test
	internal func theChosenGraceDecidesWhenLowMemoryUnloads() {
		let candidates = [
			Self.hidden(1, for: 45),
			Self.hidden(2, for: 3 * 60),
			Self.hidden(3, for: 11 * 60),
		]

		let due = { (grace: TabUnloadPressureGrace, delay: TabUnloadDelay) in
			TabUnloadPolicy.dueTabs(
				candidates,
				delay: delay,
				pressureGrace: grace,
				reason: .memoryPressure,
				now: Self.now
			)
		}

		#expect(due(.thirtySeconds, .never) == [Self.id(3), Self.id(2), Self.id(1)])
		#expect(due(.twoMinutes, .never) == [Self.id(3), Self.id(2)])
		#expect(due(.tenMinutes, .twelveHours) == [Self.id(3)])
		// Inactive sweeps ignore the grace.
		#expect(
			TabUnloadPolicy.dueTabs(
				candidates,
				delay: .oneHour,
				pressureGrace: .thirtySeconds,
				reason: .inactive,
				now: Self.now
			).isEmpty
		)
	}

	@Test
	internal func theGracesAreIncreasingAndTheProvisionalDefaultIsAMinute() {
		let durations = TabUnloadPressureGrace.allCases.map(\.duration)
		#expect(durations == durations.sorted())
		#expect(TabUnloadPressureGrace.provisionalDefault.duration == 60)
	}

	// MARK: - Preferences

	@Test
	internal func theDelayDefaultsAndSurvivesSavingAndUnknownValues() throws {
		#expect(BrowserPreferences().tabUnloadDelay == .provisionalDefault)
		#expect(BrowserPreferences().general.tabUnloadDelay == .provisionalDefault)

		var preferences = BrowserPreferences()
		preferences.general.tabUnloadDelay = .twoHours
		let data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: data).tabUnloadDelay == .twoHours)

		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["tabUnloadDelay"] = "eventually"
		let unknown = try JSONSerialization.data(withJSONObject: values)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: unknown).tabUnloadDelay == .provisionalDefault)

		values.removeValue(forKey: "tabUnloadDelay")
		let older = try JSONSerialization.data(withJSONObject: values)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: older).tabUnloadDelay == .provisionalDefault)
	}

	@Test
	internal func theGraceDefaultsAndSurvivesSavingAndUnknownValues() throws {
		#expect(BrowserPreferences().tabUnloadPressureGrace == .oneMinute)
		#expect(BrowserPreferences().general.tabUnloadPressureGrace == .oneMinute)

		var preferences = BrowserPreferences()
		preferences.general.tabUnloadPressureGrace = .fiveMinutes
		let data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: data).tabUnloadPressureGrace == .fiveMinutes)

		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values["tabUnloadPressureGrace"] = "eventually"
		let unknown = try JSONSerialization.data(withJSONObject: values)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: unknown).tabUnloadPressureGrace == .oneMinute)

		values.removeValue(forKey: "tabUnloadPressureGrace")
		let older = try JSONSerialization.data(withJSONObject: values)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: older).tabUnloadPressureGrace == .oneMinute)
	}

	/// DEV-932: off by default, and kept through a save.
	@Test
	internal func keepingPinnedTabsLoadedIsOffUntilChosen() throws {
		#expect(!BrowserPreferences().keepsPinnedTabsLoaded)
		var preferences = BrowserPreferences()
		preferences.general.keepsPinnedTabsLoaded = true
		let data = try JSONEncoder().encode(preferences)
		#expect(try JSONDecoder().decode(BrowserPreferences.self, from: data).keepsPinnedTabsLoaded)

		var values = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
		values.removeValue(forKey: "keepsPinnedTabsLoaded")
		let older = try JSONSerialization.data(withJSONObject: values)
		#expect(try !JSONDecoder().decode(BrowserPreferences.self, from: older).keepsPinnedTabsLoaded)
	}
}

extension TabUnloadEligibility.Facts {
	fileprivate static var hiddenAndLoaded: Self {
		.init(
			isLoaded: true,
			isOnScreen: false,
			isSelectedInSpace: false,
			isInAgentUse: false,
			isChat: false
		)
	}
}
