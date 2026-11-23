import AppLinkClient
import BrowserCore
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// Air Traffic Control › App Links in Settings (DEV-857).
@Suite(.dependencies)
@MainActor
internal struct AppLinkSettingsTests {
	private static let work = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
	private static let personal = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

	private func store(
		_ runScript: @escaping @Sendable (AppLinkScript) async -> AppLinkScriptOutcome = { _ in .succeeded(log: nil) },
		dependencies: (inout DependencyValues) -> Void = { _ in }
	) -> TestStoreOf<SettingsFeature> {
		let state = SettingsFeature.State()
		state.$routingPreferences.withLock { $0 = .init() }
		let store = TestStore(initialState: state) { SettingsFeature() } withDependencies: {
			$0.uuid = .incrementing
			$0.appLinks.runScript = runScript
			dependencies(&$0)
		}
		store.exhaustivity = .off
		return store
	}

	@Test
	internal func newHandlerIsSavedNormalized() async {
		let store = store()
		await store.send(.ui(.appLinks(.add(.init(id: UUID(), name: "Claude", scheme: " Claude:// ")))))
		let handlers = store.state.routingPreferences.appLinks.handlers
		#expect(handlers.map(\.scheme) == ["claude"])
		#expect(handlers.first?.id == UUID(0))
		#expect(store.state.appLinks.error == nil)
	}

	@Test
	internal func webSchemesAreRefusedOnTheirRow() async {
		let store = store()
		let draft = AppLinkHandler(id: UUID(), name: "Web", scheme: "https")
		await store.send(.ui(.appLinks(.add(draft))))
		#expect(store.state.routingPreferences.appLinks.handlers.isEmpty)
		#expect(store.state.appLinks.failedHandlerID == draft.id)
		#expect(store.state.appLinks.error == .reservedScheme)
	}

	@Test
	internal func correctedDraftSavesAndClearsItsError() async {
		let store = store()
		var draft = AppLinkHandler(id: UUID(), name: "Web", scheme: "https")
		await store.send(.ui(.appLinks(.add(draft))))
		#expect(store.state.appLinks.failedHandlerID == draft.id)

		draft.scheme = "claude"
		await store.send(.ui(.appLinks(.add(draft))))
		#expect(store.state.routingPreferences.appLinks.handlers.map(\.scheme) == ["claude"])
		#expect(store.state.appLinks.failedHandlerID == nil)
		#expect(store.state.appLinks.error == nil)
	}

	@Test
	internal func testRunsTheProfileScriptWithASampleLink() async {
		let ran = LockIsolated<[AppLinkScript]>([])
		let store = store { script in
			ran.withValue { $0.append(script) }
			return .failed(status: 1, message: "no workspace", log: nil)
		}
		let handler = AppLinkHandler(
			id: UUID(),
			name: "Claude",
			scheme: "claude",
			overrides: [.init(profileID: Self.work, handling: .runScript(#"fxclaude open-url work "$1""#))]
		)
		await store.send(.ui(.appLinks(.add(handler))))
		let id = UUID(0)
		await store.send(.ui(.appLinks(.test(id, profileID: Self.work, profileName: "Work"))))
		await store.receive(\.ui.appLinks.testFinished)

		#expect(ran.value.map(\.link) == ["claude://arx-test/callback?arx-test=1"])
		#expect(ran.value.map(\.script) == [#"fxclaude open-url work "$1""#])
		#expect(ran.value.map(\.profileName) == ["Work"])
		#expect(store.state.appLinks.tests[.init(handlerID: id, profileID: Self.work)]
			== .finished(.failed(status: 1, message: "no workspace", log: nil)))

		// The default opens the app: there's nothing to test.
		await store.send(.ui(.appLinks(.test(id, profileID: nil, profileName: nil))))
		#expect(ran.value.count == 1)
	}

	@Test
	internal func forgetRemovesAnAlwaysAllowedSite() async {
		let store = store()
		var handler = AppLinkHandler(id: UUID(), name: "Claude", scheme: "claude")
		handler.alwaysAllowedOrigins = ["https://claude.ai", "https://example.com"]
		await store.send(.ui(.appLinks(.add(handler))))
		await store.send(.ui(.appLinks(.forget(UUID(0), origin: "https://claude.ai"))))
		#expect(store.state.routingPreferences.appLinks.handlers.first?.alwaysAllowedOrigins == ["https://example.com"])

		await store.send(.ui(.appLinks(.delete(UUID(0)))))
		#expect(store.state.routingPreferences.appLinks.handlers.isEmpty)

		// A late save from the removed row doesn't bring it back.
		handler.id = UUID(0)
		await store.send(.ui(.appLinks(.update(handler))))
		#expect(store.state.routingPreferences.appLinks.handlers.isEmpty)
	}

	// MARK: - App picker (DEV-862)

	private static let claudeApp = AppLinkApplication(
		path: "/Applications/Claude.app",
		bundleID: "com.anthropic.claudefordesktop",
		name: "Claude"
	)

	private static let other = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!)
	private static let fourth = Profile.ID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!)
	private static let elsewhere = AppLinkApplication(path: "/Applications/Elsewhere.app", name: "Elsewhere")

