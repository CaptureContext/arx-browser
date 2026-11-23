#if DEBUG
import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// DEV-996. With the `ARX_TRANSLATE` feature flag on, as it is by default (DEV-1143), a French
/// fixture page says Translation Available, translates in place with its link kept on the
/// translated words, and Show Original brings the French back, in an ordinary window and then a
/// private one. When this Mac hasn't downloaded French and English for Apple's translation, or
/// the flag was turned off, it says so and skips: the smoke doesn't download languages.
@MainActor
internal enum TranslationSmoke {
	internal enum Failure: Error {
		case unavailable
		case notOpened(String)
		case noOffer(String)
		case notTranslated(String)
		case notRestored(String)
		case privateWindow
	}

	private static let title: String = "Arx traduction"

	/// What the page shows: its paragraphs' text and its link.
	private struct Reading: Decodable {
		var text: String
		var link: String
		var href: String
	}

	internal static func run(
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		baseURL: URL
	) async throws {
		guard engine.developerTierIsAvailable() else { throw Failure.unavailable }
		let page = baseURL.deletingLastPathComponent().appending(path: "translate.html")
		guard store.translationFeatureFlag else {
			print("ARX_TRANSLATE_SMOKE_SKIPPED the ARX_TRANSLATE feature flag is off")
			return
		}

		// An ordinary window: a new tab in the main window.
		store.send(.main(.ui(.openCommand(.newTab))))
		try await wait { store.main.commandBar.isPresented }
		store.send(.main(.commandBar(.ui(.queryChanged(page.absoluteString)))))
		store.send(.main(.commandBar(.ui(.selected("destination")))))
		try await wait {
			store.main.viewer.item.navigation.title == title && !store.main.viewer.item.navigation.isLoading
		}
		guard let tab = store.main.viewer.item.tab?.id else { throw Failure.notOpened("main") }

		let offer = try await offered(tab, in: { store.main.translationOffers })
		guard offer.phase == .available else {
			print("ARX_TRANSLATE_SMOKE_SKIPPED French to English isn't downloaded on this Mac (\(offer.phase))")
			store.send(.main(.ui(.closeTab)))
			return
		}
		try await translate(tab, store: store, engine: engine, offers: { store.main.translationOffers })
		print("ARX_TRANSLATE_SMOKE_TRANSLATED")
		store.send(.main(.ui(.closeTab)))

		// A private window, translated through the engine's translation world (ABI57).
		let preparation = store.send(.ui(.newPrivateWindow))
		defer { preparation.cancel() }
		try await wait { store.windows.contains(where: \.isPrivate) }
		guard let window = store.windows.first(where: \.isPrivate)?.id else { throw Failure.privateWindow }
		try await wait { store.windows[id: window]?.commandBar.isPresented == true }
		store.send(.windows(.element(id: window, action: .commandBar(.ui(.queryChanged(page.absoluteString))))))
		store.send(.windows(.element(id: window, action: .commandBar(.ui(.selected("destination"))))))
		try await wait {
			guard let navigation = store.windows[id: window]?.viewer.item.navigation else { return false }
			return navigation.title == title && !navigation.isLoading
		}
		guard let privateTab = store.windows[id: window]?.viewer.item.tab?.id else { throw Failure.notOpened("private") }
		_ = try await offered(privateTab, in: { store.windows[id: window]?.translationOffers ?? [:] })
		try await translate(privateTab, store: store, engine: engine, offers: { store.windows[id: window]?.translationOffers ?? [:] })
		print("ARX_TRANSLATE_SMOKE_PRIVATE")

		store.send(.ui(.requestClosePrivateWindow(window)))
		try await wait { store.windows[id: window] == nil }
		print("ARX_TRANSLATE_SMOKE_SUCCESS")
	}

	/// The tab's Translation Available, once its language is read.
	private static func offered(
		_ tab: BrowserCore.Tab.ID,
		in offers: () -> [BrowserCore.Tab.ID: PageTranslationOffer]
	) async throws -> PageTranslationOffer {
		do {
			try await wait { offers()[tab] != nil }
		} catch {
			throw Failure.noOffer("no offer among \(offers().count)")
		}
		guard let offer = offers()[tab], offer.source == "fr" else { throw Failure.noOffer("\(String(describing: offers()[tab]))") }
		return offer
	}

	/// Translate from the popover, check the page, then Show Original and check it again.
	private static func translate(
		_ tab: BrowserCore.Tab.ID,
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient,
		offers: () -> [BrowserCore.Tab.ID: PageTranslationOffer]
	) async throws {
		let original = try await read(tab, engine: engine)
		store.send(.translation(.offer(tab, .translate(target: nil))))
		do {
			try await wait(seconds: 60) { offers()[tab]?.phase == .translated }

			// The sentence and its link are English; the link is still the link.
			try await wait(seconds: 30) {
				guard let reading = try? await read(tab, engine: engine) else { return false }
				return !reading.text.contains("Bonjour") && !reading.text.contains("Cliquez")
					&& !reading.link.isEmpty && reading.link != original.link && reading.href == original.href
			}
		} catch {
			let reading = try? await read(tab, engine: engine)
			let notice = store.main.sidebar.message ?? store.windows.compactMap(\.sidebar.message).first ?? "no notice"
			throw Failure.notTranslated(
				"\(String(describing: offers()[tab]?.phase)) (\(notice)) \(reading?.text ?? "") [\(reading?.link ?? "")]"
			)
		}

		store.send(.translation(.offer(tab, .showOriginal)))
		do {
			try await wait(seconds: 15) {
				guard let reading = try? await read(tab, engine: engine) else { return false }
				return reading.text == original.text && reading.link == original.link
			}
		} catch {
			let reading = try? await read(tab, engine: engine)

			// Whether a translation started again, or the restore never ran.
			let phase = offers()[tab].map { String(describing: $0.phase) } ?? "no offer"
			let translating = store.translations[tab] != nil
			let pending = store.pendingTranslationRestores.contains(tab)

			// A translation that stopped with a problem says so in the sidebar (DEV-1175).
			let notice = store.main.sidebar.message ?? store.windows.compactMap(\.sidebar.message).first ?? "no notice"
			throw Failure.notRestored(
				"\(phase) translating=\(translating) pendingRestore=\(pending) (\(notice)) \(reading?.text ?? "")"
			)
		}
	}

	private static func read(
		_ tab: BrowserCore.Tab.ID,
		engine: BrowserEngineClient
	) async throws -> Reading {
		let script = """
		const link = document.querySelector('#link');
		return { text: [...document.querySelectorAll('p')].map((p) => p.textContent).join('\\n'),
		  link: link ? link.textContent : '', href: link ? link.getAttribute('href') : '' };
		"""
		guard
			case let .value(json) = try await engine.evaluateTranslationScript(tab, script, 16 * 1024, 5000),
			let reading = try? JSONDecoder().decode(Reading.self, from: Data(json.utf8))
		else { throw Failure.unavailable }

		return reading
	}

	private static func wait(
		seconds: Int = 20,
		_ condition: () async -> Bool
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !(await condition()) {
			guard ContinuousClock.now < deadline else { throw CancellationError() }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}
#endif
