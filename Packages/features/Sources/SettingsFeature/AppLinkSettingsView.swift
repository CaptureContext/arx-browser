import AppLinkClient
import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Links › App Links (DEV-857), a page of its own beside Air Traffic Control (DEV-1114): which
/// apps' links Arx handles, how in each profile, and how otherwise. Each handler is a card that
/// starts from an app picker (DEV-862).
internal struct AppLinkSettingsView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let organization: BrowserOrganization

	@Environment(\.settingsToolbarAdd)
	private var addsFromToolbar

	internal init(
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization
	) {
		self.store = store
		self.organization = organization
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			// The page's bar carries the title, and New Handler while it's on the bar.
			if !addsFromToolbar {
				HStack {
					Spacer()
					Button(String.localized(.appUI.appLinks.newHandler), systemImage: "plus") {
						send(.newHandler)
					}
					.disabled(store.appLinks.draft != nil)
				}
				.padding(.horizontal, 14)
			}

			SettingsSection(
				content: {
					let handlers = store.routingPreferences.appLinks.handlers
					let draft = store.appLinks.draft
					if handlers.isEmpty, draft == nil {
						Text(localized: .appUI.appLinks.empty)
							.foregroundStyle(.secondary)
							.padding(.vertical, 10)
					}
					ForEach(handlers) { handler in
						AppLinkHandlerRow(
							handler: handler,
							organization: organization,
							editor: store.appLinks,
							error: store.appLinks.failedHandlerID == handler.id ? store.appLinks.error : nil,
							send: send,
							onChange: { send(.update($0)) },
							onRemove: { send(.delete(handler.id)) }
						)
					}
					if let draft {
						AppLinkHandlerRow(
							handler: draft,
							organization: organization,
							editor: store.appLinks,
							error: store.appLinks.failedHandlerID == draft.id ? store.appLinks.error : nil,
							isDraft: true,
							send: send,
							onChange: { send(.saveDraft($0)) },
							onRemove: { send(.discardDraft) }
						)
						.id(draft.id)
					}
				},
				footer: {
					VStack(alignment: .leading, spacing: 4) {
						Text(localized: .appUI.appLinks.description)

						// Links to the manual's Scripts section, which describes fxClaude's and
						// fxCodex's `open-url` (DEV-860).
						Text(Self.markdown(String.localized(.appUI.appLinks.footerOpenURL)))
					}
				}
			)
		}
		.task { send(.appeared) }
	}

	private func send(_ action: AppLinkEditor.Action) {
		store.send(.ui(.appLinks(action)))
	}

	/// A footer line with a link in it, written as Markdown in the string catalog.
	private static func markdown(_ text: String) -> AttributedString {
		(try? AttributedString(markdown: text)) ?? AttributedString(text)
	}
}

/// One handler's card: the picker, Name, Scheme and Remove; Host and Path; the links it
/// catches; Add profile and the Enabled switch; then each profile's route and Otherwise last.
private struct AppLinkHandlerRow: View {
	internal let handler: AppLinkHandler
	internal let organization: BrowserOrganization
	internal let editor: AppLinkEditor
	internal let error: AppLinkError?
	internal var isDraft: Bool = false
	internal let send: (AppLinkEditor.Action) -> Void
	internal let onChange: (AppLinkHandler) -> Void
	internal let onRemove: () -> Void

	@SwiftUI.State
	private var name: String

	@SwiftUI.State
	private var scheme: String

	@SwiftUI.State
	private var host: String

	@SwiftUI.State
	private var path: String

	/// Fields save on Return, when focus leaves them, and when the row goes away.
	@SwiftUI.State
	private var editingField: AppLinkField?

	/// Removing the row discards unsaved edits instead of saving them on the way out.
	@SwiftUI.State
	private var isRemoved: Bool = false

	@SwiftUI.State
	private var isPickerPresented: Bool = false

	internal init(
		handler: AppLinkHandler,
		organization: BrowserOrganization,
		editor: AppLinkEditor,
		error: AppLinkError?,
		isDraft: Bool = false,
		send: @escaping (AppLinkEditor.Action) -> Void,
		onChange: @escaping (AppLinkHandler) -> Void,
		onRemove: @escaping () -> Void
	) {
		self.handler = handler
		self.organization = organization
		self.editor = editor
		self.error = error
		self.isDraft = isDraft
		self.send = send
		self.onChange = onChange
		self.onRemove = onRemove
		self._name = .init(initialValue: handler.name)
		self._scheme = .init(initialValue: handler.scheme)
		self._host = .init(initialValue: handler.host ?? "")
		self._path = .init(initialValue: handler.pathPrefix ?? "")
	}

