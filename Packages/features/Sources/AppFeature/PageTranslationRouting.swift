import AppUI
import BrowserCore
import BrowserEngineClient
import Foundation
import MainFeature
import PageTranslationClient
import SettingsFeature
import _ComposableArchitecture

/// Translate Page, Show Original and Always translate (DEV-904). The page's text is read and
/// replaced by scripts the page can't see; text that scrolls into view or appears later is
/// translated as it comes. Nothing waits for a person, so a headless run translates the same
/// way, though only Always translate can start it there.
///
/// Off the `ARX_TRANSLATE` feature flag this is DEV-904's: Apple's Translation, text node by
/// text node, in the engine's developer world, ordinary pages only. On (DEV-996), each Chromium
/// page's language is read after it loads, so the URL bar can say Translation Available; whole
/// sentences go out with their links as runs; the scripts run in the engine's translation world
/// (ABI57), so private windows translate too, without remembering their choices; and the person
/// picks Apple or Google, the quality and the language pages are translated into.
@Reducer
internal struct PageTranslationRouting {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.pageTranslation)
	private var translation

	@Dependency(\.pageEngines)
	private var pageEngines

	@Dependency(\.continuousClock)
	private var clock

	/// How often a translated page is read again for new text.
	internal static let pollInterval: Duration = .milliseconds(1500)

	/// Script limits: at most this many bytes back, and this long.
	private static let resultBytes: Int = 256 * 1024
	private static let timeoutMilliseconds: Int = 5000

	private enum Cancellation: Hashable {
		case translation(BrowserCore.Tab.ID)
		case language(BrowserCore.Tab.ID)
		case languages
	}

	internal var body: some ReducerOf<Self> {
		Pullback(\.translation.toggle) { state, tabID in
			state.translations[tabID] == nil
			? .send(.translation(.start(tabID, automatic: false)))
			: .send(.translation(.showOriginal(tabID)))
		}

		Pullback(\.translation.start) { state, value in
			let (tabID, automatic) = value
			guard state.translations[tabID] == nil else { return .none }
			return start(tabID, automatic: automatic, target: nil, restoresFirst: false, state: &state)
		}

		Pullback(\.translation.translateInto) { state, value in
			let (tabID, target) = value
			guard state.translationFeatureFlag else { return .none }
			let wasTranslated = state.translations.removeValue(forKey: tabID) != nil
			return .concatenate(
				.cancel(id: Cancellation.translation(tabID)),
				start(tabID, automatic: false, target: target, restoresFirst: wasTranslated, state: &state)
			)
		}

		Pullback(\.translation.detected) { state, value in
			let (tabID, source) = value
			state.translations[tabID]?.source = source
			state.translations[tabID]?.phase = .translating
			return .none
		}

		Pullback(\.translation.progressed) { state, tabID in
			state.translations[tabID]?.phase = .translated
			return .none
		}

		Pullback(\.translation.stopped) { state, value in
			let (tabID, problem) = value
			let stopped = state.translations.removeValue(forKey: tabID)
			let wasAutomatic = stopped?.isAutomatic ?? false
			let target = stopped?.target

			// A translation that stops with a problem once it has begun changing the page, its
			// scripts timing out say, would leave the page translated with nothing to show the
			// original: the original comes back as Show Original brings it.
			let ends: Effect<Action>
			if problem != nil, stopped?.phase == .translating || stopped?.phase == .translated {
				ends = restoreOriginal(tabID, state: &state)
			} else {
				ends = .cancel(id: Cancellation.translation(tabID))
			}
			guard let problem, !wasAutomatic else { return ends }

			// The popover offers the download itself, for the pair that was asked for (DEV-996).
			if case .needsDownload = problem, state.translationFeatureFlag {
				if let target { state.pageLanguages[tabID]?.target = target }
				let options = Self.options(state)
				state.pageLanguages[tabID]?.options = options
				state.pageLanguages[tabID]?.availability = .needsDownload
				return ends
			}
			state.showNotice(Self.message(problem), forTab: tabID)
			return ends
		}

		Pullback(\.translation.showOriginal) { state, tabID in

			// Restored even when no translation is running any more: restoring a page that shows
			// its original changes nothing.
			state.translations[tabID] = nil
			return restoreOriginal(tabID, state: &state)
		}

		Pullback(\.translation.restored) { state, tabID in
			state.pendingTranslationRestores.remove(tabID)
			return .none
		}

		Pullback(\.translation.languageRead) { state, value in
			let (tabID, page) = value
			guard state.translationFeatureFlag, state.pageLanguages[tabID]?.url == page.url else { return .none }
			state.pageLanguages[tabID] = page
			var effects: [Effect<Action>] = []

			// Settings changed while the page was read: its availability is read again for them.
			if
				let settings = state.translationSettings,
				let source = page.source,
				settings != .init(target: page.target, options: page.options)
			{
				effects.append(readAvailability(tabID, page: page, source: source, settings: settings))
			}

			// Always translate: a page in one of the profile's languages translates as it loads.
			if
				let source = page.source,
				source != page.target,
				page.availability == .ready,
				state.translations[tabID] == nil,
				let context = state.translationContext(tabID),
				context.preferences.alwaysTranslates(source),
				!context.preferences.neverTranslates(page.url)
			{
				effects.append(.send(.translation(.start(tabID, automatic: true))))
			}
			return .merge(effects)
		}

		Pullback(\.translation.featureFlag) { state, isOn in
			state.translationFeatureFlag = isOn
			guard !isOn else { return .none }
			state.pageLanguages = [:]
			return .none
		}

		Pullback(\.translation.availabilityRead) { state, value in
			let (tabID, page) = value

			// A reply for settings that changed again since is dropped; the newer one follows.
			guard
				state.translationFeatureFlag,
				state.pageLanguages[tabID]?.url == page.url,
				state.translationSettings == .init(target: page.target, options: page.options)
			else { return .none }
			state.pageLanguages[tabID] = page
			return .none
		}

		Pullback(\.translation.languagesLoaded) { state, languages in
			state.translationLanguages = languages
			return .none
		}

		Pullback(\.translation.offer) { state, value in
			let (tabID, action) = value
			guard state.translationFeatureFlag else { return .none }
			switch action {
			case let .translate(target):
				if let target, target != state.translations[tabID]?.target ?? translationTarget(state) {
					return .send(.translation(.translateInto(tabID, target: target)))
				}
				return state.translations[tabID] == nil ? .send(.translation(.start(tabID, automatic: false))) : .none

			case .showOriginal:
				return .send(.translation(.showOriginal(tabID)))

			case let .setNeverTranslateSite(isOn):
				guard
					let context = state.translationContext(tabID),
					let url = state.pageLanguages[tabID]?.url
				else { return .none }

				if context.isPrivate {
					// A private window's choice lasts as long as the window.
					state.privateTranslationChoices[context.profileID, default: .init()].setNeverTranslates(isOn, for: url)
				} else {
					state.settings.$translation.withLock { $0[context.profileID].setNeverTranslates(isOn, for: url) }
				}
				return .none

			case .openLanguageSettings:
				return .concatenate(
					.send(.ui(.openSettings)),
					.send(.settings(.ui(.searchResultChosen(.row(.general, .translation)))))
				)

			case .downloaded:
				// The pair that was downloaded, which Choose Another Language may have picked.
				state.pageLanguages[tabID]?.availability = .ready
				if let target = state.pageLanguages[tabID]?.target, target != translationTarget(state) {
					return .send(.translation(.translateInto(tabID, target: target)))
				}
				return .send(.translation(.start(tabID, automatic: false)))
			}
		}

		// Every window's site menu knows which tabs are translated, and from what; with the
		// feature flag, every window's URL bar has the translation offers.
		Reduce { state, _ in
			state.publishTranslatedTabs()
			state.publishTranslationOffers(target: translationTarget(state), options: Self.options(state))
			return refreshForSettings(&state)
		}

		// A new document isn't translated; Always translate may translate it. With the feature
		// flag, its language is read once it loads, and Always translate follows from that.
		Reduce { state, action in
			guard let (tabID, navigation) = Self.navigation(action) else { return .none }
			var effects: [Effect<Action>] = []
			if state.translations[tabID] != nil, navigation.isLoading {
				state.translations[tabID] = nil
				effects.append(.cancel(id: Cancellation.translation(tabID)))
			}
			let finished = !navigation.isLoading && navigation.errorCode == nil && navigation.engine == .chromium
			if state.translationFeatureFlag {
				guard let url = navigation.url, url.hasWebScheme, finished else {
					if navigation.isLoading || navigation.url?.hasWebScheme != true {
						state.pageLanguages[tabID] = nil
						effects.append(.cancel(id: Cancellation.language(tabID)))
					}
					return .merge(effects)
				}
				guard state.pageLanguages[tabID]?.url != url, state.translationContext(tabID) != nil
				else { return .merge(effects) }

				// The same document at another address (the History API): a translated page's
				// text is no longer the original's, so its language is kept rather than read.
				if state.translations[tabID] != nil, let page = state.pageLanguages[tabID], page.source != nil {
					state.pageLanguages[tabID]?.url = url
					return .merge(effects)
				}

				effects.append(readLanguage(tabID, url: url, state: &state))
				return .merge(effects)
			}
			if
				finished,
				state.translations[tabID] == nil,
				let url = navigation.url,
				url.hasWebScheme,
				let tab = state.workspace.tabs[id: tabID]
			{
				let preferences = state.settings.translation[tab.profileID]
				if !preferences.alwaysLanguages.isEmpty, !preferences.neverTranslates(url) {
					effects.append(.send(.translation(.start(tabID, automatic: true))))
				}
			}
			return .merge(effects)
		}
	}

	/// The language pages are translated into: Settings' choice with the feature flag, else
	/// the person's first preferred language.
	private func translationTarget(_ state: State) -> String {
		state.translationFeatureFlag
		? state.settings.translation.targetLanguage ?? translation.targetLanguage()
		: translation.targetLanguage()
	}

	private static func options(_ state: State) -> PageTranslationClient.Options {
		guard state.translationFeatureFlag else { return .init() }
		return .init(provider: state.settings.translation.provider, quality: state.settings.translation.quality)
	}

	/// When the target, provider or quality changes in Settings, every loaded page's
	/// availability is read again, and Choose Another Language's list too when the provider
	/// changed (DEV-996).
	private func refreshForSettings(_ state: inout State) -> Effect<Action> {
		guard state.translationFeatureFlag else { return .none }
		let snapshot = TranslationSettingsSnapshot(target: translationTarget(state), options: Self.options(state))
		guard state.translationSettings != snapshot else { return .none }
		let previous = state.translationSettings
		state.translationSettings = snapshot
		var effects: [Effect<Action>] = []
		let provider = snapshot.options.provider
		if previous?.options.provider != provider || state.translationLanguages?.provider != provider {
			effects.append(
				.run { [translation] send in
					await send(.translation(.languagesLoaded(.init(provider: provider, codes: await translation.targetLanguages(provider)))))
				}
				.cancellable(id: Cancellation.languages, cancelInFlight: true)
			)
		}

		// Running translations start over from the original with the new provider or quality:
		// none keeps sending text to a provider the person turned away from, and if the new one
		// can't translate (a download, say), the page is its own again and the offer says why.
		if let previous, previous.options != snapshot.options {
			for (tabID, running) in state.translations where running.options != snapshot.options {
				guard let context = state.translationContext(tabID) else { continue }
				state.translations[tabID]?.options = snapshot.options
				effects.append(
					run(
						tabID,
						target: running.target,
						source: running.source ?? state.pageLanguages[tabID]?.source,
						automatic: running.isAutomatic,
						preferences: context.preferences,
						options: snapshot.options,
						segments: true,
						restoresFirst: true
					)
					.cancellable(id: Cancellation.translation(tabID), cancelInFlight: true)
				)
			}
		}
		for (tabID, page) in state.pageLanguages {
			guard let source = page.source else { continue }
			effects.append(readAvailability(tabID, page: page, source: source, settings: snapshot))
		}
		return .merge(effects)
	}

	/// Whether a read page can be translated with `settings` (DEV-996).
	private func readAvailability(
		_ tabID: BrowserCore.Tab.ID,
		page: PageLanguage,
		source: String,
		settings: TranslationSettingsSnapshot
	) -> Effect<Action> {
		.run { [translation] send in
			var page = page
			page.target = settings.target
			page.options = settings.options
			page.availability = source == settings.target
			? .unsupported
			: await translation.pairAvailability(source, settings.target, settings.options)
			await send(.translation(.availabilityRead(tabID, page)))
		}
	}

	/// Stops the tab's translation and puts the page's original text back once its scripts are
	/// free. Until the restore has run, the tab stays in `pendingTranslationRestores`: a
	/// translation started meanwhile cancels this restore and restores first itself, and keeps
	/// the record in turn until its own restore has run, so the restore is never dropped
	/// (DEV-1121, DEV-1175).
	private func restoreOriginal(
		_ tabID: BrowserCore.Tab.ID,
		state: inout State
	) -> Effect<Action> {
		state.pendingTranslationRestores.insert(tabID)
		let flag = state.translationFeatureFlag
		return .concatenate(
			.cancel(id: Cancellation.translation(tabID)),
			.run { [engine, clock] send in
				do {
					_ = try await Self.whenFree(clock: clock, retryingTimeouts: true) { () throws(BrowserDeveloperFailure) in
						flag
						? try await engine.evaluateTranslationScript(
							tabID,
							PageTranslationScripts.restore,
							Self.resultBytes,
							Self.timeoutMilliseconds
						)
						: try await engine.evaluateScript(
							tabID,
							PageTranslationScripts.restore,
							Self.resultBytes,
							Self.timeoutMilliseconds,
							{ true }
						)
					}
				} catch BrowserDeveloperFailure.stale {
					// The tab navigated or closed: a new document shows its own text.
				} catch {
					// Cancelled by a new translation, which restores first itself, or a page that
					// can't run scripts at all: the record stays for the next translation.
					return
				}
				await send(.translation(.restored(tabID)))
			}

			// A translation started meanwhile supersedes a restore still waiting for the page.
			.cancellable(id: Cancellation.translation(tabID), cancelInFlight: true)
		)
	}

	private func start(
		_ tabID: BrowserCore.Tab.ID,
		automatic: Bool,
		target chosen: String?,
		restoresFirst: Bool,
		state: inout State
	) -> Effect<Action> {
		let flag = state.translationFeatureFlag
		let isWebKit = MainActor.assumeIsolated { [pageEngines] in pageEngines.engine(tabID) == .webKit }
		guard
			!isWebKit,
			let context = state.translationContext(tabID),
			flag || !context.isPrivate
		else {
			return automatic ? .none : .send(.translation(.stopped(tabID, .unavailable)))
		}

		let target = chosen ?? translationTarget(state)
		let options = Self.options(state)
		state.translations[tabID] = .init(target: target, isAutomatic: automatic, options: options)

		// Show Original's restore, cancelled by this start if it was still waiting for the page,
		// runs first here; the record goes once it has (`restored`). Restoring a page already
		// restored changes nothing.
		let restoresFirst = restoresFirst || state.pendingTranslationRestores.contains(tabID)
		return run(
			tabID,
			target: target,
			// The language read after the page loaded.
			source: flag ? state.pageLanguages[tabID]?.source : nil,
			automatic: automatic,
			preferences: context.preferences,
			options: options,
			segments: flag,
			restoresFirst: restoresFirst
		)
		.cancellable(id: Cancellation.translation(tabID), cancelInFlight: true)
	}

	/// Reads a loaded page's language and whether it can be translated (DEV-996).
	private func readLanguage(
		_ tabID: BrowserCore.Tab.ID,
		url: URL,
		state: inout State
	) -> Effect<Action> {
		let target = translationTarget(state)
		let options = Self.options(state)
		state.pageLanguages[tabID] = .init(url: url, target: target, options: options)
		return .run { [engine, translation, clock] send in
			var page = PageLanguage(url: url, target: target, options: options)

			// Many pages loading at once can find the engine's translation scripts busy: wait
			// and ask again rather than taking the page for one whose language can't be told.
			var outcome: BrowserScriptOutcome?
			for attempt in 0 ..< 10 {
				do {
					outcome = try await engine.evaluateTranslationScript(
						tabID,
						PageTranslationScripts.sample,
						16 * 1024,
						Self.timeoutMilliseconds
					)
					break
				} catch let failure as BrowserDeveloperFailure where failure == .busy && attempt < 9 {
					try await clock.sleep(for: .milliseconds(250 * (attempt + 1)))
				} catch {
					break
				}
			}
			if
				case let .value(json) = outcome,
				let sample = try? JSONDecoder().decode(PageTranslationScripts.Sample.self, from: Data(json.utf8)),
				let detected = translation.detectLanguage(sample.text) ?? (sample.lang.isEmpty ? nil : sample.lang)
			{
				let source = PageTranslationClient.baseLanguage(detected)
				page.source = source
				if source != target {
					page.availability = await translation.pairAvailability(source, target, options)
				}
			}
			await send(.translation(.languageRead(tabID, page)))
		}
		.cancellable(id: Cancellation.language(tabID), cancelInFlight: true)
	}

	/// Reads the page's language, then translates what's in view and keeps translating what
	/// comes into view, until the page changes or Show Original.
	private func run(
		_ tabID: BrowserCore.Tab.ID,
		target: String,
		source known: String?,
		automatic: Bool,
		preferences: ProfileTranslationPreferences,
		options: PageTranslationClient.Options,
		segments: Bool,
		restoresFirst: Bool
	) -> Effect<Action> {
		.run { [engine, translation, clock] send in
			let evaluateOnce: @Sendable (String) async throws(BrowserDeveloperFailure) -> BrowserScriptOutcome = { script throws(BrowserDeveloperFailure) in
				segments
				? try await engine.evaluateTranslationScript(tabID, script, Self.resultBytes, Self.timeoutMilliseconds)
				: try await engine.evaluateScript(tabID, script, Self.resultBytes, Self.timeoutMilliseconds, { true })
			}

			// Another reading of the page, as the app smoke's checks every 100 ms, can find its
			// scripts busy: the translation waits for them rather than stopping halfway with the
			// page translated (DEV-1175). A translation cancelled by Show Original while it waited for
			// the provider runs no more scripts, so it never applies text over the restored page.
			let evaluate: @Sendable (String) async throws -> BrowserScriptOutcome = { script in
				try Task.checkCancellation()
				return try await Self.whenFree(clock: clock) { () throws(BrowserDeveloperFailure) in
					try await evaluateOnce(script)
				}
			}
			var source = known
			do {
				// Choose Another Language and a new provider or quality start from the original text.
				if restoresFirst {
					_ = try await Self.whenFree(clock: clock, retryingTimeouts: true) { () throws(BrowserDeveloperFailure) in
						try await evaluateOnce(PageTranslationScripts.restore)
					}
					await send(.translation(.restored(tabID)))
				}

				if source == nil {
					guard
						case let .value(json) = try await evaluate(PageTranslationScripts.sample),
						let sample = try? JSONDecoder().decode(PageTranslationScripts.Sample.self, from: Data(json.utf8))
					else { return await send(.translation(.stopped(tabID, .failed))) }

					source = (translation.detectLanguage(sample.text) ?? (sample.lang.isEmpty ? nil : sample.lang))
						.map(PageTranslationClient.baseLanguage)
				}
				guard let source
				else { return await send(.translation(.stopped(tabID, .unknownLanguage))) }
				guard source != target
				else { return await send(.translation(.stopped(tabID, .sameLanguage))) }
				guard !automatic || preferences.alwaysTranslates(source)
				else { return await send(.translation(.stopped(tabID, nil))) }

				let availability = segments
				? await translation.pairAvailability(source, target, options)
				: await translation.availability(source, target)
				switch availability {
				case .ready: break
				case .needsDownload: return await send(.translation(.stopped(tabID, .needsDownload(source))))
				case .unsupported: return await send(.translation(.stopped(tabID, .unsupported(source))))
				}
				await send(.translation(.detected(tabID, source: source)))

				while !Task.isCancelled {
					let found = segments
					? try await translateSegments(evaluate: evaluate, source: source, target: target, options: options)
					: try await translatePieces(evaluate: evaluate, source: source, target: target)
					guard let found
					else { return await send(.translation(.stopped(tabID, .failed))) }

					await send(.translation(.progressed(tabID)))
					if found { continue }
					try await clock.sleep(for: Self.pollInterval)
				}
			} catch is CancellationError {
				return
			} catch BrowserDeveloperFailure.stale {
				// The page navigated or closed: the new document starts untranslated.
				await send(.translation(.stopped(tabID, nil)))
			} catch let failure as BrowserDeveloperFailure {
				await send(.translation(.stopped(tabID, failure == .unavailable || failure == .unsupported ? .unavailable : .failed)))
			} catch PageTranslationClient.Failure.needsDownload {
				await send(.translation(.stopped(tabID, .needsDownload(source ?? ""))))
			} catch {
				await send(.translation(.stopped(tabID, .failed)))
			}
		}
	}

	/// Runs a script once the page's translation scripts are free (DEV-996). The engine runs one
	/// at a time per page and refuses another as busy: the translating loop's last script, still
	/// running after it was cancelled, or another reading of the page, such as its text being
	/// kept for history search. Showing the original or starting over from it must not be lost to
	/// that, however long it lasts (DEV-1132): it asks again until the page is free, the tab
	/// navigates or closes (`stale`), or the effect is cancelled, by a new translation say.
	/// `retryingTimeouts` asks again after a script that timed out too, for the restore, which
	/// changes nothing when it runs twice: a loaded Mac can take longer than the limit.
	internal static func whenFree(
		clock: any Clock<Duration>,
		retryingTimeouts: Bool = false,
		_ evaluate: () async throws(BrowserDeveloperFailure) -> BrowserScriptOutcome
	) async throws -> BrowserScriptOutcome {
		var attempt = 0
		while true {
			do {
				return try await evaluate()
			} catch .busy {
				attempt += 1
				try await clock.sleep(for: retryDelay(attempt))
			} catch .timedOut where retryingTimeouts {
				attempt += 1
				try await clock.sleep(for: retryDelay(attempt))
			}
		}
	}

	/// How long `whenFree` waits before its `attempt`th retry: 100 ms more each time up to half a
	/// second, plus an offset under 100 ms that differs from one attempt to the next. Whatever
	/// keeps the page busy may read it in a steady rhythm, as the app smoke's checks do every
	/// 100 ms; retries on a steady rhythm of their own can fall into step with it and find the
	/// page busy every time (DEV-1132).
	internal static func retryDelay(_ attempt: Int) -> Duration {
		.milliseconds(100 * min(attempt, 5) + (attempt * 37) % 100)
	}

	/// DEV-904: the text nodes in view, each translated alone. Whether any were found; nil when
	/// the page couldn't be read.
	private func translatePieces(
		evaluate: @Sendable (String) async throws -> BrowserScriptOutcome,
		source: String,
		target: String
	) async throws -> Bool? {
		guard
			case let .value(json) = try await evaluate(PageTranslationScripts.collect()),
			let pieces = try? JSONDecoder().decode([PageTranslationScripts.Piece].self, from: Data(json.utf8))
		else { return nil }

		guard !pieces.isEmpty else { return false }
		let texts = try await translation.translate(pieces.map(\.text), source, target)
		let translated = zip(pieces, texts).map { PageTranslationScripts.Piece(id: $0.id, text: $1) }
		for batch in PageTranslationScripts.batches(translated) {
			_ = try await evaluate(PageTranslationScripts.apply(batch))
		}
		return true
	}

	/// DEV-996: the blocks in view, each sentence whole with its runs. Whether any were found;
	/// nil when the page couldn't be read.
	private func translateSegments(
		evaluate: @Sendable (String) async throws -> BrowserScriptOutcome,
		source: String,
		target: String,
		options: PageTranslationClient.Options
	) async throws -> Bool? {
		guard
			case let .value(json) = try await evaluate(PageTranslationScripts.collectSegments()),
			let segments = try? JSONDecoder().decode([PageTranslationScripts.Segment].self, from: Data(json.utf8))
		else { return nil }

		guard !segments.isEmpty else { return false }
		let arranged = try await translation.translateSegments(segments.map(\.runs), source, target, options)
		let translated = zip(segments, arranged).compactMap { segment, arrangement in
			arrangement.map { PageTranslationScripts.TranslatedSegment(id: segment.id, texts: $0.texts, order: $0.order) }
		}
		for batch in PageTranslationScripts.segmentBatches(translated) {
			_ = try await evaluate(PageTranslationScripts.applySegments(batch))
		}
		return true
	}

	private static func navigation(_ action: Action) -> (BrowserCore.Tab.ID, BrowserNavigation)? {
		switch action {
		case let .main(.viewer(.item(.delegate(.navigation(tabID, navigation))))),
			let .main(.viewer(.panes(.element(_, .item(.delegate(.navigation(tabID, navigation))))))),
			let .windows(.element(_, .viewer(.item(.delegate(.navigation(tabID, navigation)))))),
			let .windows(.element(_, .viewer(.panes(.element(_, .item(.delegate(.navigation(tabID, navigation)))))))):
			(tabID, navigation)

		default:
			nil
		}
	}

	internal static func message(_ problem: PageTranslationProblem) -> String {
		switch problem {
		case .unavailable: String.localized(.appUI.translation.unavailable)
		case .unknownLanguage: String.localized(.appUI.translation.unknownLanguage)
		case .sameLanguage: String.localized(.appUI.translation.sameLanguage)
		case let .unsupported(language): String.localized(.appUI.translation.unsupported(languageName(language)))
		case let .needsDownload(language): String.localized(.appUI.translation.needsDownload(languageName(language)))
		case .failed: String.localized(.appUI.translation.failed)
		}
	}

	/// A language's name in the person's own language, such as "French".
	internal static func languageName(_ code: String) -> String {
		Locale.current.localizedString(forIdentifier: code) ?? code
	}
}

