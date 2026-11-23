import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import PageTranslationClient
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

/// Translate Page, Show Original and Always translate (DEV-904).
@Suite(.dependencies)
@MainActor
internal struct PageTranslationTests {
	private static let tab = BrowserCore.Tab.ID(rawValue: UUID(3))
	private static let profile = Profile.ID(rawValue: UUID(0))

	/// A page whose text the fake engine hands out once, then nothing new.
	private final class FakePage: @unchecked Sendable {
		let lock = NSLock()
		var scripts: [String] = []
		var collected = false
		var applied: [PageTranslationScripts.Piece] = []

		func run(_ script: String) -> BrowserScriptOutcome {
			lock.withLock {
				if script.contains("documentElement.lang") {
					scripts.append("sample")
					return .value(#"{"lang":"fr","text":"Bonjour tout le monde"}"#)
				}
				if script.contains("createTreeWalker") {
					scripts.append("collect")
					defer { collected = true }
					return .value(collected ? "[]" : #"[{"id":1,"text":"Bonjour"},{"id":2,"text":"Merci"}]"#)
				}
				if script.contains("state.originals.set") {
					scripts.append("apply")
					if let start = script.range(of: "for (const { id, text } of "),
						let end = script.range(of: ") {", range: start.upperBound ..< script.endIndex) {
						let json = String(script[start.upperBound ..< end.lowerBound])
						applied += (try? JSONDecoder().decode([PageTranslationScripts.Piece].self, from: Data(json.utf8))) ?? []
					}
					return .value("2")
				}
				scripts.append("restore")
				return .value("2")
			}
		}
	}

	private static func state() -> AppFeature.State {
		let organization = IntegrationFeatureTests().fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[id: tab]

		// DEV-904's behaviour, without DEV-996's `ARX_TRANSLATE` feature flag.
		state.translationFeatureFlag = false
		return state
	}

	private static func translation(availability: PageTranslationClient.Availability = .ready) -> PageTranslationClient {
		.init(
			detectLanguage: { _ in "fr" },
			availability: { _, _ in availability },
			translate: { texts, _, _ in texts.map { $0.uppercased() } },
			targetLanguage: { "en" }
		)
	}

	@Test
	internal func translatePageTranslatesWhatsInViewAndShowOriginalRestoresIt() async throws {
		let page = FakePage()
		let clock = TestClock()
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateScript = { _, script, _, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.translation(.toggle(Self.tab)))
		await store.receive(\.translation.detected)
		await store.receive(\.translation.progressed)
		await store.receive(\.translation.progressed)
		#expect(store.state.translations[Self.tab]?.source == "fr")
		#expect(store.state.translations[Self.tab]?.phase == .translated)
		#expect(store.state.main.siteMenu.translatedTabs == [Self.tab: "fr"])
		#expect(page.applied == [.init(id: 1, text: "BONJOUR"), .init(id: 2, text: "MERCI")])

		// Text that comes into view later is read on the next pass.
		await clock.advance(by: PageTranslationRouting.pollInterval)
		await store.receive(\.translation.progressed)

		await store.send(.translation(.toggle(Self.tab)))
		await store.receive(\.translation.showOriginal)
		await store.finish()
		#expect(store.state.translations[Self.tab] == nil)
		#expect(store.state.main.siteMenu.translatedTabs.isEmpty)
		#expect(page.scripts.last == "restore")
	}

	@Test
	internal func aLanguageThatIsntDownloadedSaysSo() async throws {
		let page = FakePage()
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.pageTranslation = Self.translation(availability: .needsDownload)
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateScript = { _, script, _, _, _ in page.run(script) }
		}
		store.exhaustivity = .off

		await store.send(.translation(.toggle(Self.tab)))
		await store.receive(\.translation.stopped)
		#expect(store.state.translations.isEmpty)
		#expect(store.state.main.sidebar.message?.isEmpty == false)
		#expect(page.applied.isEmpty)
	}

	@Test
	internal func webKitAndUnknownTabsArentTranslated() async throws {
		let store = TestStore(initialState: Self.state()) { AppFeature() } withDependencies: {
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .webKit }
		}
		store.exhaustivity = .off

		await store.send(.translation(.toggle(Self.tab)))
		await store.receive(\.translation.stopped)
		#expect(store.state.translations.isEmpty)
	}

	@Test
	internal func alwaysTranslateStartsOnLoadForItsLanguageOnly() async throws {
		let page = FakePage()
		let state = Self.state()
		state.settings.$translation.withLock { $0[Self.profile].setAlwaysTranslates(true, language: "de") }
		let clock = TestClock()
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.continuousClock = clock
			$0.pageTranslation = Self.translation()
			$0.pageEngines.engine = { _ in .chromium }
			$0.browserEngine.evaluateScript = { _, script, _, _, _ in page.run(script) }
		}
		store.exhaustivity = .off
		let loaded = BrowserNavigation(url: URL(string: "https://lemonde.fr")!, title: "Le Monde")

		await store.send(.main(.viewer(.item(.delegate(.navigation(Self.tab, loaded))))))
		await store.receive(\.translation.start)

		// The page is French, and only German is always translated: it stops quietly.
		await store.receive(\.translation.stopped)
		#expect(store.state.translations.isEmpty)
		#expect(store.state.main.sidebar.message == nil)
		#expect(page.applied.isEmpty)
	}
}