	private var availableProfiles: [Profile] {
		organization.profiles.filter { profile in
			!handler.overrides.contains { $0.profileID == profile.id }
		}
	}

	/// The handler as the row shows it, with edits not saved yet.
	private var edited: AppLinkHandler {
		var next = handler
		next.name = name.trimmingCharacters(in: .whitespacesAndNewlines)

		// Arx's built-in handler keeps its scheme (DEV-1193).
		next.scheme = handler.isBuiltIn ? handler.scheme : scheme
		next.host = host.isEmpty ? nil : host
		next.pathPrefix = path.isEmpty ? nil : path
		return next
	}

	private var normalizedScheme: String {
		AppLinkHandler.normalizedScheme(handler.scheme)
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Rows 1–3: the picker, Name, Scheme and Remove; Host and Path; the links it catches.
			AppLinkFields(
				name: $name,
				scheme: $scheme,
				host: $host,
				path: $path,
				error: error,
				onEditingChanged: { field, editing in
					if editing {
						editingField = field
					} else {
						if editingField == field { editingField = nil }
						commit()
					}
				},
				onSubmit: commit,
				picker: { picker },
				accessory: { removeButton }
			)
			if !isDraft {
				// Row 4: Add profile, and the handler's switch.
				HStack(spacing: 8) {
					if !availableProfiles.isEmpty {
						Menu(String.localized(.appUI.appLinks.addOverride)) {
							ForEach(availableProfiles) { profile in
								Button(profile.name) { send(.addProfileRoute(handler.id, profile.id)) }
							}
						}
						.menuStyle(.button)
						.buttonStyle(.arx(.secondary, size: .small))
						.fixedSize()
					}
					Spacer()
					Text(localized: .appUI.appLinks.enabled)
						.foregroundStyle(.secondary)
						.accessibilityHidden(true)
					Toggle(String.localized(.appUI.appLinks.enabled), isOn: Binding(
						get: { handler.isEnabled },
						set: { value in change { $0.isEnabled = value } }
					))
					.toggleStyle(.switch)
					.controlSize(.mini)
					.labelsHidden()
				}

				// Each profile's route first, then Otherwise, the way link routing reads.
				ForEach(AppLinkEditor.routes(of: handler), id: \.self) { route in
					routeRow(route)
				}
				ForEach(handler.alwaysAllowedOrigins, id: \.self) { origin in
					HStack {
						Text(localized: .appUI.appLinks.alwaysAllowed(origin))
							.font(.caption)
							.foregroundStyle(.secondary)
						Button(String.localized(.appUI.appLinks.forget)) { send(.forget(handler.id, origin: origin)) }
							.buttonStyle(.arx(.secondary, size: .small))
					}
					.padding(.leading, 26)
				}
			}
		}
		.opacity(isDraft || handler.isEnabled ? 1 : 0.55)
		.padding(.vertical, 10)
		.task(id: normalizedScheme) {
			if !normalizedScheme.isEmpty { send(.schemeShown(normalizedScheme)) }
		}