	private static let claudeWork = AppLinkApplication(
		path: "/Users/me/Workspaces/Claude Work.app",
		bundleID: "com.anthropic.claudefordesktop",
		name: "Claude Work"
	)

	@Test
	internal func pickingAnAppFillsTheNewHandlerAndSavesIt() async throws {
		let store = store()
		await store.send(.ui(.appLinks(.newHandler)))
		var draft = try #require(store.state.appLinks.draft)
		#expect(draft.id == UUID(0))

		// Typing a host before a scheme keeps the row open, with no error.
		draft.host = "login"
		await store.send(.ui(.appLinks(.add(draft))))
		#expect(store.state.appLinks.draft?.host == "login")
		#expect(store.state.appLinks.error == nil)
		#expect(store.state.routingPreferences.appLinks.handlers.isEmpty)

		await store.send(.ui(.appLinks(.pickApplication(draft, Self.claudeApp, scheme: "claude"))))
		#expect(store.state.appLinks.draft == nil)
		expectNoDifference(store.state.routingPreferences.appLinks.handlers, [.init(
			id: UUID(1),
			name: "Claude",
			scheme: "claude",
			host: "login",
			application: Self.claudeApp,
			defaultHandling: .openApp(Self.claudeApp)
		)])
	}

	@Test
	internal func pickingAnotherAppKeepsANameYouWroteAndScriptsAsTheyAre() async {
		let store = store()
		let handler = AppLinkHandler(
			id: UUID(),
			name: "Sign-ins",
			scheme: "claude",
			application: Self.claudeApp,
			defaultHandling: .openApp(Self.claudeApp),
			overrides: [
				.init(profileID: Self.work, handling: .runScript("true")),
				.init(profileID: Self.personal, handling: .openApp(Self.claudeApp)),
				.init(profileID: Self.other, handling: .systemDefault),
				.init(profileID: Self.fourth, handling: .openApp(Self.elsewhere)),
			]
		)
		await store.send(.ui(.appLinks(.add(handler))))
		let saved = store.state.routingPreferences.appLinks.handlers[0]
		await store.send(.ui(.appLinks(.pickApplication(saved, Self.claudeWork, scheme: nil))))

		let picked = store.state.routingPreferences.appLinks.handlers[0]
		#expect(picked.name == "Sign-ins")
		#expect(picked.scheme == "claude")
		#expect(picked.application == Self.claudeWork)
		#expect(picked.defaultHandling == .openApp(Self.claudeWork))
		// System Default follows too; an app chosen for one row alone stays.
		#expect(picked.overrides.map(\.handling) == [
			.runScript("true"), .openApp(Self.claudeWork), .openApp(Self.claudeWork), .openApp(Self.elsewhere),
		])

		// System Default clears the app wherever it followed it.
		await store.send(.ui(.appLinks(.pickApplication(picked, nil, scheme: nil))))
		let cleared = store.state.routingPreferences.appLinks.handlers[0]
		#expect(cleared.application == nil)
		#expect(cleared.defaultHandling == .systemDefault)
		#expect(cleared.overrides.map(\.handling) == [.runScript("true"), .systemDefault, .systemDefault, .openApp(Self.elsewhere)])
	}

	@Test
	internal func chooseKeepsTheSchemeWhenTheAppDeclaresIt() async {
		let choice = AppLinkApplicationChoice(application: Self.claudeWork, schemes: ["claude", "claude-work"])
		let store = store(dependencies: { $0.appLinks.chooseApplication = { choice } })

		// Settings names a handler after its scheme until it has a name of its own.
		await store.send(.ui(.appLinks(.add(.init(id: UUID(), name: "claude-work", scheme: "claude-work")))))
		let saved = store.state.routingPreferences.appLinks.handlers[0]
		#expect(saved.name == "claude-work")

		await store.send(.ui(.appLinks(.chooseApplication(saved))))
		await store.receive(\.ui.appLinks.applicationChosen)
		let picked = store.state.routingPreferences.appLinks.handlers[0]
		#expect(picked.name == "Claude Work")
		#expect(picked.scheme == "claude-work")
		#expect(picked.defaultHandling == .openApp(Self.claudeWork))
		#expect(store.state.appLinks.chosenApplications == [choice])
		#expect(store.state.appLinks.schemes(of: Self.claudeWork) == ["claude", "claude-work"])
	}

	@Test
	internal func chooseFillsAnEmptySchemeFromTheApp() async throws {
		let choice = AppLinkApplicationChoice(application: Self.claudeApp, schemes: ["claude"])
		let store = store(dependencies: { $0.appLinks.chooseApplication = { choice } })
		await store.send(.ui(.appLinks(.newHandler)))
		let draft = try #require(store.state.appLinks.draft)
		await store.send(.ui(.appLinks(.chooseApplication(draft))))
		await store.receive(\.ui.appLinks.applicationChosen)
		#expect(store.state.appLinks.draft == nil)
		#expect(store.state.routingPreferences.appLinks.handlers.map(\.scheme) == ["claude"])
	}

	@Test
	internal func otherAppSetsOneProfilesHandling() async {
		let choice = AppLinkApplicationChoice(application: Self.claudeWork, schemes: [])
		let store = store(dependencies: { $0.appLinks.chooseApplication = { choice } })
		await store.send(.ui(.appLinks(.add(.init(
			id: UUID(),
			name: "Claude",
			scheme: "claude",
			overrides: [.init(profileID: Self.work, handling: .systemDefault)]
		)))))
		await store.send(.ui(.appLinks(.chooseApplicationForHandling(UUID(0), profileID: Self.work))))
		await store.receive(\.ui.appLinks.applicationChosen)
		let handler = store.state.routingPreferences.appLinks.handlers[0]
		#expect(handler.defaultHandling == .systemDefault)
		#expect(handler.overrides.map(\.handling) == [.openApp(Self.claudeWork)])
		#expect(handler.applications == [Self.claudeWork])
	}

	@Test
	internal func cancelledChooseChangesNothing() async {
		let store = store(dependencies: { $0.appLinks.chooseApplication = { nil } })
		await store.send(.ui(.appLinks(.add(.init(id: UUID(), name: "Claude", scheme: "claude")))))
		let before = store.state.routingPreferences
		await store.send(.ui(.appLinks(.chooseApplicationForHandling(UUID(0), profileID: nil))))
		await store.receive(\.ui.appLinks.applicationChosen)
		#expect(store.state.routingPreferences == before)
		#expect(store.state.appLinks.chosenApplications.isEmpty)
	}

	@Test
	internal func pickerListsRegisteredAndInstalledApps() async {
		let looked = LockIsolated(0)
		let installed = [AppLinkApplicationChoice(application: Self.claudeApp, schemes: ["claude"])]
		let registered = [AppLinkApplicationChoice(application: Self.claudeWork, schemes: [])]
		let store = store(dependencies: {
			$0.appLinks.installedApplications = {
				looked.withValue { $0 += 1 }
				return installed
			}
			$0.appLinks.applicationsForScheme = { scheme in scheme == "claude" ? registered : [] }
		})
		await store.send(.ui(.appLinks(.appeared)))
		await store.receive(\.ui.appLinks.installedApplicationsLoaded)
		await store.send(.ui(.appLinks(.appeared)))
		#expect(looked.value == 1)
		#expect(store.state.appLinks.installedApplications == installed)

		await store.send(.ui(.appLinks(.schemeShown("Claude://"))))
		#expect(store.state.appLinks.registeredApplications["claude"] == registered)
		await store.send(.ui(.appLinks(.schemeShown("https"))))
		#expect(store.state.appLinks.registeredApplications["https"] == nil)
	}

	@Test
	internal func draftRowSavingAgainAsItGoesAwayAddsNothing() async throws {
		let store = store()
		await store.send(.ui(.appLinks(.newHandler)))
		var draft = try #require(store.state.appLinks.draft)
		draft.scheme = "claude"
		await store.send(.ui(.appLinks(.saveDraft(draft))))
		await store.send(.ui(.appLinks(.saveDraft(draft))))
		#expect(store.state.routingPreferences.appLinks.handlers.map(\.scheme) == ["claude"])
		#expect(store.state.appLinks.draft == nil)
	}

	@Test
	internal func pickedAppGetsABookmark() async {
		let store = store(dependencies: {
			$0.appLinks.bookmarked = { app in
				var app = app
				app.bookmark = Data([7])
				return app
			}
		})
		await store.send(.ui(.appLinks(.add(.init(id: UUID(), name: "Claude", scheme: "claude")))))
		let saved = store.state.routingPreferences.appLinks.handlers[0]
		await store.send(.ui(.appLinks(.pickApplication(saved, Self.claudeApp, scheme: nil))))
		let picked = store.state.routingPreferences.appLinks.handlers[0]
		#expect(picked.application?.bookmark == Data([7]))
		#expect(picked.defaultHandling.application?.bookmark == Data([7]))
	}

	@Test
	internal func deletingAFailedHandlerKeepsTheDraftAndThePickerLists() async throws {
		let installed = [AppLinkApplicationChoice(application: Self.claudeApp, schemes: ["claude"])]
		let store = store(dependencies: { $0.appLinks.installedApplications = { installed } })
		await store.send(.ui(.appLinks(.appeared)))
		await store.receive(\.ui.appLinks.installedApplicationsLoaded)
		await store.send(.ui(.appLinks(.add(.init(id: UUID(), name: "Claude", scheme: "claude")))))
		var saved = store.state.routingPreferences.appLinks.handlers[0]
		saved.host = "Has Spaces"
		await store.send(.ui(.appLinks(.update(saved))))
		#expect(store.state.appLinks.error == .invalidHost)
		await store.send(.ui(.appLinks(.newHandler)))

		await store.send(.ui(.appLinks(.delete(saved.id))))
		#expect(store.state.appLinks.error == nil)
		#expect(store.state.appLinks.failedHandlerID == nil)
		#expect(store.state.appLinks.draft != nil)
		#expect(store.state.appLinks.installedApplications == installed)
	}

	// MARK: - Card layout (DEV-862 follow-up)

	@Test
	internal func profileRoutesComeFirstAndAddProfileLandsJustAboveOtherwise() async throws {
		let store = store()
		await store.send(.ui(.appLinks(.add(.init(
			id: UUID(),
			name: "Claude",
			scheme: "claude",
			defaultHandling: .runScript("otherwise"),
			overrides: [.init(profileID: Self.work, handling: .systemDefault)]
		)))))
		let id = UUID(0)
		#expect(AppLinkEditor.routes(of: store.state.routingPreferences.appLinks.handlers[0])
			== [.profile(Self.work), .otherwise])

		await store.send(.ui(.appLinks(.addProfileRoute(id, Self.personal))))
		let handler = store.state.routingPreferences.appLinks.handlers[0]
		#expect(AppLinkEditor.routes(of: handler) == [.profile(Self.work), .profile(Self.personal), .otherwise])
		// It starts as Otherwise does.
		#expect(handler.overrides.last?.handling == .runScript("otherwise"))

		// A profile has one route.
		await store.send(.ui(.appLinks(.addProfileRoute(id, Self.personal))))
		#expect(store.state.routingPreferences.appLinks.handlers[0].overrides.count == 2)

		await store.send(.ui(.appLinks(.removeProfileRoute(id, Self.work))))
		#expect(AppLinkEditor.routes(of: store.state.routingPreferences.appLinks.handlers[0])
			== [.profile(Self.personal), .otherwise])
	}

	@Test
	internal func tabFillsAnEmptyScriptWithTheExampleOnly() async throws {
		let store = store()
		await store.send(.ui(.appLinks(.add(.init(
			id: UUID(),
			name: "Claude",
			scheme: "claude",
			defaultHandling: .runScript(" "),
			overrides: [
				.init(profileID: Self.work, handling: .runScript("")),
				.init(profileID: Self.personal, handling: .runScript("mine \"$1\"")),
			]
		)))))
		let id = UUID(0)
		await store.send(.ui(.appLinks(.useScriptExample(id, profileID: Self.work))))
		await store.send(.ui(.appLinks(.useScriptExample(id, profileID: Self.personal))))
		await store.send(.ui(.appLinks(.useScriptExample(id, profileID: nil))))
		let handler = store.state.routingPreferences.appLinks.handlers[0]
		#expect(AppLinkEditor.scriptExample == #"fxclaude open-url work "$1""#)
		#expect(handler.overrides.map(\.handling) == [
			.runScript(AppLinkEditor.scriptExample),
			.runScript(#"mine "$1""#),
		])
		#expect(handler.defaultHandling == .runScript(AppLinkEditor.scriptExample))
	}

	@Test
	internal func tabNeverTurnsAnAppRouteIntoAScript() async throws {
		let store = store()
		await store.send(.ui(.appLinks(.add(.init(id: UUID(), name: "Claude", scheme: "claude")))))
		await store.send(.ui(.appLinks(.useScriptExample(UUID(0), profileID: nil))))
		#expect(store.state.routingPreferences.appLinks.handlers[0].defaultHandling == .systemDefault)
	}

	@Test
	internal func pickerSearchFiltersByNameSchemeAndBundleID() {
		let codex = AppLinkApplication(path: "/Applications/Codex.app", bundleID: "com.openai.codex", name: "Codex")
		let editor = AppLinkEditor(
			installedApplications: [
				.init(application: Self.claudeApp, schemes: ["claude"]),
				.init(application: codex, schemes: ["codex"]),
			],
			registeredApplications: ["claude": [.init(application: Self.claudeApp, schemes: [])]],
			chosenApplications: [.init(application: Self.claudeWork, schemes: ["claude"])]
		)
		let all = editor.pickerChoices(scheme: "claude", query: "")
		#expect(all.registered.map(\.application) == [Self.claudeApp])
		// Each app once: the registered one isn't listed again.
		#expect(all.others.map(\.application) == [Self.claudeWork, codex])

		#expect(editor.pickerChoices(scheme: "claude", query: "work").others.map(\.application) == [Self.claudeWork])
		#expect(editor.pickerChoices(scheme: "claude", query: "CODEX").others.map(\.application) == [codex])
		#expect(editor.pickerChoices(scheme: "claude", query: "openai").others.map(\.application) == [codex])
		#expect(editor.pickerChoices(scheme: "claude", query: "nothing").isEmpty)

		// One row per scheme an app declares; a registered app keeps the row's scheme.
		let xcode = AppLinkApplication(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode", name: "Xcode")
		let several = AppLinkEditor(
			installedApplications: [.init(application: xcode, schemes: ["xcode", "xcpref", "xcdevice"])],
			registeredApplications: ["claude": [.init(application: Self.claudeApp, schemes: [])]]
		)
		let entries = several.pickerChoices(scheme: "claude", query: "").entries(scheme: "claude")
		#expect(entries.map(\.scheme) == ["claude", "xcode", "xcpref", "xcdevice"])
		#expect(entries.map(\.isRegistered) == [true, false, false, false])
		#expect(Set(entries.map(\.id)).count == 4)
	}
}
