import AppLinkClient
import BrowserCore
import Foundation
import _ComposableArchitecture

/// Air Traffic Control › App Links: handlers for pages' links to other apps (DEV-857).
public struct AppLinkEditor: Equatable, Sendable {
	/// The handler whose last change was refused, so its row shows the error.
	public var failedHandlerID: UUID?
	public var error: AppLinkError?

	/// Each handler's last Test, by handler and the profile it ran as (nil for the default).
	public var tests: [TestKey: TestStatus]

	/// New Handler's row, not saved until it has a scheme.
	public var draft: AppLinkHandler?

	/// Installed apps that declare schemes, for the picker (DEV-862). Nil until looked up.
	public var installedApplications: [AppLinkApplicationChoice]?

	/// The apps macOS registers for each scheme a row shows, default first.
	public var registeredApplications: [String: [AppLinkApplicationChoice]]

	/// Apps picked with Choose… this session, so the picker offers them again.
	public var chosenApplications: [AppLinkApplicationChoice]

	public init(
		failedHandlerID: UUID? = nil,
		error: AppLinkError? = nil,
		tests: [TestKey: TestStatus] = [:],
		draft: AppLinkHandler? = nil,
		installedApplications: [AppLinkApplicationChoice]? = nil,
		registeredApplications: [String: [AppLinkApplicationChoice]] = [:],
		chosenApplications: [AppLinkApplicationChoice] = []
	) {
		self.failedHandlerID = failedHandlerID
		self.error = error
		self.tests = tests
		self.draft = draft
		self.installedApplications = installedApplications
		self.registeredApplications = registeredApplications
		self.chosenApplications = chosenApplications
	}

	/// The script field's example, shown as ghost text until Tab uses it.
	public static let scriptExample: String = #"fxclaude open-url work "$1""#

	/// One of a handler's routes, in the order Settings lists them: each profile's, then
	/// Otherwise (the default), the way link routing reads.
	public enum Route: Hashable, Sendable {
		case profile(Profile.ID)
		case otherwise

		public var profileID: Profile.ID? {
			guard case let .profile(id) = self else { return nil }
			return id
		}
	}

	public static func routes(of handler: AppLinkHandler) -> [Route] {
		handler.overrides.map { .profile($0.profileID) } + [.otherwise]
	}

	/// The picker's lists for a row's scheme, filtered by what's typed in its search field:
	/// apps macOS registers for the scheme, then every other app it knows, each once.
	public struct PickerChoices: Equatable, Sendable {
		public var registered: [AppLinkApplicationChoice]
		public var others: [AppLinkApplicationChoice]

		public var isEmpty: Bool { registered.isEmpty && others.isEmpty }

		/// The rows the popover lists, in order: a registered app keeps the row's scheme; any
		/// other app gets one row per scheme it declares, so every scheme fits and ↑ and ↓
		/// reach each one.
		public func entries(scheme: String) -> [PickerEntry] {
			registered.map { .init(application: $0.application, scheme: scheme, isRegistered: true) }
				+ others.flatMap { choice in
					choice.schemes.isEmpty
					? [PickerEntry(application: choice.application, scheme: nil, isRegistered: false)]
					: choice.schemes.map { PickerEntry(application: choice.application, scheme: $0, isRegistered: false) }
				}
		}
	}

	/// One row of the picker: an app, and the scheme picking it sets.
	public struct PickerEntry: Hashable, Identifiable, Sendable {
		public var application: AppLinkApplication

		/// Nil keeps the row's scheme.
		public var scheme: String?
		public var isRegistered: Bool

		public var id: String { application.path + "\u{0}" + (scheme ?? "") }
	}