		// The saved handler is normalized (`Claude` becomes `claude`) or filled by the picker:
		// show what was saved in every field not being edited.
		.onChange(of: handler) { _, saved in
			if editingField != .name { name = saved.name }
			if editingField != .scheme { scheme = saved.scheme }
			if editingField != .host { host = saved.host ?? "" }
			if editingField != .path { path = saved.pathPrefix ?? "" }
		}
		.onDisappear(perform: commit)
	}

	@ViewBuilder
	private func routeRow(_ route: AppLinkEditor.Route) -> some View {
		switch route {
		case let .profile(profileID):
			if let override = handler.overrides.first(where: { $0.profileID == profileID }) {
				let profile = organization.profiles[id: profileID]
				HandlingRow(
					title: String.localized(.appUI.appLinks.inProfile(profile?.name ?? "—")),
					handling: override.handling,
					applications: handler.applications,
					test: editor.tests[.init(handlerID: handler.id, profileID: profileID)],
					offersArx: handler.isBuiltIn,
					onChange: { value in
						change { handler in
							guard let index = handler.overrides.firstIndex(where: { $0.profileID == profileID })
							else { return }
							handler.overrides[index].handling = value
						}
					},
					onChooseApp: { send(.chooseApplicationForHandling(handler.id, profileID: profileID)) },
					onUseExample: { send(.useScriptExample(handler.id, profileID: profileID)) },
					// The row's own profile, also for a profile deleted since: never Otherwise's.
					onTest: { send(.test(handler.id, profileID: profileID, profileName: profile?.name)) },
					onRemove: { send(.removeProfileRoute(handler.id, profileID)) }
				)
			}

		case .otherwise:
			HandlingRow(
				title: String.localized(.appUI.appLinks.otherwise),
				handling: handler.defaultHandling,
				applications: handler.applications,
				test: editor.tests[.init(handlerID: handler.id, profileID: nil)],
				offersArx: handler.isBuiltIn,
				onChange: { value in change { $0.defaultHandling = value } },
				onChooseApp: { send(.chooseApplicationForHandling(handler.id, profileID: nil)) },
				onUseExample: { send(.useScriptExample(handler.id, profileID: nil)) },
				onTest: { send(.test(handler.id, profileID: nil, profileName: nil)) }
			)
		}
	}

	/// The app picker (DEV-862): a button that opens a searchable popover of the apps macOS
	/// registers for the scheme, apps that declare schemes, Choose… and System Default. It shows
	/// an app only once one is picked, never one that merely matches the scheme.
	private var picker: some View {
		Button {
			isPickerPresented = true
		} label: {
			AppLinkAppLabel(
				name: handler.application?.name,
				icon: handler.application.flatMap { appLinkIcon(path: $0.path) }
			)
		}
		.buttonStyle(.plain)
		.help(handler.application?.path ?? String.localized(.appUI.appLinks.chooseApp))
		.popover(isPresented: $isPickerPresented, arrowEdge: .bottom) {
			AppLinkAppPicker(
				editor: editor,
				scheme: normalizedScheme,
				hasApplication: handler.application != nil,
				onPick: { application, scheme in
					isPickerPresented = false
					pick(application, scheme: scheme)
				},
				onChoose: {
					isPickerPresented = false
					send(.chooseApplication(edited))
				}
			)
		}
	}

	private var removeButton: some View {
		Button {
			isRemoved = true
			onRemove()
		} label: {
			Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
		}
		.buttonStyle(.arx(.plain, size: .small))
		.help(String.localized(.appUI.appLinks.removeHandler))
		.accessibilityLabel(Text(localized: .appUI.appLinks.removeHandler))
	}

	private func pick(
		_ application: AppLinkApplication?,
		scheme: String?
	) {
		// Edits typed so far go with the pick; the fields then show what was saved.
		editingField = nil
		send(.pickApplication(edited, application, scheme: scheme))
	}

	private func commit() {
		guard !isRemoved else { return }
		var next = edited
		guard next != handler else { return }
		if next.name.isEmpty { next.name = AppLinkHandler.normalizedScheme(next.scheme) }
		onChange(next)
	}

	private func change(_ edit: (inout AppLinkHandler) -> Void) {
		var next = handler
		edit(&next)
		onChange(next)
	}
}

/// The picker's popover: a search field, the apps macOS registers for the scheme, then the
/// other apps it knows, one row per scheme an app declares, then Choose… and System Default.
/// ↑ and ↓ move the highlight from the search field, and Return picks the highlighted row.
private struct AppLinkAppPicker: View {
	internal let editor: AppLinkEditor
	internal let scheme: String
	internal let hasApplication: Bool
	internal let onPick: (AppLinkApplication?, String?) -> Void
	internal let onChoose: () -> Void

	@SwiftUI.State
	private var query: String = ""

	@SwiftUI.State
	private var highlightedID: AppLinkEditor.PickerEntry.ID?

	@FocusState
	private var isSearching: Bool

	private var entries: [AppLinkEditor.PickerEntry] {
		editor.pickerChoices(scheme: scheme, query: query).entries(scheme: scheme)
	}

