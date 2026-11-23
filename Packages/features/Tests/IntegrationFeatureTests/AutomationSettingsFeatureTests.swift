import BrowserAutomationClient
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import AppFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct AutomationSettingsFeatureTests {
	private typealias Fixture = AutomationManagementFeatureTests

	@Test
	func preferencesChangeThroughTheSettingsReducer() async throws {
		let state = Fixture.state()
		let (store, responses) = Fixture.store(state)
		let read = try #require(Self.settings(state, .read(.preferences, profileID: nil)))
		await store.send(.automation(.event(.host(.request(read)))))
		await store.finish()
		guard case let .settings(section) = responses.value.last else {
			Issue.record("No preferences read: \(String(describing: responses.value.last))")
			return
		}

		// Settings' row index decides the list, and lists every row with its access (DEV-1023).
		// Rows behind a feature flag that's off, and their keys, aren't listed (DEV-1141).
		let flags = state.settings.featureFlags
		expectNoDifference(section.preferences?.map(\.key), SettingsCategory.agentPreferenceKeys(flags))

		// Every key, with the flags on or off: a row a flag replaces reaches its keys while the
		// flag is off (DEV-1243).
		expectNoDifference(
			Set(SettingsCategory.agentPreferenceKeys(.all)).union(SettingsCategory.agentPreferenceKeys(.init())),
			Set(AutomationPreferenceKey.allCases)
		)
		expectNoDifference(section.rows, SettingsCategory.automationRows(flags))
		#expect(!AutomationPreferenceKey.allCases.map(\.rawValue).contains("developerModeEnabled"))

		// Made against the revision before the change: `state` shares its preferences with the store.
		let stale = Self.change(
			state,
			.setPreferences([.init(key: .warnsBeforeQuitting, value: .bool(true))]),
			id: UUID(90)
		)
		let change = Self.change(state, .setPreferences([
			.init(key: .warnsBeforeQuitting, value: .bool(false)),
			.init(key: .tintHue, value: .number(120)),
			.init(key: .forceClickLinkAction, value: .string("littleArx")),
		]))
		await store.send(.automation(.event(.host(.request(change)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		#expect(!store.state.settings.general.warnsBeforeQuitting)
		expectNoDifference(store.state.settings.chromeAppearance.tint.hue, 120)
		expectNoDifference(store.state.settings.linkClicks.forceClickLinkAction, .littleArx)
		guard case let .settings(result) = responses.value.last else {
			Issue.record("The change did not settle: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.operationID, change.operation.mutationID)
		#expect(result.revision != section.revision)
		// The released result is what the gate sees now.
		#expect(store.state.automationResponseValidation(change, result: .settings(result), snapshots: [:]) == nil)

		// The old revision no longer matches.
		await store.send(.automation(.event(.host(.request(stale)))))
		await store.finish()
		expectNoDifference(responses.value.last, .failure(.staleTarget))
		#expect(!store.state.settings.general.warnsBeforeQuitting)
	}

	/// DEV-1023: an agent puts back its own preference change, once, while nothing else changed
	/// those preferences.
	@Test
	func undoPutsBackAnAgentsOwnPreferenceChange() async throws {
		let state = Fixture.state()
		let (store, responses) = Fixture.store(state)
		let wasWarning = state.settings.general.warnsBeforeQuitting
		let change = Self.change(state, .setPreferences([
			.init(key: .warnsBeforeQuitting, value: .bool(!wasWarning)),
			.init(key: .newTabPlacement, value: .string("top")),
		]))
		await store.send(.automation(.event(.host(.request(change)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.settings.general.warnsBeforeQuitting == !wasWarning)
		expectNoDifference(store.state.settings.general.newTabPlacement, .top)
		let operationID = try #require(change.operation.mutationID)

		let undo = Self.change(store.state, .undoPreferences(operationID: operationID.uuidString), id: UUID(87))
		await store.send(.automation(.event(.host(.request(undo)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.settings.general.warnsBeforeQuitting == wasWarning)
		expectNoDifference(store.state.settings.general.newTabPlacement, state.settings.general.newTabPlacement)
		guard case .settings = responses.value.last else {
			Issue.record("The undo did not settle: \(String(describing: responses.value.last))")
			return
		}

		// Undone once, it's gone.
		let again = Self.change(store.state, .undoPreferences(operationID: operationID.uuidString), id: UUID(88))
		await store.send(.automation(.event(.host(.request(again)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(responses.value.last, .failure(.staleTarget))
	}

	/// DEV-1141: agents read and change dark pages as a choice, the way Settings' picker does,
	/// and only while its feature flag shows the row.
	@Test
	func darkPagesChangeThroughTheSettingsReducerWhileTheirFlagIsOn() async throws {
		var state = Fixture.state()
		state.settings.darkPagesAvailable = true
		let (store, responses) = Fixture.store(state)
		let read = try #require(Self.settings(state, .read(.preferences, profileID: nil)))
		await store.send(.automation(.event(.host(.request(read)))))
		await store.finish()
		guard case let .settings(section) = responses.value.last else {
			Issue.record("No preferences read: \(String(describing: responses.value.last))")
			return
		}
		let entry = try #require(section.preferences?.first { $0.key == .darkPages })
		expectNoDifference(entry.value, .string("off"))
		expectNoDifference(entry.type, "choice")
		expectNoDifference(entry.choices, ["off", "withTheme", "always"])
		#expect(section.rows?.contains { $0.id == "row/appearance/darkPages" && $0.keys == [.darkPages] } == true)

		expectNoDifference(Self.failure(state, .setPreferences([.init(key: .darkPages, value: .string("sepia"))])), .invalidValue)
		let change = Self.change(state, .setPreferences([.init(key: .darkPages, value: .string("always"))]))
		await store.send(.automation(.event(.host(.request(change)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.settings.general.darkPages, .always)
		guard case let .settings(result) = responses.value.last else {
			Issue.record("The change did not settle: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.preferences?.first { $0.key == .darkPages }?.value, .string("always"))
	}

	@Test
	func darkPagesAreOutOfReachWhileTheirFlagIsOff() async throws {
		let state = Fixture.state()
		#expect(!state.settings.darkPagesAvailable)
		let client = state.automationPreferences.clients[0]
		let section = try #require(state.automationSettings(.preferences, client: client))
		#expect(section.preferences?.contains { $0.key == .darkPages } == false)
		#expect(section.rows?.contains { $0.id == "row/appearance/darkPages" } == false)
		expectNoDifference(
			Self.failure(state, .setPreferences([.init(key: .darkPages, value: .string("always"))])),
			.invalidRequest
		)

		// Nor alongside a key agents can change.
		expectNoDifference(
			Self.failure(state, .setPreferences([
				.init(key: .darkPages, value: .string("always")),
				.init(key: .warnsBeforeQuitting, value: .bool(true)),
			])),
			.invalidRequest
		)
	}

	@Test
	func undoPutsBackAValueSettingsNormalized() async throws {
		let state = Fixture.state()
		let (store, responses) = Fixture.store(state)
		let hue = state.settings.chromeAppearance.tint.hue

		// Settings stores a hue of 360 as 0.
		let change = Self.change(state, .setPreferences([.init(key: .tintHue, value: .number(360))]))
		await store.send(.automation(.event(.host(.request(change)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let operationID = try #require(change.operation.mutationID)

		let undo = Self.change(store.state, .undoPreferences(operationID: operationID.uuidString.lowercased()), id: UUID(87))
		await store.send(.automation(.event(.host(.request(undo)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case .settings = responses.value.last else {
			Issue.record("The undo did not settle: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(store.state.settings.chromeAppearance.tint.hue, hue)
	}

	@Test
	func anotherClientsChangeWithTheSameOperationIDStaysItsOwn() async throws {
		var state = Fixture.state()
		let operationID = UUID(70)
		state.automation.preferenceChanges = [
			.init(
				operationID: operationID,
				clientID: state.automationPreferences.clients[0].id,
				before: [.init(key: .hapticsEnabled, value: .bool(true))],
				after: [.init(key: .hapticsEnabled, value: .bool(state.settings.general.hapticsEnabled))]
			),
			.init(
				operationID: operationID,
				clientID: UUID(71),
				before: [.init(key: .soundsEnabled, value: .bool(false))],
				after: [.init(key: .soundsEnabled, value: .bool(true))]
			),
		]

		let found = state.automation.preferenceChange(operationID.uuidString, clientID: state.automationPreferences.clients[0].id)
		expectNoDifference(found?.before, [.init(key: .hapticsEnabled, value: .bool(true))])
		#expect(state.automation.preferenceChange(operationID.uuidString, clientID: UUID(72)) == nil)
	}

	@Test
	func undoLeavesAPreferenceChangedSince() async throws {
		let state = Fixture.state()
		let (store, responses) = Fixture.store(state)
		let change = Self.change(state, .setPreferences([.init(key: .hapticsEnabled, value: .bool(false))]))
		await store.send(.automation(.event(.host(.request(change)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		let operationID = try #require(change.operation.mutationID)

		// The person turns it back on in Settings.
		await store.send(.settings(.ui(.hapticsEnabled(true))))
		await store.finish()
		await store.skipReceivedActions(strict: false)

		let undo = Self.change(store.state, .undoPreferences(operationID: operationID.uuidString), id: UUID(87))
		await store.send(.automation(.event(.host(.request(undo)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(responses.value.last, .failure(.staleTarget))
		#expect(store.state.settings.general.hapticsEnabled)
	}

	@Test
	func changesWaitForTheUsersApproval() async throws {
		var state = Fixture.state()
		state.automationPreferences.clients[0].approvalPolicy = .alwaysAsk
		let (store, responses) = Fixture.store(state)
		let change = Self.change(state, .setPreferences([.init(key: .shiftClickLinkAction, value: .string("newWindow"))]))
		await store.send(.automation(.event(.host(.request(change)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.automation.pending[change.id]?.awaitingApproval == true)
		expectNoDifference(store.state.settings.linkClicks.shiftClickLinkAction, .peek)

		await store.send(.automation(.ui(.approve(change.id))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.settings.linkClicks.shiftClickLinkAction, .newWindow)
		guard case .settings = responses.value.last else {
			Issue.record("No result after approval: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func keyboardShortcutsKeepSettingsConflictRules() async throws {
		let state = Fixture.state()
		let commandK = BrowserCore.KeyboardShortcut(key: "k")
		let (store, responses) = Fixture.store(state)
		let conflict = Self.change(state, .setKeyboardShortcut(.newTab, commandK, replacesConflicts: false))
		await store.send(.automation(.event(.host(.request(conflict)))))
		await store.finish()
		expectNoDifference(responses.value.last, .failure(.shortcutConflict))
		expectNoDifference(store.state.settings.keyboardShortcuts.shortcut(for: .commandBar), commandK)

		let replace = Self.change(state, .setKeyboardShortcut(.newTab, commandK, replacesConflicts: true), id: UUID(91))
		await store.send(.automation(.event(.host(.request(replace)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.settings.keyboardShortcuts.shortcut(for: .newTab), commandK)
		expectNoDifference(store.state.settings.keyboardShortcuts.shortcut(for: .commandBar), nil)
		#expect(store.state.settings.shortcutConflict == nil)
		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		let newTab = result.keyboardShortcuts?.first { $0.command == .newTab }
		expectNoDifference(newTab?.shortcut, .init(key: "k", modifiers: ["command"]))
		expectNoDifference(newTab?.isDefault, false)

		// Resetting the command bar now collides with New Tab, so it needs replace too.
		let current = store.state
		let reset = Self.change(current, .resetKeyboardShortcut(.commandBar, replacesConflicts: false), id: UUID(92))
		await store.send(.automation(.event(.host(.request(reset)))))
		await store.finish()
		expectNoDifference(responses.value.last, .failure(.shortcutConflict))
	}

	@Test
	func routingRulesStayWithinTheGrant() async throws {
		var state = Fixture.state()
		let hidden = RoutingRule(
			id: UUID(100),
			name: "Home only",
			host: "home.capturecontext.dev",
			destination: .init(scope: .space(Fixture.elsewhere), mode: .mainBrowser)
		)
		let visible = RoutingRule(
			id: UUID(101),
			name: "Work docs",
			host: "docs.capturecontext.dev",
			destination: .init(scope: .space(Fixture.first), mode: .mainBrowser)
		)
		state.settings.$routingPreferences.withLock { $0.rules = [hidden, visible] }
		state.settings.routing.name = "User draft"
		let client = state.automationPreferences.clients[0]

		let section = try #require(state.automationSettings(.routing, client: client))
		expectNoDifference(section.routing?.rules.map(\.id), [visible.id])
		expectNoDifference(section.routing?.hiddenRules, 1)

		let tested = state.automationRouteTest(
			URL(string: "https://home.capturecontext.dev/")!,
			sourceSpaceID: Fixture.first.rawValue,
			client: client
		)
		expectNoDifference(tested, .init(outcome: "hiddenRule"))
		let routed = state.automationRouteTest(
			URL(string: "https://docs.capturecontext.dev/a")!,
			sourceSpaceID: nil,
			client: client
		)
		expectNoDifference(routed.outcome, "rule")
		expectNoDifference(routed.spaceID, Fixture.first.rawValue)

		// A hidden rule can't be removed, and nothing can move around it or route outside the grant.
		expectNoDifference(Self.failure(state, .deleteRoutingRule(hidden.id)), .denied)
		expectNoDifference(Self.failure(state, .moveRoutingRule(visible.id, offset: -1)), .denied)
		let outside = AutomationRoutingRule(
			id: UUID(102),
			name: "Out",
			host: "out.capturecontext.dev",
			destination: .init(scope: .space, id: Fixture.elsewhere.rawValue, mode: .mainBrowser)
		)
		expectNoDifference(Self.failure(state, .saveRoutingRule(outside)), .denied)

		let (store, responses) = Fixture.store(state)
		let created = AutomationRoutingRule(
			id: UUID(103),
			name: "Second",
			host: "second.capturecontext.dev",
			includesSubdomains: true,
			destination: .init(scope: .space, id: Fixture.second.rawValue, mode: .mainBrowser)
		)
		let save = Self.change(state, .saveRoutingRule(created))
		await store.send(.automation(.event(.host(.request(save)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.settings.routingPreferences.rules.map(\.id), [hidden.id, visible.id, created.id])

		// The user's own draft in the routing editor survives.
		expectNoDifference(store.state.settings.routing.name, "User draft")
		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.targetID, created.id.uuidString)

		let disable = Self.change(store.state, .setRoutingRuleEnabled(created.id, false), id: UUID(93))
		await store.send(.automation(.event(.host(.request(disable)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.settings.routingPreferences.rules.last?.isEnabled == false)

		let delete = Self.change(store.state, .deleteRoutingRule(visible.id), id: UUID(94))
		await store.send(.automation(.event(.host(.request(delete)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.settings.routingPreferences.rules.map(\.id), [hidden.id, created.id])
	}

	@Test
	func searchShortcutsSaveThroughTheSettingsDraft() async throws {
		SearchShortcut.useFixtures()
		var state = Fixture.state()
		let draft = SearchShortcut(name: "Mine", keyword: "mine", template: "https://capturecontext.dev/?q={query}")
		state.settings.draft = draft
		let taken = try #require(state.settings.searchShortcuts.first)
		let duplicate = SearchShortcut(name: "Again", keyword: taken.keyword, template: "https://capturecontext.dev/?q={query}")
		expectNoDifference(Self.failure(state, .saveSearchShortcut(duplicate, replacing: nil)), .shortcutConflict)

		let (store, _) = Fixture.store(state)
		let added = SearchShortcut(name: "CaptureContext", keyword: "cc", template: "https://capturecontext.dev/?q={query}")
		await store.send(.automation(.event(.host(.request(Self.change(state, .saveSearchShortcut(added, replacing: nil)))))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.settings.searchShortcuts.contains(added))
		expectNoDifference(store.state.settings.draft, draft)

		let renamed = SearchShortcut(name: "CC", keyword: "ccx", template: "https://capturecontext.dev/?q={query}")
		let replace = Self.change(store.state, .saveSearchShortcut(renamed, replacing: "cc"), id: UUID(95))
		await store.send(.automation(.event(.host(.request(replace)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(!store.state.settings.searchShortcuts.contains { $0.keyword == "cc" })
		#expect(store.state.settings.searchShortcuts.contains(renamed))
		expectNoDifference(store.state.main.commandBar.shortcuts, store.state.settings.searchShortcuts)
	}

	@Test
	func replacingTheShortcutBeingEditedKeepsTheEditorOpenOnTheReplacement() async throws {
		SearchShortcut.useFixtures()
		var state = Fixture.state()
		let edited = try #require(state.settings.searchShortcuts.first)
		var draft = edited
		draft.name = "Unsaved"
		state.settings.editingKeyword = edited.id
		state.settings.isEditingShortcut = true
		state.settings.draft = draft
		let (store, _) = Fixture.store(state)
		let renamed = SearchShortcut(name: "Renamed", keyword: "renamed", template: "https://capturecontext.dev/?q={query}")
		let replace = Self.change(store.state, .saveSearchShortcut(renamed, replacing: edited.keyword), id: UUID(96))
		await store.send(.automation(.event(.host(.request(replace)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.settings.isEditingShortcut)
		expectNoDifference(store.state.settings.editingKeyword, renamed.id)
		expectNoDifference(store.state.settings.draft, draft)
	}

	@Test
	func extensionsBelongToGrantedProfilesOnly() async throws {
		let state = Fixture.state()
		let disabled = BrowserExtension(
			id: String(repeating: "a", count: 32),
			name: "Fixture",
			version: "1",
			state: .disabled,
			disableReasons: [.userAction],
			canEnable: true,
			canDisable: true
		)
		let managed = LockIsolated<[BrowserExtensionRequest]>([])
		let revision = LockIsolated<UInt64>(1)
		let (store, responses) = Fixture.store(state) {
			$0.browserExtensions = .init(
				isAvailable: true,
				inspect: { profileID in
					var item = disabled
					if managed.value.contains(where: { $0.action == .enable }) { item.state = .enabled }
					return .init(id: UUID(), profileID: profileID, revision: revision.value, extensions: [item])
				},
				manage: { request in
					managed.withValue { $0.append(request) }
					revision.withValue { $0 += 1 }
					var item = disabled
					item.state = .enabled
					return .init(id: UUID(), profileID: request.profileID, revision: revision.value, extensions: [item])
				}
			)
		}

		let ungranted = try #require(Self.settings(state, .read(.extensions, profileID: Fixture.home.rawValue)))
		await store.send(.automation(.event(.host(.request(ungranted)))))
		await store.finish()
		expectNoDifference(responses.value.last, .failure(.denied))

		let read = try #require(Self.settings(state, .read(.extensions, profileID: Fixture.work.rawValue), id: UUID(96)))
		await store.send(.automation(.event(.host(.request(read)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case let .settings(list) = responses.value.last else {
			Issue.record("No extension list: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(list.extensions?.items.map(\.canEnable), [true])

		let enable = AutomationRequest(
			id: UUID(97),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .settings(.init(.change(.init(
				operationID: UUID(98),
				expectedRevision: list.revision,
				edit: .setExtensionEnabled(profileID: Fixture.work.rawValue, extensionID: disabled.id, true)
			))))
		)
		await store.send(.automation(.event(.host(.request(enable)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(managed.value.map(\.action), [.enable])
		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.extensions?.items.map(\.state), ["enabled"])

		// The revision moved, so the old one is stale and nothing else is managed.
		var again = enable
		again.id = UUID(99)
		again.operation = .settings(.init(.change(.init(
			operationID: UUID(110),
			expectedRevision: list.revision,
			edit: .setExtensionEnabled(profileID: Fixture.work.rawValue, extensionID: disabled.id, false)
		))))
		await store.send(.automation(.event(.host(.request(again)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(responses.value.last, .failure(.staleTarget))
		expectNoDifference(managed.value.count, 1)
	}

	@Test
	func sitePermissionsAndZoomBelongToGrantedProfilesOnly() async throws {
		var state = Fixture.state()
		state.settings.siteSettings = .init(profileID: Fixture.work, profileName: "Work", isLoading: false)
		let stored = LockIsolated(SiteSettings(
			defaults: [.init(permission: .camera, setting: .ask)],
			zoom: [.init(host: "docs.example", factor: 1.5)]
		))
		let edits = LockIsolated<[SiteSettingsEdit]>([])
		let read = LockIsolated<[Profile.ID]>([])
		let (store, responses) = Fixture.store(state) {
			$0.browserEngine.siteSettings = { profileID throws(SiteSettingsFailure) in
				read.withValue { $0.append(profileID) }
				return stored.value
			}
			$0.browserEngine.changeSiteSettings = { _, edit throws(SiteSettingsFailure) in
				edits.withValue { $0.append(edit) }
				stored.withValue { settings in
					if case let .setPermission(origin?, permission, setting?) = edit {
						settings.exceptions = [.init(origin: origin, permission: permission, setting: setting)]
					}
				}
				return stored.value
			}
		}

		// Another profile's settings are never read.
		let ungranted = try #require(Self.settings(state, .read(.sitePermissions, profileID: Fixture.home.rawValue)))
		await store.send(.automation(.event(.host(.request(ungranted)))))
		await store.finish()
		expectNoDifference(responses.value.last, .failure(.denied))
		expectNoDifference(read.value, [])

		let list = try #require(Self.settings(state, .read(.sitePermissions, profileID: Fixture.work.rawValue), id: UUID(120)))
		await store.send(.automation(.event(.host(.request(list)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case let .settings(permissions) = responses.value.last else {
			Issue.record("No site permissions: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(permissions.sitePermissions?.defaults.map(\.permission), [.camera])
		expectNoDifference(permissions.sitePermissions?.profileID, Fixture.work.rawValue)

		let block = AutomationRequest(
			id: UUID(121),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .settings(.init(.change(.init(
				operationID: UUID(122),
				expectedRevision: permissions.revision,
				edit: .setSitePermission(profileID: Fixture.work.rawValue, origin: "https://meet.example", .camera, .block)
			))))
		)
		await store.send(.automation(.event(.host(.request(block)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(edits.value, [.setPermission(origin: "https://meet.example", .camera, .block)])
		guard case let .settings(result) = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(result.sitePermissions?.sites.map(\.setting), [.block])
		#expect(result.revision != permissions.revision)
		// The open Site Settings sheet for that profile read the change too.
		expectNoDifference(store.state.settings.siteSettings?.settings.exceptions.map(\.setting), [.block])

		// The old revision is stale, so nothing else changes.
		var again = block
		again.id = UUID(123)
		again.operation = .settings(.init(.change(.init(
			operationID: UUID(124),
			expectedRevision: permissions.revision,
			edit: .setSitePermission(profileID: Fixture.work.rawValue, origin: "https://meet.example", .camera, nil)
		))))
		await store.send(.automation(.event(.host(.request(again)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(responses.value.last, .failure(.staleTarget))
		expectNoDifference(edits.value.count, 1)

		let zoom = try #require(Self.settings(state, .read(.zoom, profileID: Fixture.work.rawValue), id: UUID(125)))
		await store.send(.automation(.event(.host(.request(zoom)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		guard case let .settings(zooms) = responses.value.last else {
			Issue.record("No zoom: \(String(describing: responses.value.last))")
			return
		}
		expectNoDifference(zooms.zoom?.sites, [.init(host: "docs.example", factor: 1.5)])
		#expect(zooms.sitePermissions == nil)

		// Settings' own validation answers before anyone is asked.
		expectNoDifference(
			Self.failure(state, .setSitePermission(profileID: Fixture.work.rawValue, origin: "https://a.example", .popups, .ask)),
			.invalidValue
		)
		expectNoDifference(
			Self.failure(state, .setSiteZoom(profileID: Fixture.home.rawValue, host: "a.example", factor: 2)),
			.denied
		)
	}

	@Test
	func truncatedListingsLetTheEngineDecide() async throws {
		let state = Fixture.state()
		let edits = LockIsolated<[SiteSettingsEdit]>([])
		let (store, responses) = Fixture.store(state) {
			$0.browserEngine.siteSettings = { _ throws(SiteSettingsFailure) in .init(isTruncated: true) }
			$0.browserEngine.changeSiteSettings = { _, edit throws(SiteSettingsFailure) in
				edits.withValue { $0.append(edit) }
				return .init(isTruncated: true)
			}
		}
		let revision = AppFeature.State.automationSiteSettingsResult(
			.sitePermissions,
			profileID: Fixture.work,
			settings: .init(isTruncated: true),
			client: state.automationPreferences.clients[0]
		).revision

		// The row isn't listed, but a truncated listing can't prove it's gone.
		let remove = AutomationRequest(
			id: UUID(128),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .settings(.init(.change(.init(
				operationID: UUID(129),
				expectedRevision: revision,
				edit: .setSitePermission(profileID: Fixture.work.rawValue, origin: "https://meet.example", .camera, nil)
			))))
		)
		await store.send(.automation(.event(.host(.request(remove)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(edits.value, [.setPermission(origin: "https://meet.example", .camera, nil)])
		guard case .settings = responses.value.last else {
			Issue.record("No result: \(String(describing: responses.value.last))")
			return
		}
	}

	@Test
	func allowingASitePermissionAsksEvenWithoutAnApprovalPolicy() async throws {
		let state = Fixture.state()
		#expect(state.automationPreferences.clients[0].approvalPolicy == .never)
		let edits = LockIsolated<[SiteSettingsEdit]>([])
		let (store, _) = Fixture.store(state) {
			$0.browserEngine.siteSettings = { _ throws(SiteSettingsFailure) in .init() }
			$0.browserEngine.changeSiteSettings = { _, edit throws(SiteSettingsFailure) in
				edits.withValue { $0.append(edit) }
				return .init()
			}
		}
		let allow = AutomationRequest(
			id: UUID(126),
			clientID: UUID(80),
			sessionID: UUID(81),
			operation: .settings(.init(.change(.init(
				operationID: UUID(127),
				expectedRevision: String(repeating: "0", count: 64),
				edit: .setSitePermission(profileID: Fixture.work.rawValue, origin: "https://meet.example", .camera, .allow)
			))))
		)
		await store.send(.automation(.event(.host(.request(allow)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		#expect(store.state.automation.pending[allow.id]?.awaitingApproval == true)
		expectNoDifference(edits.value, [])
	}

	@Test
	func spacesAndProfilesTakeAppearanceThroughSettingsTransactions() async throws {
		let state = Fixture.state()
		let (store, _) = Fixture.store(state)
		var request = Fixture.request(.setProfileAppearance, target: Fixture.work.rawValue, state: state)
		if case var .command(command) = request.operation {
			command.appearance = .init(set: .init(theme: .dark, tintHue: 30, grainSize: 2))
			request.operation = .command(command)
		}
		await store.send(.automation(.event(.host(.request(request)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(
			store.state.workspace.profiles[id: Fixture.work]?.appearance,
			.init(theme: .dark, tintHue: 30, grainSize: 2)
		)

		let current = store.state
		var space = Fixture.request(.setSpaceAppearance, target: Fixture.first.rawValue, state: current)
		space.id = UUID(111)
		if case var .command(command) = space.operation {
			command.operationID = UUID(112)
			command.appearance = .init(set: .init(tintIntensity: 0.6), inherit: [.theme])
			space.operation = .command(command)
		}
		await store.send(.automation(.event(.host(.request(space)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.spaces[id: Fixture.first]?.appearance, .init(tintIntensity: 0.6))
		expectNoDifference(store.state.workspace.appearance(ofSpace: Fixture.first).tintHue, 30)

		// Clearing everything returns the profile to Arx Settings' appearance.
		var clear = Fixture.request(.setProfileAppearance, target: Fixture.work.rawValue, state: store.state)
		clear.id = UUID(113)
		if case var .command(command) = clear.operation {
			command.operationID = UUID(114)
			command.appearance = .init(clearsAll: true)
			clear.operation = .command(command)
		}
		await store.send(.automation(.event(.host(.request(clear)))))
		await store.finish()
		await store.skipReceivedActions(strict: false)
		expectNoDifference(store.state.workspace.profiles[id: Fixture.work]?.appearance, nil)

		// Inventory carries each override and the app-wide appearance it applies to.
		let client = store.state.automationPreferences.clients[0]
		let items = AutomationInventoryBuilder.items(client: client, organization: store.state.workspace, snapshots: [:])
		expectNoDifference(items.first { $0.id == Fixture.first.rawValue }?.appearance, .init(tintIntensity: 0.6))
	}

	// MARK: - Helpers

	private static func settings(
		_ state: AppFeature.State,
		_ kind: AutomationSettingsRequest.Kind,
		id: UUID = UUID(85)
	) -> AutomationRequest? {
		.init(id: id, clientID: UUID(80), sessionID: UUID(81), operation: .settings(.init(kind)))
	}

	private static func change(
		_ state: AppFeature.State,
		_ edit: AutomationSettingsEdit,
		id: UUID = UUID(86)
	) -> AutomationRequest {
		let client = state.automationPreferences.clients[0]
		let revision = state.automationSettings(edit.section, client: client)?.revision ?? String(repeating: "0", count: 64)
		return .init(
			id: id,
			clientID: client.id,
			sessionID: UUID(81),
			operation: .settings(.init(.change(.init(
				operationID: UUID(),
				expectedRevision: revision,
				edit: edit
			))))
		)
	}

	/// What the app answers before asking anyone.
	private static func failure(
		_ state: AppFeature.State,
		_ edit: AutomationSettingsEdit
	) -> AutomationFailure? {
		guard case let .settings(request) = change(state, edit).operation else { return .invalidRequest }
		return state.automationSettingsValidation(request, client: state.automationPreferences.clients[0])
	}
}
