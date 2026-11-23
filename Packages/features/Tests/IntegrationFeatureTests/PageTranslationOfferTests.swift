import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import PageTranslationClient
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Translation Available, its popover, whole sentences and private windows (DEV-996), with the
/// `ARX_TRANSLATE` feature flag on.
@Suite(.dependencies)
@MainActor
internal struct PageTranslationOfferTests {
	private static let tab = BrowserCore.Tab.ID(rawValue: UUID(3))
	private static let profile = Profile.ID(rawValue: UUID(0))
	private static let privateWindow = UUID(90)
	private static let privateProfile = Profile.ID(rawValue: UUID(91))
	private static let privateTab = BrowserCore.Tab.ID(rawValue: UUID(92))
	private static let loaded = BrowserNavigation(url: URL(string: "https://lemonde.fr/a")!, title: "Le Monde")

	/// A French page whose one sentence, with a link, the fake engine hands out once.
	private final class FakePage: @unchecked Sendable {
		let lock = NSLock()
		var scripts: [String] = []
		var collected = false
		var applied: [PageTranslationScripts.TranslatedSegment] = []

		func run(_ script: String) -> BrowserScriptOutcome {
			lock.withLock {
				if script.contains("documentElement.lang") {
					scripts.append("sample")
					return .value(#"{"lang":"fr","text":"Cliquez ici pour commencer"}"#)
				}
				if script.contains("blockOf") {
					scripts.append("collect")
					defer { collected = true }
					return .value(collected ? "[]" : #"[{"id":1,"runs":[{"text":"Cliquez ","translate":true},{"text":"ici","translate":true},{"text":" pour commencer.","translate":true}]}]"#)
				}
				if script.contains("for (const { id, texts, order } of ") {
					scripts.append("apply")
					if
						let start = script.range(of: "for (const { id, texts, order } of "),
						let end = script.range(of: ") {", range: start.upperBound ..< script.endIndex)
					{
						let json = String(script[start.upperBound ..< end.lowerBound])
						applied += (try? JSONDecoder().decode([PageTranslationScripts.TranslatedSegment].self, from: Data(json.utf8))) ?? []
					}
					return .value("1")
				}
				scripts.append("restore")
				return .value("1")
			}
		}
	}

	private static func state(flag: Bool = true) -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: tab]
		state.translationFeatureFlag = flag
		return state
	}

	/// A private window opened from the ordinary profile, showing one tab.
	private static func withPrivateWindow(_ state: AppFeature.State) -> AppFeature.State {
		var state = state
		let space = Space.ID(rawValue: UUID(93))
		let tab = BrowserCore.Tab(
			id: privateTab,
			profileID: privateProfile,
			restoration: .init(title: "Le Monde", url: loaded.url!)
		)
		let organization = BrowserOrganization(
			profiles: [.init(id: privateProfile, name: "Private")],
			spaces: [.init(id: space, profileID: privateProfile, name: "Private", unpinnedTabs: [tab.id])],
			tabs: [tab]
		)
		var window = MainFeature.State(organization: organization, spaceID: space, isPrivate: true, id: privateWindow)
		window.privateOpenerProfileID = profile
		window.viewer.item.tab = tab
		state.windows.append(window)
		return state
	}

	private static func translation(
		availability: PageTranslationClient.Availability = .ready,
		pairs: (@Sendable (String, String, PageTranslationClient.Options) -> PageTranslationClient.Availability)? = nil,
		calls: LockIsolated<[(String, String, PageTranslationClient.Options)]> = .init([])
	) -> PageTranslationClient {
		.init(
			detectLanguage: { _ in "fr" },
			targetLanguage: { "en" },
			pairAvailability: { source, target, options in pairs?(source, target, options) ?? availability },
			translateSegments: { segments, source, target, options in
				calls.withValue { $0.append((source, target, options)) }
				return segments.map { runs in .init(texts: runs.map { $0.translate ? $0.text.uppercased() : nil }) }
			},
			targetLanguages: { provider in provider == .google ? ["de", "en", "fr", "sw"] : ["de", "en", "fr"] }
		)
	}