	internal var body: some View {
		let entries = entries
		VStack(alignment: .leading, spacing: 0) {
			TextField(String.localized(.appUI.appLinks.searchApps), text: $query)
				.textFieldStyle(.arx(systemImage: "magnifyingglass"))
				.focused($isSearching)
				.onSubmit { pick(entries.first { $0.id == highlightedID } ?? entries.first) }
				.onKeyPress(.downArrow) { move(1, in: entries) }
				.onKeyPress(.upArrow) { move(-1, in: entries) }
				.onChange(of: query) { _, _ in highlightedID = self.entries.first?.id }
				.padding(10)
			Divider()
			ScrollViewReader { proxy in
				ScrollView {
					LazyVStack(alignment: .leading, spacing: 2) {
						ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
							if index == 0 || entries[index - 1].isRegistered != entry.isRegistered {
								header(entry.isRegistered
								? String.localized(.appUI.appLinks.registeredFor(scheme + "://"))
								: String.localized(.appUI.appLinks.appsWithLinks))
							}
							row(entry).id(entry.id)
						}
						if entries.isEmpty {
							Text(localized: .appUI.appLinks.noApps)
								.foregroundStyle(.secondary)
								.padding(10)
						}
					}
					.padding(6)
				}
				.frame(maxHeight: 320)
				.onChange(of: highlightedID) { _, id in
					if let id { proxy.scrollTo(id) }
				}
			}
			Divider()
			HStack {
				Button(String.localized(.appUI.appLinks.choose), action: onChoose)
					.buttonStyle(.arx(.secondary, size: .small))
				Spacer()
				if hasApplication {
					Button(String.localized(.appUI.appLinks.systemDefault)) { onPick(nil, nil) }
						.buttonStyle(.arx(.secondary, size: .small))
				}
			}
			.padding(10)
		}
		.frame(width: 320)
		.onAppear {
			isSearching = true
			highlightedID = entries.first?.id
		}
	}

	private func header(_ title: String) -> some View {
		Text(title)
			.font(.caption.weight(.semibold))
			.foregroundStyle(.secondary)
			.padding(.horizontal, 8)
			.padding(.top, 6)
			.accessibilityAddTraits(.isHeader)
	}

	private func row(_ entry: AppLinkEditor.PickerEntry) -> some View {
		Button {
			pick(entry)
		} label: {
			HStack(spacing: 8) {
				Group {
					if let icon = appLinkIcon(path: entry.application.path) {
						Image(nsImage: icon).resizable()
					} else {
						Image(systemName: "app").resizable()
					}
				}
				.frame(width: 20, height: 20)
				.accessibilityHidden(true)
				Text(entry.application.name)
					.lineLimit(1)
				Spacer(minLength: 8)
				if !entry.isRegistered, let scheme = entry.scheme {
					Text(scheme + "://")
						.font(.caption.monospaced())
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(
				entry.id == highlightedID ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
				in: ArxControlShape()
			)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.onHover { if $0 { highlightedID = entry.id } }
		.help(entry.application.path)
	}

	private func move(
		_ offset: Int,
		in entries: [AppLinkEditor.PickerEntry]
	) -> KeyPress.Result {
		guard !entries.isEmpty else { return .handled }
		let index = entries.firstIndex { $0.id == highlightedID } ?? -1
		highlightedID = entries[min(max(index + offset, 0), entries.count - 1)].id
		return .handled
	}

	private func pick(_ entry: AppLinkEditor.PickerEntry?) {
		guard let entry else { return }
		onPick(entry.application, entry.scheme)
	}
}

/// A route: Open app or Run script for one profile, or Otherwise, with the script's editor and
/// Test.
private struct HandlingRow: View {
	internal let title: String
	internal let handling: AppLinkHandling

	/// The handler's apps, offered as Open in ‹app›.
	internal let applications: [AppLinkApplication]
	internal let test: AppLinkEditor.TestStatus?

	/// Open in Arx is a choice: Arx's built-in handler for another browser's pages (DEV-1193).
	internal let offersArx: Bool
	internal let onChange: (AppLinkHandling) -> Void
	internal let onChooseApp: () -> Void
	internal let onUseExample: () -> Void
	internal let onTest: () -> Void
	internal var onRemove: (() -> Void)?

	/// The dropdown's choices: System Default, an app, Other App… (opens a panel), Run script, and
	/// Open in Arx for Arx's built-in handler.
	private enum Choice: Hashable {
		case systemDefault
		case application(String)
		case otherApp
		case script
		case arx
	}

	@SwiftUI.State
	private var script: String

	/// Removing the profile's route discards an unsaved script instead of saving it on the way out.
	@SwiftUI.State
	private var isRemoved: Bool = false

	internal init(
		title: String,
		handling: AppLinkHandling,
		applications: [AppLinkApplication],
		test: AppLinkEditor.TestStatus?,
		offersArx: Bool = false,
		onChange: @escaping (AppLinkHandling) -> Void,
		onChooseApp: @escaping () -> Void,
		onUseExample: @escaping () -> Void,
		onTest: @escaping () -> Void,
		onRemove: (() -> Void)? = nil
	) {
		self.title = title
		self.handling = handling
		self.applications = applications
		self.test = test
		self.offersArx = offersArx
		self.onChange = onChange
		self.onChooseApp = onChooseApp
		self.onUseExample = onUseExample
		self.onTest = onTest
		self.onRemove = onRemove
		self._script = .init(initialValue: handling.script ?? "")
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 8) {
				Image(systemName: "arrow.turn.down.right")
					.foregroundStyle(.secondary)
					.frame(width: 18)
					.accessibilityHidden(true)
				Text(title)
				Spacer(minLength: 12)
				ArxDropdown(title, selection: selection, options: options)
					.fixedSize()

				// A script's route has Remove under its field instead.
				if let onRemove, handling.script == nil {
					Button(String.localized(.appUI.appLinks.removeOverride)) {
						isRemoved = true
						onRemove()
					}
					.buttonStyle(.arx(.secondary, size: .small))
				}
			}
			if handling.script != nil {
				AppLinkScriptField(
					script: $script,
					example: AppLinkEditor.scriptExample,
					error: testError,
					isTestDisabled: test == .running,
					onUseExample: onUseExample,
					onCommit: commit,
					onTest: onTest,
					onRemove: onRemove.map { remove in
						{
							isRemoved = true
							remove()
						}
					},
					status: { testStatus }
				)
				.padding(.leading, 26)
			}
		}

		// Take the saved script unless there are edits of its own not saved yet.
		.onChange(of: handling) { previous, saved in
			guard let value = saved.script, value != script else { return }
			if script.isEmpty || script == (previous.script ?? "") { script = value }
		}
		.onDisappear(perform: commit)
	}

	/// Every app the handler has, plus this handling's own if it's another.
	private var choices: [AppLinkApplication] {
		guard let own = handling.application, !applications.contains(where: { $0.isSameApp(as: own) })
		else { return applications }
		return applications + [own]
	}

	private var options: [ArxSuggestion<Choice>] {
		(offersArx ? [.init(id: .arx, title: String.localized(.appUI.appLinks.handlingOpenInArx))] : [])
			+ [.init(id: .systemDefault, title: String.localized(.appUI.appLinks.handlingSystemDefault))]
			+ choices.map { .init(id: .application($0.path), title: String.localized(.appUI.appLinks.handlingOpenIn($0.name))) }
			+ [
				.init(id: .otherApp, title: String.localized(.appUI.appLinks.handlingOtherApp)),
				.init(id: .script, title: String.localized(.appUI.appLinks.handlingRunScript)),
			]
	}

	private var selection: Binding<Choice> {
		Binding(
			get: {
				switch handling {
				case .runScript: .script
				case .openApp(nil): .systemDefault
				case let .openApp(application?): .application(application.path)
				case .openInArx: .arx
				}
			},
			set: { choice in
				switch choice {
				case .systemDefault: onChange(.systemDefault)

				case let .application(path):
					guard let application = choices.first(where: { $0.path == path }) else { return }
					onChange(.openApp(application))

				// The panel picks; the dropdown keeps showing the current choice meanwhile.
				case .otherApp: onChooseApp()

				case .script: onChange(.runScript(script))

				case .arx: onChange(.openInArx)
				}
			}
		)
	}

	/// Running or succeeded, beside Test.
	@ViewBuilder
	private var testStatus: some View {
		switch test {
		case .running:
			Text(localized: .appUI.appLinks.testing).font(.caption).foregroundStyle(.secondary)
		case let .finished(.succeeded(log))?:
			Text(localized: .appUI.appLinks.testSucceeded)
				.font(.caption)
				.foregroundStyle(.green)
				.help(log?.path(percentEncoded: false) ?? "")
		default:
			EmptyView()
		}
	}

	/// A failed Test, on its own line under the field, in full.
	private var testError: String? {
		switch test {
		case let .finished(.failed(status, message, _))?:
			String.localized(.appUI.appLinks.scriptFailed(String(status))) + (message.isEmpty ? "" : " " + message)
		case .finished(.timedOut)?:
			String.localized(.appUI.appLinks.scriptTimedOut)
		case let .finished(.unavailable(reason))?:
			String.localized(.appUI.appLinks.scriptUnavailable(reason))
		default:
			nil
		}
	}

	private func commit() {
		guard !isRemoved, case .runScript = handling, handling.script != script else { return }
		onChange(.runScript(script))
	}
}