	public func pickerChoices(
		scheme: String,
		query: String
	) -> PickerChoices {
		let scheme = AppLinkHandler.normalizedScheme(scheme)
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		func matches(_ choice: AppLinkApplicationChoice) -> Bool {
			guard !query.isEmpty else { return true }
			return choice.application.name.localizedStandardContains(query)
				|| choice.schemes.contains { $0.localizedStandardContains(query) }
				|| (choice.application.bundleID?.localizedStandardContains(query) ?? false)
		}
		let registered = registeredApplications[scheme] ?? []
		var seen = Set(registered.map(\.application.path))
		let others = (chosenApplications + (installedApplications ?? []))
			.filter { seen.insert($0.application.path).inserted }
		return .init(registered: registered.filter(matches), others: others.filter(matches))
	}

	/// The schemes `application` declares, from any list the picker has.
	public func schemes(of application: AppLinkApplication) -> [String] {
		let lists = [chosenApplications, installedApplications ?? []] + Array(registeredApplications.values)
		return lists.lazy
			.flatMap { $0 }
			.first { $0.application.isSameApp(as: application) && !$0.schemes.isEmpty }?
			.schemes ?? []
	}

	/// `handler` with `application` picked (DEV-862): Name becomes the app's name unless the
	/// person wrote their own, Scheme becomes `scheme` when given, and every Open app, by default
	/// or for a profile, that used System Default or the previous app opens this one. Scripts
	/// and apps chosen for one row with Other App… stay as they are.
	public static func picking(
		_ application: AppLinkApplication?,
		scheme: String?,
		for handler: AppLinkHandler
	) -> AppLinkHandler {
		var next = handler
		let previous = handler.application
		let name = handler.name.trimmingCharacters(in: .whitespacesAndNewlines)
		if let application, name.isEmpty || name == handler.scheme || name == previous?.name {
			next.name = application.name
		}

		// Arx's built-in handler for Chrome's pages keeps `chrome` (DEV-1193).
		if let scheme, !scheme.isEmpty, !handler.isBuiltIn { next.scheme = scheme }
		next.application = application

		// Open app follows unless it opens an app chosen for that row alone.
		func follows(_ handling: AppLinkHandling) -> Bool {
			guard case let .openApp(current) = handling else { return false }
			return current.map { $0.isSameApp(as: previous) } ?? true
		}
		if follows(next.defaultHandling) { next.defaultHandling = .openApp(application) }
		for index in next.overrides.indices where follows(next.overrides[index].handling) {
			next.overrides[index].handling = .openApp(application)
		}
		return next
	}

	public struct TestKey: Hashable, Sendable {
		public let handlerID: UUID
		public let profileID: Profile.ID?

		public init(
			handlerID: UUID,
			profileID: Profile.ID?
		) {
			self.handlerID = handlerID
			self.profileID = profileID
		}
	}

	public enum TestStatus: Equatable, Sendable {
		case running
		case finished(AppLinkScriptOutcome)
	}

	/// The sample link a Test passes: the handler's scheme, host and path with a marker query.
	public static func sampleLink(for handler: AppLinkHandler) -> String {
		let host = handler.host ?? "arx-test"
		var path = handler.pathPrefix ?? "/callback"
		if !path.hasPrefix("/") { path = "/" + path }
		return "\(handler.scheme)://\(host)\(path)?arx-test=1"
	}

	@CasePathable
	public enum Action: Sendable {
		/// New Handler: an empty row to fill in.
		case newHandler

		/// The empty row's Remove: nothing was saved.
		case discardDraft

		/// A new handler, added at the end with an ID of its own.
		case add(AppLinkHandler)

		/// The New Handler row saving: only while it's still the open draft, so the row saving
		/// again as it goes away adds nothing.
		case saveDraft(AppLinkHandler)

		/// A handler changed in place.
		case update(AppLinkHandler)
		case delete(UUID)

		/// Forget an origin Always allow remembered.
		case forget(UUID, origin: String)

		/// Runs the handler's script for a profile (nil: the default) with ``sampleLink(for:)``.
		case test(UUID, profileID: Profile.ID?, profileName: String?)
		case testFinished(TestKey, AppLinkScriptOutcome)

		/// The section appeared: the picker's installed apps are looked up once.
		case appeared