/// The tab a translation is for: its profile, whether it's private, and the Never and Always
/// choices that apply to it.
internal struct TranslationContext: Equatable {
	internal var profileID: Profile.ID
	internal var isPrivate: Bool
	internal var preferences: ProfileTranslationPreferences
}

extension AppFeature.State {
	/// An ordinary tab, or with the feature flag a private window's tab, which follows the
	/// choices of the profile that opened its window plus its own, which aren't saved (DEV-996).
	internal func translationContext(_ tabID: BrowserCore.Tab.ID) -> TranslationContext? {
		if let tab = workspace.tabs[id: tabID] {
			return .init(profileID: tab.profileID, isPrivate: false, preferences: settings.translation[tab.profileID])
		}
		guard translationFeatureFlag else { return nil }
		for window in windows where window.isPrivate {
			guard let tab = window.sidebar.organization.tabs[id: tabID] else { continue }
			let opener = window.privateOpenerProfileID.map { settings.translation[$0] } ?? .init()
			let own = privateTranslationChoices[tab.profileID] ?? .init()
			return .init(profileID: tab.profileID, isPrivate: true, preferences: opener.adding(own))
		}
		return nil
	}

	/// The translated tabs and their source languages, for every window's site menu.
	internal mutating func publishTranslatedTabs() {
		var translated: [BrowserCore.Tab.ID: String] = [:]
		for (id, translation) in translations {
			if let source = translation.source { translated[id] = source }
		}
		if main.siteMenu.translatedTabs != translated { main.siteMenu.translatedTabs = translated }
		for id in windows.ids where windows[id: id]?.siteMenu.translatedTabs != translated {
			windows[id: id]?.siteMenu.translatedTabs = translated
		}
	}