	@Test
	internal func aLoadedPageInAnotherLanguageOffersTranslationAndTranslatesWholeSentences() async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let state = Self.state()
		state.settings.$translation.withLock { $0.quality = .faster }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
			$0.browserEngine.evaluateScript = { _, _, _, _, _ in
				Issue.record("Translation never uses the developer world with the feature flag")
				return .undefined
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		let offer = try #require(store.state.main.translationOffers[Self.tab])
		#expect(offer.source == "fr")
		#expect(offer.target == "en")
		#expect(offer.phase == .available)
		#expect(offer.quality == .faster)
		#expect(offer.targets == ["de", "en", "fr"])
		#expect(offer.line == String.localized(.appUI.translation.available))

		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.start)
		await store.receive(\.translation.detected)
		await store.receive(\.translation.progressed)
		await store.receive(\.translation.progressed)

		// The language read after the load is used: no second sample.
		#expect(page.scripts.filter { $0 == "sample" }.count == 1)
		#expect(page.applied == [.init(id: 1, texts: ["CLIQUEZ ", "ICI", " POUR COMMENCER."])])
		#expect(calls.value.map(\.2) == [.init(provider: .apple, quality: .faster)])
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .translated)

		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)
		await store.finish()
		#expect(page.scripts.last == "restore")
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .available)
	}

	/// Show Original while the page's translation scripts are busy, with the translating loop's
	/// last script or another reading of the page, waits for them rather than losing the original:
	/// the engine runs one translation script per page and refuses another as busy.
	@Test
	internal func showOriginalWaitsWhileThePageIsBusy() async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let busy = LockIsolated(2)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in

				// Restoring finds the page busy twice before it's free.
				let isRestore = !script.contains("documentElement.lang") && !script.contains("blockOf")
					&& !script.contains("for (const { id, texts, order } of ")
				if isRestore, busy.withValue({ remaining in defer { remaining -= 1 }; return remaining > 0 }) {
					throw .busy
				}
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)
		await store.receive(\.translation.progressed)

		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)
		#expect(!page.scripts.contains("restore"))
		await clock.advance(by: PageTranslationRouting.retryDelay(1))
		#expect(!page.scripts.contains("restore"))
		await clock.advance(by: PageTranslationRouting.retryDelay(2))
		await store.finish()
		#expect(page.scripts.last == "restore")
		#expect(busy.value <= 0)
	}

	/// Show Original on a page busy for longer than any fixed number of retries, with its text
	/// read for history search and other scripts queued, still restores it once the page is free:
	/// the restore isn't dropped (DEV-1132).
	@Test
	internal func showOriginalOutlastsALongBusySpell() async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let isBusy = LockIsolated(false)
		let restoresTried = LockIsolated(0)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				let isRestore = !script.contains("documentElement.lang") && !script.contains("blockOf")
					&& !script.contains("for (const { id, texts, order } of ")
				if isRestore {
					restoresTried.withValue { $0 += 1 }
					if isBusy.value { throw .busy }
				}
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)

		isBusy.setValue(true)
		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)

		// A minute of a busy page: the restore keeps asking, about twice a second.
		for _ in 0 ..< 60 {
			await clock.advance(by: .seconds(1))
		}
		#expect(restoresTried.value > 100)
		#expect(!page.scripts.contains("restore"))

		isBusy.setValue(false)
		await clock.advance(by: .seconds(1))
		await store.finish()
		#expect(page.scripts.last == "restore", "\(page.scripts)")
		#expect(store.state.translations[Self.tab] == nil)
	}

	/// Show Original on a page read in a steady rhythm, busy for the first half of every 100 ms as
	/// the app smoke's checks keep it, still finds it free: the retries don't fall into step with
	/// the reads (DEV-1132).
	@Test
	internal func showOriginalFindsAGapInARegularlyBusyPage() async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let busySince = LockIsolated<TestClock<Duration>.Instant?>(nil)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				let isRestore = !script.contains("documentElement.lang") && !script.contains("blockOf")
					&& !script.contains("for (const { id, texts, order } of ")
				if isRestore, let start = busySince.value {
					let milliseconds = Int((start.duration(to: clock.now) / .milliseconds(1)).rounded())
					if milliseconds % 100 < 50 { throw .busy }
				}
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)

		busySince.setValue(clock.now)
		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)
		for _ in 0 ..< 15 where !page.scripts.contains("restore") {
			await clock.advance(by: .seconds(1))
		}
		#expect(page.scripts.last == "restore", "\(page.scripts)")
		await store.finish()
	}

	private static func isRestore(_ script: String) -> Bool {
		!script.contains("documentElement.lang") && !script.contains("blockOf")
			&& !script.contains("for (const { id, texts, order } of ")
	}

	/// The app smoke's race (DEV-1175): the smoke reads the translated page every 100 ms, so the
	/// translation's next look for new text finds the page busy. The translation waits for it
	/// rather than stopping with the page translated, and Show Original then brings the original
	/// back. Before, the translation stopped as failed, and Show Original, finding no translation,
	/// did nothing.
	@Test
	internal func aBusyPageDuringATranslationLeavesShowOriginalWorking() async throws {
		let page = FakePage()
		let clock = TestClock()
		let busyLooks = LockIsolated(0)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				if script.contains("blockOf"), busyLooks.withValue({ remaining in defer { remaining -= 1 }; return remaining > 0 }) {
					throw .busy
				}
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)
		await store.receive(\.translation.progressed)

		// The next three looks for new text find the page busy.
		busyLooks.setValue(3)
		let looks = page.scripts.filter { $0 == "collect" }.count
		await clock.advance(by: PageTranslationRouting.pollInterval)
		for _ in 0 ..< 3 {
			await clock.advance(by: .seconds(1))
		}
		#expect(busyLooks.value <= 0)
		#expect(page.scripts.filter { $0 == "collect" }.count > looks, "\(page.scripts)")
		#expect(store.state.translations[Self.tab]?.phase == .translated)
		#expect(store.state.main.sidebar.message == nil)

		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.restored)
		#expect(page.scripts.last == "restore", "\(page.scripts)")
		#expect(store.state.translations[Self.tab] == nil)
		#expect(store.state.pendingTranslationRestores.isEmpty)
		await store.finish()
	}

	/// A translation that stops with a problem once it has changed the page, its scripts timing
	/// out on a loaded Mac say, puts the original back: nothing would be left to show it
	/// (DEV-1175).
	@Test
	internal func aTranslationThatStopsHalfwayPutsTheOriginalBack() async throws {
		let page = FakePage()
		let clock = TestClock()
		let timesOut = LockIsolated(false)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				if script.contains("blockOf"), timesOut.value { throw .timedOut }
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)
		await store.receive(\.translation.progressed)
		#expect(!page.scripts.contains("restore"))

		timesOut.setValue(true)
		await clock.advance(by: PageTranslationRouting.pollInterval)
		await store.receive(\.translation.stopped)
		await store.receive(\.translation.restored)
		#expect(page.scripts.last == "restore", "\(page.scripts)")
		#expect(store.state.translations[Self.tab] == nil)
		#expect(store.state.pendingTranslationRestores.isEmpty)
		#expect(store.state.main.sidebar.message == PageTranslationRouting.message(.failed))
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .available)
		await store.finish()
	}

	/// Show Original's restore, timing out on a loaded Mac, tries again rather than leaving the
	/// page translated: restoring twice changes nothing (DEV-1175).
	@Test
	internal func showOriginalTriesAgainAfterATimeout() async throws {
		let page = FakePage()
		let clock = TestClock()
		let timeouts = LockIsolated(0)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				if Self.isRestore(script), timeouts.withValue({ remaining in defer { remaining -= 1 }; return remaining > 0 }) {
					throw .timedOut
				}
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)

		timeouts.setValue(2)
		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)
		#expect(!page.scripts.contains("restore"))
		#expect(store.state.pendingTranslationRestores.contains(Self.tab))
		await clock.advance(by: PageTranslationRouting.retryDelay(1) + PageTranslationRouting.retryDelay(2))
		await store.receive(\.translation.restored)
		#expect(page.scripts.last == "restore", "\(page.scripts)")
		#expect(store.state.pendingTranslationRestores.isEmpty)
		await store.finish()
	}

	/// Show Original while the provider is still translating what the page showed: the provider
	/// may answer after the restore ran, and none of its text reaches the page (DEV-1175).
	@Test
	internal func showOriginalWhileTheProviderWorksKeepsItsTextOffThePage() async throws {
		let page = FakePage()
		let clock = TestClock()
		let waiting = LockIsolated<CheckedContinuation<Void, Never>?>(nil)
		var translation = Self.translation()
		translation.translateSegments = { segments, _, _, _ in

			// A provider that answers whether or not anyone still waits for it.
			await withCheckedContinuation { waiting.setValue($0) }
			return segments.map { runs in .init(texts: runs.map { $0.text.uppercased() }) }
		}
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = translation
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.detected)
		await waitWhile { waiting.value == nil }
		let provider = try #require(waiting.value)

		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.restored)
		provider.resume()
		for _ in 0 ..< 100 {
			await Task.yield()
		}
		await store.finish()
		#expect(page.applied.isEmpty, "\(page.scripts)")
		#expect(page.scripts.last == "restore", "\(page.scripts)")
	}

	/// A translation that takes over a waiting restore keeps the tab's record until its own
	/// restore has run: were it stopped before then, the next one still restores first
	/// (DEV-1175).
	@Test
	internal func aTakenOverRestoreStaysPendingUntilItRuns() async throws {
		let page = FakePage()
		let clock = TestClock()
		let isBusy = LockIsolated(false)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				if Self.isRestore(script), isBusy.value { throw .busy }
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)

		isBusy.setValue(true)
		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)
		page.lock.withLock { page.collected = false }
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.start)
		await clock.advance(by: .seconds(2))
		#expect(!page.scripts.contains("restore"))
		#expect(store.state.pendingTranslationRestores.contains(Self.tab))

		isBusy.setValue(false)
		await clock.advance(by: .seconds(1))
		await store.receive(\.translation.restored)
		#expect(store.state.pendingTranslationRestores.isEmpty)
		await store.receive(\.translation.progressed)
		#expect(page.scripts.filter { $0 == "restore" }.count == 1, "\(page.scripts)")
		await store.send(.translation(.showOriginal(Self.tab)))
		await store.skipInFlightEffects(strict: false)
	}

	/// A translation started while Show Original still waits for the page supersedes it: the
	/// waiting restore never runs over the new translation. The new one restores first itself,
	/// once the page is free, so nothing of the old one stays (DEV-1121).
	@Test(arguments: [nil, "de"] as [String?])
	internal func aNewTranslationSupersedesAWaitingRestore(target: String?) async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let restoresTried = LockIsolated(0)
		let isBusy = LockIsolated(true)
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ throws(BrowserDeveloperFailure) in
				let isRestore = !script.contains("documentElement.lang") && !script.contains("blockOf")
					&& !script.contains("for (const { id, texts, order } of ")
				if isRestore {
					restoresTried.withValue { $0 += 1 }

					// Busy until the new translation is chosen: the restore keeps waiting.
					if isBusy.value { throw .busy }
				}
				return page.run(script)
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.skipReceivedActions(strict: false)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)
		await store.send(.translation(.offer(Self.tab, .showOriginal)))
		await store.receive(\.translation.showOriginal)
		#expect(restoresTried.value >= 1)
		#expect(!page.scripts.contains("restore"))

		page.lock.withLock { page.collected = false }
		isBusy.setValue(false)
		let before = page.scripts.count
		await store.send(.translation(.offer(Self.tab, .translate(target: target))))
		await store.receive(\.translation.progressed)
		await clock.advance(by: .seconds(10))

		// The original comes back first, then the whole page is translated again.
		let after = Array(page.scripts.dropFirst(before))
		#expect(after.first == "restore", "\(after)")
		#expect(after.contains("apply"), "\(after)")
		#expect(after.filter { $0 == "restore" }.count == 1, "\(after)")
		#expect(after.last != "restore", "\(after)")
		#expect(calls.value.map(\.1) == ["en", target ?? "en"])
		#expect(store.state.pendingTranslationRestores.isEmpty)
		await store.send(.translation(.showOriginal(Self.tab)))
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	internal func chooseAnotherLanguageStartsOverFromTheOriginal() async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.detected)
		await store.receive(\.translation.progressed)
		page.lock.withLock { page.collected = false }

		await store.send(.translation(.offer(Self.tab, .translate(target: "de"))))
		await store.receive(\.translation.translateInto)
		await store.receive(\.translation.detected)
		await store.receive(\.translation.progressed)
		#expect(calls.value.map(\.1) == ["en", "de"])
		#expect(page.scripts.contains("restore"))
		#expect(store.state.translations[Self.tab]?.target == "de")
		#expect(store.state.main.translationOffers[Self.tab]?.target == "de")
		await store.send(.translation(.showOriginal(Self.tab)))
	}

	@Test
	internal func aPairThatNeedsDownloadingOffersTheDownload() async throws {
		let page = FakePage()
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = TestClock()
			$0.pageTranslation = Self.translation(availability: .needsDownload)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .needsDownload)

		// Translate without downloading stops without a notice: the popover offers the download.
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.stopped)
		#expect(store.state.main.sidebar.message == nil)
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .needsDownload)

		await store.send(.translation(.offer(Self.tab, .downloaded)))
		await store.receive(\.translation.start)

		// The fake still has no languages, so it stops again, with the download still offered.
		await store.receive(\.translation.stopped)
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .needsDownload)
	}

	@Test
	internal func anotherLanguageThatNeedsDownloadingKeepsItsPairThroughTheDownload() async throws {
		let page = FakePage()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = TestClock()
			$0.pageTranslation = Self.translation(pairs: { _, target, _ in target == "ja" ? .needsDownload : .ready }, calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.send(.translation(.offer(Self.tab, .translate(target: "ja"))))
		await store.receive(\.translation.translateInto)
		await store.receive(\.translation.stopped)
		let offer = try #require(store.state.main.translationOffers[Self.tab])
		#expect(offer.target == "ja")
		#expect(offer.phase == .needsDownload)

		await store.send(.translation(.offer(Self.tab, .downloaded)))
		await store.receive(\.translation.translateInto)
		#expect(store.state.translations[Self.tab]?.target == "ja")
		// The fake still has no Japanese, so it stops again, offering the same pair.
		await store.receive(\.translation.stopped)
		#expect(store.state.main.translationOffers[Self.tab]?.target == "ja")
	}

	@Test
	internal func aSettingsChangeReadsAvailabilityAndLanguagesAgain() async throws {
		let page = FakePage()
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = TestClock()
			$0.pageTranslation = Self.translation(pairs: { _, target, options in
				options.provider == .apple && target == "de" ? .needsDownload : .ready
			})
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .available)
		#expect(store.state.translationLanguages?.provider == .apple)

		// German needs downloading for Apple: the loaded page says so without a reload.
		await store.send(.settings(.ui(.translationTarget("de"))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.main.translationOffers[Self.tab]?.target == "de")
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .needsDownload)

		// Google has it, and its own list of languages.
		await store.send(.settings(.ui(.translationProvider(.google))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .available)
		#expect(store.state.main.translationOffers[Self.tab]?.provider == .google)
		#expect(store.state.main.translationOffers[Self.tab]?.targets.contains("sw") == true)
	}

	@Test
	internal func switchingFromGoogleToAppleSendsNothingMoreToGoogle() async throws {
		let page = FakePage()
		let clock = TestClock()
		let calls = LockIsolated<[(String, String, PageTranslationClient.Options)]>([])
		let state = Self.state()
		state.settings.$translation.withLock { $0.provider = .google }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation(calls: calls)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)
		#expect(calls.value.map(\.2.provider) == [.google])
		#expect(store.state.main.translationOffers[Self.tab]?.provider == .google)

		// New text appears; the person picks Apple meanwhile.
		page.lock.withLock { page.collected = false }
		await store.send(.settings(.ui(.translationProvider(.apple))))
		await store.receive(\.translation.detected)
		await store.receive(\.translation.progressed)
		#expect(calls.value.map(\.2.provider) == [.google, .apple])
		#expect(store.state.translations[Self.tab]?.options.provider == .apple)
		#expect(store.state.main.translationOffers[Self.tab]?.provider == .apple)
		await store.send(.translation(.showOriginal(Self.tab)))
	}

	@Test
	internal func anAddressChangeOnATranslatedPageKeepsItsLanguage() async throws {
		let page = FakePage()
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = TestClock()
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		await store.send(.translation(.offer(Self.tab, .translate(target: nil))))
		await store.receive(\.translation.progressed)

		// pushState: a new address, the same (translated) document.
		let pushed = BrowserNavigation(url: URL(string: "https://lemonde.fr/b")!, title: "Le Monde")
		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, pushed))))))
		#expect(store.state.pageLanguages[Self.tab]?.url == pushed.url)
		#expect(store.state.pageLanguages[Self.tab]?.source == "fr")
		#expect(page.scripts.filter { $0 == "sample" }.count == 1)
		await store.send(.translation(.showOriginal(Self.tab)))
		#expect(store.state.main.translationOffers[Self.tab]?.phase == .available)
	}

	@Test
	internal func neverTranslateThisSiteHidesTheOfferAndIsSaved() async throws {
		let page = FakePage()
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.receive(\.translation.languageRead)
		#expect(store.state.main.translationOffers[Self.tab] != nil)

		await store.send(.translation(.offer(Self.tab, .setNeverTranslateSite(true))))
		#expect(store.state.main.translationOffers[Self.tab] == nil)
		#expect(store.state.settings.translation[Self.profile].neverSites == ["lemonde.fr"])
	}

	@Test
	internal func aPrivateWindowTranslatesAndForgetsItsChoices() async throws {
		let page = FakePage()
		let clock = TestClock()
		let state = Self.withPrivateWindow(Self.state())
		state.settings.$translation.withLock { $0[Self.profile].setNeverTranslates(true, for: URL(string: "https://spiegel.de")!) }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.windows(.element(id: Self.privateWindow, action: .viewer(.item(.delegate(.navigation(Self.privateTab, Self.loaded)))))))
		await store.receive(\.translation.languageRead)
		#expect(store.state.windows[id: Self.privateWindow]?.translationOffers[Self.privateTab]?.phase == .available)
		// The opener's choices apply in the private window.
		#expect(store.state.translationContext(Self.privateTab)?.preferences.neverSites == ["spiegel.de"])

		await store.send(.translation(.offer(Self.privateTab, .translate(target: nil))))
		await store.receive(\.translation.detected)
		await store.receive(\.translation.progressed)
		#expect(page.applied.count == 1)
		await store.send(.translation(.showOriginal(Self.privateTab)))

		// Its Never Translate This Site holds in the window, and isn't saved.
		await store.send(.translation(.offer(Self.privateTab, .setNeverTranslateSite(true))))
		#expect(store.state.windows[id: Self.privateWindow]?.translationOffers[Self.privateTab] == nil)
		#expect(store.state.privateTranslationChoices[Self.privateProfile]?.neverSites == ["lemonde.fr"])
		#expect(store.state.settings.translation[Self.profile].neverSites == ["spiegel.de"])
		#expect(store.state.settings.translation[Self.privateProfile].isEmpty)

		// Gone with the window.
		var closed = store.state
		closed.windows.remove(id: Self.privateWindow)
		closed.publishTranslationOffers(target: "en", options: .init())
		#expect(closed.privateTranslationChoices.isEmpty)
		#expect(closed.pageLanguages[Self.privateTab] == nil)
		await store.send(.translation(.showOriginal(Self.privateTab)))
	}

	/// DEV-1122: with the feature flag on, Translate Page is enabled in a private window's menu,
	/// listed in its command bar and translates its page. Off, a private window has none of it.
	/// An ordinary window has it either way.
	@Test(arguments: [true, false])
	internal func translatePageInAPrivateWindowFollowsTheFeatureFlag(flag: Bool) async throws {
		let page = FakePage()
		let clock = TestClock()
		var state = Self.withPrivateWindow(Self.state(flag: flag))
		state.main.viewer.item.navigation = Self.loaded
		state.windows[id: Self.privateWindow]?.viewer.item.navigation = Self.loaded
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, script, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		// Every action brings the windows the app's feature flags.
		await store.send(.translation(.featureFlag(flag)))
		let window = try #require(store.state.windows[id: Self.privateWindow])
		#expect(BrowserCommand.translatePage.isEnabled(in: window.commandContext) == flag)
		let menu = try #require(store.state.commandContext(for: .window(Self.privateWindow)))
		#expect(BrowserCommand.translatePage.isEnabled(in: menu) == flag)
		#expect(window.commandCandidates.contains { $0.intent == .command(.translatePage) } == flag)
		#expect(BrowserCommand.translatePage.isEnabled(in: store.state.main.commandContext))

		await store.send(.ui(.command(.translatePage, .window(Self.privateWindow))))
		if flag {
			await store.receive(\.translation.toggle)
			await store.receive(\.translation.progressed)
			#expect(store.state.translations[Self.privateTab] != nil)
			await store.send(.translation(.showOriginal(Self.privateTab)))
		} else {
			await store.finish()
			#expect(store.state.translations.isEmpty)
		}
		await store.skipInFlightEffects(strict: false)
	}

	@Test
	internal func withoutTheFeatureFlagNothingIsReadOnLoad() async throws {
		let store = TestStore(initialState: Self.state(flag: false)) { AppFeature() } withDependencies: {
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateTranslationScript = { _, _, _, _ in
				Issue.record("The translation world is only used with the feature flag")
				return .undefined
			}
		}
		store.exhaustivity = .off

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, Self.loaded))))))
		await store.finish()
		#expect(store.state.pageLanguages.isEmpty)
		#expect(store.state.main.translationOffers.isEmpty)
	}
}