		/// A row shows `scheme`: the picker lists the apps macOS registers for it.
		case schemeShown(String)
		case installedApplicationsLoaded([AppLinkApplicationChoice])

		/// An app from the picker for the handler as the row shows it (the draft too), with the
		/// scheme picked from its menu. Nil is System Default.
		case pickApplication(AppLinkHandler, AppLinkApplication?, scheme: String?)

		/// Choose… in the picker: an open panel for an app anywhere on disk.
		case chooseApplication(AppLinkHandler)

		/// Other App… in a handling's menu: the app for the default (nil) or one profile.
		case chooseApplicationForHandling(UUID, profileID: Profile.ID?)
		case applicationChosen(Chooser, AppLinkApplicationChoice?)

		/// Add Profile: a profile's own route, just above Otherwise, starting as Otherwise does.
		case addProfileRoute(UUID, Profile.ID)
		case removeProfileRoute(UUID, Profile.ID)

		/// Tab (or →) in an empty script field: the field takes ``scriptExample``.
		case useScriptExample(UUID, profileID: Profile.ID?)
	}

	/// Who asked for Choose…: the picker of a handler (as its row showed it), or one handling.
	public enum Chooser: Equatable, Sendable {
		case handler(AppLinkHandler)
		case handling(UUID, profileID: Profile.ID?)
	}
}