	/// Translation Available and the popover's state for every tab with something to offer,
	/// for every window's URL bar (DEV-996). Languages of tabs that are gone are forgotten, and
	/// so are private windows' choices once their windows are.
	internal mutating func publishTranslationOffers(
		target: String,
		options: PageTranslationClient.Options
	) {
		var offers: [BrowserCore.Tab.ID: PageTranslationOffer] = [:]
		if translationFeatureFlag {
			for tabID in Set(pageLanguages.keys).union(translations.keys) {
				guard let context = translationContext(tabID) else {
					pageLanguages[tabID] = nil
					continue
				}
				if let offer = translationOffer(tabID, context: context, target: target, options: options) {
					offers[tabID] = offer
				}
			}
			if !privateTranslationChoices.isEmpty {
				let open = Set(windows.filter(\.isPrivate).flatMap { $0.sidebar.organization.profiles.map(\.id) })
				for profile in privateTranslationChoices.keys where !open.contains(profile) {
					privateTranslationChoices[profile] = nil
				}
			}
		}
		if main.translationOffers != offers { main.translationOffers = offers }
		for id in windows.ids where windows[id: id]?.translationOffers != offers {
			windows[id: id]?.translationOffers = offers
		}
	}

	private func translationOffer(
		_ tabID: BrowserCore.Tab.ID,
		context: TranslationContext,
		target current: String,
		options: PageTranslationClient.Options
	) -> PageTranslationOffer? {
		let settings = settings.translation
		let page = pageLanguages[tabID]
		let never = page.map { context.preferences.neverTranslates($0.url) } ?? false
		let targets = translationLanguages?.provider == settings.provider ? translationLanguages?.codes ?? [] : []

		// A running translation names the provider it uses.
		let running = translations[tabID]?.options ?? options
		func offer(_ source: String, _ target: String, _ phase: PageTranslationOffer.Phase) -> PageTranslationOffer {
			.init(
				source: source,
				target: target,
				phase: phase,
				provider: running.provider,
				quality: running.quality,
				neverTranslatesSite: never,
				targets: targets
			)
		}

		if let translation = translations[tabID] {
			guard let source = translation.source ?? page?.source else { return nil }
			return offer(source, translation.target, translation.phase == .translated ? .translated : .translating)
		}
		guard let page, let source = page.source, !never else { return nil }

		// A download asked for another language than the usual target keeps that pair.
		if page.availability == .needsDownload, page.options == options, page.target != source {
			return offer(source, page.target, .needsDownload)
		}
		guard source != current else { return nil }

		// Availability is known for the target and options the page was read with; a change
		// in Settings reads it again.
		guard page.target == current, page.options == options
		else { return offer(source, current, .available) }

		switch page.availability {
		case .ready: return offer(source, current, .available)
		case .needsDownload: return offer(source, current, .needsDownload)
		case .unsupported: return nil
		}
	}

	/// Shows a passing notice in the sidebar of the window showing the tab.
	internal mutating func showNotice(
		_ text: String,
		forTab tabID: BrowserCore.Tab.ID
	) {
		guard let windowID = windowShowing(tabID) else { return }
		if windowIsOpen, main.id == windowID {
			main.sidebar.message = text
		} else {
			windows[id: windowID]?.sidebar.message = text
		}
	}
}