@Reducer
internal struct SettingsAppLinks {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.uuid)
	private var uuid

	@Dependency(\.appLinks)
	private var appLinks

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.appLinks.newHandler) { state in
			guard state.appLinks.draft == nil else { return .none }
			state.appLinks.draft = .init(id: uuid(), name: "", scheme: "")
			return .none
		}

		Pullback(\.ui.appLinks.discardDraft) { state in
			if let id = state.appLinks.draft?.id, state.appLinks.failedHandlerID == id {
				state.appLinks.failedHandlerID = nil
				state.appLinks.error = nil
			}
			state.appLinks.draft = nil
			return .none
		}

		// App links live in the routing shared key: AppFeature saves the edits. Every write is
		// validated first.
		Pullback(\.ui.appLinks.add) { state, draft in
			add(draft, in: &state)
			return .none
		}

		Pullback(\.ui.appLinks.saveDraft) { state, draft in
			guard state.appLinks.draft?.id == draft.id else { return .none }
			add(draft, in: &state)
			return .none
		}

		// Only handlers still in the list: a late save from a removed row never brings it back.
		Pullback(\.ui.appLinks.update) { state, handler in
			guard state.routingPreferences.appLinks.handlers.contains(where: { $0.id == handler.id })
			else { return .none }
			save(handler, in: &state)
			return .none
		}

		Pullback(\.ui.appLinks.delete) { state, id in
			state.$routingPreferences.withLock { $0.appLinks.handlers.removeAll { $0.id == id } }
			state.appLinks.tests = state.appLinks.tests.filter { $0.key.handlerID != id }
			if state.appLinks.failedHandlerID == id {
				state.appLinks.failedHandlerID = nil
				state.appLinks.error = nil
			}
			return .none
		}

		Pullback(\.ui.appLinks.forget) { state, value in
			let (id, origin) = value
			state.$routingPreferences.withLock { preferences in
				guard let index = preferences.appLinks.handlers.firstIndex(where: { $0.id == id })
				else { return }
				preferences.appLinks.handlers[index].alwaysAllowedOrigins.removeAll { $0 == origin }
			}
			return .none
		}

		Pullback(\.ui.appLinks.test) { state, value in
			let (id, profileID, profileName) = value
			guard
				let handler = state.routingPreferences.appLinks.handlers.first(where: { $0.id == id }),
				let script = handler.handling(profileID: profileID, isPrivate: false).script
			else { return .none }

			let key = AppLinkEditor.TestKey(handlerID: id, profileID: profileID)
			guard state.appLinks.tests[key] != .running else { return .none }
			state.appLinks.tests[key] = .running
			let run = AppLinkScript(
				script: script,
				link: AppLinkEditor.sampleLink(for: handler),
				scheme: handler.scheme,
				profileID: profileID?.rawValue.uuidString ?? "",
				profileName: profileName ?? "",
				sourceOrigin: ""
			)
			return .run { [appLinks] send in
				await send(.ui(.appLinks(.testFinished(key, appLinks.runScript(run)))))
			}
		}

		Pullback(\.ui.appLinks.testFinished) { state, value in
			let (key, outcome) = value
			guard state.appLinks.tests[key] == .running else { return .none }
			state.appLinks.tests[key] = .finished(outcome)
			return .none
		}

		Pullback(\.ui.appLinks.appeared) { state in
			guard state.appLinks.installedApplications == nil else { return .none }
			return .run { [appLinks] send in
				await send(.ui(.appLinks(.installedApplicationsLoaded(appLinks.installedApplications()))))
			}
		}

		Pullback(\.ui.appLinks.installedApplicationsLoaded) { state, choices in
			state.appLinks.installedApplications = choices
			return .none
		}

		Pullback(\.ui.appLinks.schemeShown) { state, scheme in
			let scheme = AppLinkHandler.normalizedScheme(scheme)
			guard AppLinkHandler.schemeProblem(scheme) == nil else { return .none }
			let client = appLinks
			state.appLinks.registeredApplications[scheme] = MainActor.assumeIsolated {
				client.applicationsForScheme(scheme)
			}
			return .none
		}

		Pullback(\.ui.appLinks.pickApplication) { state, value in
			let (handler, application, scheme) = value
			pick(application, scheme: scheme, for: handler, in: &state)
			return .none
		}

		Pullback(\.ui.appLinks.chooseApplication) { _, handler in
			choose(for: .handler(handler))
		}

		Pullback(\.ui.appLinks.chooseApplicationForHandling) { _, value in
			let (id, profileID) = value
			return choose(for: .handling(id, profileID: profileID))
		}

		Pullback(\.ui.appLinks.applicationChosen) { state, value in
			let (chooser, choice) = value
			guard let choice else { return .none }
			if !state.appLinks.chosenApplications.contains(where: { $0.application.isSameApp(as: choice.application) }) {
				state.appLinks.chosenApplications.append(choice)
			}
			switch chooser {
			case let .handler(handler):
				// Keep the row's scheme when the app declares it; otherwise its first one.
				let current = AppLinkHandler.normalizedScheme(handler.scheme)
				let scheme = choice.schemes.contains(current) ? current : choice.schemes.first
				pick(choice.application, scheme: scheme, for: handler, in: &state)

			case let .handling(id, profileID):
				guard var handler = state.routingPreferences.appLinks.handlers.first(where: { $0.id == id })
				else { return .none }
				if let profileID {
					guard let index = handler.overrides.firstIndex(where: { $0.profileID == profileID })
					else { return .none }
					handler.overrides[index].handling = .openApp(choice.application)
				} else {
					handler.defaultHandling = .openApp(choice.application)
				}
				save(handler, in: &state)
			}
			return .none
		}

		Pullback(\.ui.appLinks.addProfileRoute) { state, value in
			let (id, profileID) = value
			edit(id, in: &state) { handler in
				guard !handler.overrides.contains(where: { $0.profileID == profileID }) else { return }

				// Overrides come before Otherwise, so the new one lands just above it.
				handler.overrides.append(.init(profileID: profileID, handling: handler.defaultHandling))
			}
			return .none
		}

		Pullback(\.ui.appLinks.removeProfileRoute) { state, value in
			let (id, profileID) = value
			edit(id, in: &state) { $0.overrides.removeAll { $0.profileID == profileID } }
			return .none
		}

		Pullback(\.ui.appLinks.useScriptExample) { state, value in
			let (id, profileID) = value
			edit(id, in: &state) { handler in

				// Only an empty script: Tab anywhere else moves focus as usual.
				func filled(_ handling: AppLinkHandling) -> AppLinkHandling? {
					guard let script = handling.script, script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					else { return nil }
					return .runScript(AppLinkEditor.scriptExample)
				}
				if let profileID {
					guard
						let index = handler.overrides.firstIndex(where: { $0.profileID == profileID }),
						let next = filled(handler.overrides[index].handling)
					else { return }
					handler.overrides[index].handling = next
				} else if let next = filled(handler.defaultHandling) {
					handler.defaultHandling = next
				}
			}
			return .none
		}
	}

	/// Changes a saved handler in place and saves it, when it's still in the list.
	private func edit(
		_ id: UUID,
		in state: inout State,
		_ change: (inout AppLinkHandler) -> Void
	) {
		guard var handler = state.routingPreferences.appLinks.handlers.first(where: { $0.id == id })
		else { return }
		change(&handler)
		save(handler, in: &state)
	}

	private func choose(for chooser: AppLinkEditor.Chooser) -> Effect<Action> {
		.run { [appLinks] send in
			let choice = await appLinks.chooseApplication()
			await send(.ui(.appLinks(.applicationChosen(chooser, choice))))
		}
	}

	/// Picks for a saved handler in place, or adds the draft once the pick gives it a scheme.
	private func pick(
		_ application: AppLinkApplication?,
		scheme: String?,
		for handler: AppLinkHandler,
		in state: inout State
	) {
		// Installed apps are listed without bookmarks; one is made for the app that's picked,
		// so it's found again after a move.
		let client = appLinks
		let application = application.map { app in MainActor.assumeIsolated { client.bookmarked(app) } }
		let next = AppLinkEditor.picking(application, scheme: scheme, for: handler)
		if state.routingPreferences.appLinks.handlers.contains(where: { $0.id == handler.id }) {
			save(next, in: &state)
		} else if state.appLinks.draft?.id == handler.id {
			add(next, in: &state)
		}
	}

	/// Saves `draft` as a new handler with an ID of its own. The draft's row closes once it's
	/// saved, and shows the error otherwise.
	private func add(
		_ draft: AppLinkHandler,
		in state: inout State
	) {
		// The draft row keeps what's typed until it has a scheme to save.
		if state.appLinks.draft?.id == draft.id, AppLinkHandler.normalizedScheme(draft.scheme).isEmpty {
			state.appLinks.draft = draft
			return
		}
		var handler = draft
		handler.id = uuid()
		let draftFailed = state.appLinks.failedHandlerID == draft.id
		save(handler, in: &state)
		if state.appLinks.failedHandlerID == handler.id {
			// The draft's own row shows the error, with what was typed.
			state.appLinks.failedHandlerID = draft.id
			if state.appLinks.draft?.id == draft.id { state.appLinks.draft = draft }
		} else {
			if draftFailed {
				state.appLinks.failedHandlerID = nil
				state.appLinks.error = nil
			}
			if state.appLinks.draft?.id == draft.id { state.appLinks.draft = nil }
		}
	}

	private func save(
		_ handler: AppLinkHandler,
		in state: inout State
	) {
		var handler = handler
		handler.scheme = handler.isBuiltIn ? AppLinkHandler.chromePagesScheme : AppLinkHandler.normalizedScheme(handler.scheme)
		handler.host = handler.host.flatMap { $0.isEmpty ? nil : $0.lowercased() }
		handler.pathPrefix = handler.pathPrefix.flatMap { $0.isEmpty ? nil : $0 }
		var preferences = state.routingPreferences
		if let index = preferences.appLinks.handlers.firstIndex(where: { $0.id == handler.id }) {
			preferences.appLinks.handlers[index] = handler
		} else {
			preferences.appLinks.handlers.append(handler)
		}
		do {
			try preferences.appLinks.validate()
		} catch {
			state.appLinks.failedHandlerID = handler.id
			state.appLinks.error = error
			return
		}
		state.$routingPreferences.withLock { $0 = preferences }
		if state.appLinks.failedHandlerID == handler.id {
			state.appLinks.failedHandlerID = nil
			state.appLinks.error = nil
		}
	}
}
