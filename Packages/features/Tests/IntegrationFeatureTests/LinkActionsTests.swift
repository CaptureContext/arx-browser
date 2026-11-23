import AppFeature
import BrowserCore
import BrowserWorkspaceClient
import CustomDump
import Foundation
import LittleArxFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import SettingsFeature

extension IntegrationFeatureTests {
	@Test
	internal func copyingCurrentPinnedPageUsesItsLiveURLAndReportsClipboardFailure() async throws {
		var organization = fixture()
		organization.tabs[0].savedDestination = .init(title: "Saved", url: URL(string: "https://saved.example")!)
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[0]
		state.main.viewer.item.navigation = .init(url: URL(string: "https://current.example/a?utm_source=test")!, title: "Current")
		var copied: [String] = []
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = {
				copied.append($0)
				return false
			}
		}
		await store.send(.ui(.copyLinks(.clean))) { $0.linkActionGeneration = 1 }
		let result = LinkTransformer.copy(state.focusedLinkItems, mode: .clean)
		await store.receive(\.event.linkActionFinished) {
			$0.linkActionFeedback = .init(windowID: state.main.id, result: result, status: .copyFailed)
		}
		expectNoDifference(copied, ["https://current.example/a"])
		expectNoDifference(store.state.workspace, organization)
		expectNoDifference(store.state.main, state.main)
		expectNoDifference(
			state.linkItems(in: state.main.id, tabIDs: [organization.tabs[0].id.rawValue], saved: true),
			[.init(title: "Saved", url: URL(string: "https://saved.example")!)]
		)
	}

	@Test
	internal func invalidShareInputNeverCallsTheNativeShareService() async throws {
		let organization = fixture()
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() }
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.shareProxyLinks(items: [
			.init(title: "Private", url: URL(string: "https://user:secret@capturecontext.dev/")!),
		])))
		await store.receive(\.event.linkActionFinished)
		guard case .share(.failed) = store.state.linkActionFeedback?.status else {
			Issue.record("Invalid sharing input should report failure")
			return
		}
		expectNoDifference(store.state.workspace, organization)
	}

	@Test
	internal func explicitContextTargetsPreserveSelectionOrderIndependentOfFocusedTab() async throws {
		let organization = fixture()
		let items: [LinkCopyItem] = [
			.init(title: "Second", url: URL(string: "https://x.com/second")!),
			.init(title: "First", url: URL(string: "https://x.com/first")!),
		]
		var copied: String?
		let state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.settings.$proxyLinkRules.withLock { $0 = [proxyRule()] }
		let store = TestStore(initialState: state) { AppFeature() } withDependencies: {
			$0.linkSharing.copy = {
				copied = $0
				return true
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.copyLinks(.markdownProxy, items: items)))
		await store.receive(\.event.linkActionFinished)
		expectNoDifference(copied, "[Second](<https://fxtwitter.com/second>)\n[First](<https://fxtwitter.com/first>)")
		expectNoDifference(store.state.linkActionFeedback?.result.transformations.map(\.original), items)
		expectNoDifference(store.state.workspace, organization)
	}

	@Test
	internal func sharingCancellationAndStaleCompletionDoNotMutateBrowsing() async throws {
		let organization = fixture()
		var shared: [URL] = []
		let store = TestStore(initialState: AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id
		))) { AppFeature() } withDependencies: {
			$0.linkSharing.share = { urls, _ in
				shared = urls
				return .cancelled
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.shareProxyLinks()))
		await store.receive(\.event.linkActionFinished)
		expectNoDifference(shared, [organization.tabs[0].restoration.url])
		expectNoDifference(store.state.linkActionFeedback?.status, .share(.cancelled))
		expectNoDifference(store.state.workspace, organization)
		await store.send(.event(.linkActionFinished(0, .init(
			windowID: nil,
			result: .init(mode: .original, transformations: [], text: ""),
			status: .copied
		))))
		expectNoDifference(store.state.linkActionFeedback?.status, .share(.cancelled))
	}

	@Test
	internal func focusedLittleWindowAndStaleViewerCannotCopyAnotherTabsURL() async throws {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		state.main.viewer.item.tab = organization.tabs[1]
		state.main.viewer.item.navigation.url = URL(string: "https://wrong.example")!
		expectNoDifference(state.focusedLinkItems.first?.url, organization.tabs[0].restoration.url)
		let id = UUID(99)
		var little = LittleArxFeature.State(id: id, spaceID: organization.spaces[0].id, tab: organization.tabs[1])
		little.viewer.navigation = .init(url: URL(string: "https://little.example/current")!, title: "Little")
		state.littleWindows.append(little)
		state.focusedWindowID = id
		expectNoDifference(state.focusedLinkItems, [.init(title: "Little", url: URL(string: "https://little.example/current")!)])
		state.littleWindows[id: id]?.isCommandOnly = true
		expectNoDifference(state.focusedLinkItems, [])
	}

	@Test
	internal func proxySettingsEditInPlaceReorderDisableAndRejectInvalidDefinitions() async throws {
		let first = proxyRule()
		let second = proxyRule(id: 101, destination: "https://other.example{path}{query}{fragment}")
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [first, second] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		await store.send(.ui(.proxyLinks(.move(second.id, to: 0))))
		expectNoDifference(store.state.proxyLinkRules.map(\.id), [second.id, first.id])
		await store.send(.ui(.proxyLinks(.toggle(second.id))))
		await store.send(.ui(.proxyLinks(.edit(second.id))))
		var editor = try #require(store.state.proxyLinkEditor)
		editor.name = "Edited alternative"
		await store.send(.ui(.proxyLinks(.changed(editor))))
		await store.send(.ui(.proxyLinks(.save)))
		expectNoDifference(store.state.proxyLinkRules.first?.name, "Edited alternative")
		expectNoDifference(store.state.proxyLinkRules.first?.isEnabled, false)
		await store.send(.ui(.proxyLinks(.edit(first.id))))
		editor = try #require(store.state.proxyLinkEditor)
		editor.destinationTemplate = "https://{unknown}.example"
		await store.send(.ui(.proxyLinks(.changed(editor))))
		#expect(store.state.proxyLinkEditor?.isValid == false)
		let rules = store.state.proxyLinkRules
		await store.send(.ui(.proxyLinks(.save)))
		expectNoDifference(store.state.proxyLinkEditor?.error, .invalidTemplate)
		expectNoDifference(store.state.proxyLinkRules, rules)
	}

	/// DEV-1163: ⌥⌘↓ on the first rule, then ⌥⌘↑ on it, move it down a place and back, as the row
	/// sends them.
	@Test
	internal func aRuleMovesDownAndBackFromTheKeyboard() async throws {
		let first = proxyRule()
		let second = proxyRule(id: 101, destination: "https://other.example{path}{query}{fragment}")
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [first, second] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)
		let down = try #require(RuleMove(key: .downArrow, modifiers: [.option, .command])?.destination(from: 0, among: 2))
		await store.send(.ui(.proxyLinks(.move(first.id, to: down))))
		expectNoDifference(store.state.proxyLinkRules.map(\.id), [second.id, first.id])
		let up = try #require(RuleMove(key: .upArrow, modifiers: [.option, .command])?.destination(from: 1, among: 2))
		await store.send(.ui(.proxyLinks(.move(first.id, to: up))))
		expectNoDifference(store.state.proxyLinkRules.map(\.id), [first.id, second.id])
	}

	/// DEV-1003: Restore Defaults puts Arx's rules back as they ship and keeps the person's own first.
	@Test
	internal func restoreDefaultsBringsBackTheDefaultProxyRules() async throws {
		let own = proxyRule()
		var changed = ProxyLinkRule.defaults[0]
		changed.isEnabled = false
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [own, changed] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.restoreDefaults))) {
			$0.$proxyLinkRules.withLock { $0 = [own] + ProxyLinkRule.defaults }
		}
	}

	/// DEV-1113: a drag drops a rule at any place in the list; a place outside it changes nothing.
	@Test
	internal func movingAProxyRuleDropsItAtTheIndex() async throws {
		let rules = (101...103).map { proxyRule(id: $0, destination: "https://m\($0).example{path}") }
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = rules }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.move(rules[0].id, to: 2)))) {
			$0.$proxyLinkRules.withLock { $0 = [rules[1], rules[2], rules[0]] }
		}
		await store.send(.ui(.proxyLinks(.move(rules[0].id, to: 3))))
		await store.send(.ui(.proxyLinks(.move(rules[2].id, to: 0)))) {
			$0.$proxyLinkRules.withLock { $0 = [rules[2], rules[1], rules[0]] }
		}
	}

	/// DEV-1113: deleting one of Arx's rules remembers it, so no launch or Mac offers it again;
	/// Restore Default Links brings it back and forgets.
	@Test
	internal func aDeletedDefaultProxyRuleStaysDeletedUntilRestored() async throws {
		let own = proxyRule()
		let deleted = ProxyLinkRule.defaults[0]
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [own] + ProxyLinkRule.defaults }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.delete(deleted.id)))) {
			$0.$removedProxyLinkDefaults.withLock { $0 = [deleted.id] }
			$0.$proxyLinkRules.withLock { $0 = [own, ProxyLinkRule.defaults[1], ProxyLinkRule.defaults[2]] }
		}

		// The person's own rule isn't one to remember.
		await store.send(.ui(.proxyLinks(.delete(own.id)))) {
			$0.$proxyLinkRules.withLock { $0 = [ProxyLinkRule.defaults[1], ProxyLinkRule.defaults[2]] }
		}

		// A relaunch, and another Mac that hasn't offered the defaults yet: neither brings it back.
		var relaunched = BrowserPreferences(
			proxyLinkRules: store.state.proxyLinkRules,
			offeredProxyLinkDefaults: ProxyLinkRule.defaults.map(\.id),
			removedProxyLinkDefaults: store.state.removedProxyLinkDefaults
		)
		relaunched.offerDefaultProxyLinkRules()
		var otherMac = BrowserPreferences(removedProxyLinkDefaults: store.state.removedProxyLinkDefaults)
		otherMac.offerDefaultProxyLinkRules()
		#expect(!relaunched.proxyLinkRules.contains { $0.id == deleted.id })
		#expect(!otherMac.proxyLinkRules.contains { $0.id == deleted.id })

		await store.send(.ui(.proxyLinks(.restoreDefaults))) {
			$0.$proxyLinkRules.withLock { $0 = [ProxyLinkRule.defaults[1], ProxyLinkRule.defaults[2], deleted] }
			$0.$removedProxyLinkDefaults.withLock { $0 = [] }
		}
	}

	/// DEV-767: New Rule opens an empty form; Save is invalid until the rule is, then adds it and
	/// closes the form.
	@Test
	internal func addingAProxyRuleOpensTheFormAndSavesOnlyAValidRule() async throws {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.uuid = .constant(UUID(100))
		}
		await store.send(.ui(.proxyLinks(.newRule))) {
			$0.proxyLinkEditor = .init()
		}
		#expect(store.state.proxyLinkEditor?.isNew == true)
		#expect(store.state.proxyLinkEditor?.isValid == false)

		let filled = ProxyLinksEditor(
			name: "Example proxy",
			sourceHosts: "x.com, twitter.com",
			destinationTemplate: "https://fxtwitter.com{path}{query}{fragment}",
			testURL: "https://x.com/post"
		)
		await store.send(.ui(.proxyLinks(.changed(filled)))) {
			$0.proxyLinkEditor = filled
		}
		#expect(store.state.proxyLinkEditor?.isValid == true)
		await store.send(.ui(.proxyLinks(.save))) {
			$0.$proxyLinkRules.withLock { $0 = [proxyRule()] }
			$0.proxyLinkEditor = nil
		}
	}

	/// DEV-767: a click on a rule opens it for editing; Save replaces it in place and keeps its switch.
	@Test
	internal func editingAProxyRuleReplacesItInPlace() async throws {
		var disabled = proxyRule(id: 101, destination: "https://other.example{path}{query}{fragment}")
		disabled.isEnabled = false
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [proxyRule(), disabled] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.edit(disabled.id)))) {
			$0.proxyLinkEditor = .init(
				name: "Example proxy",
				sourceHosts: "x.com, twitter.com",
				destinationTemplate: "https://other.example{path}{query}{fragment}",
				editingID: disabled.id
			)
		}
		#expect(store.state.proxyLinkEditor?.isNew == false)

		var editor = try #require(store.state.proxyLinkEditor)
		editor.name = "Alternative"
		editor.sourceHosts = "x.com"
		await store.send(.ui(.proxyLinks(.changed(editor)))) {
			$0.proxyLinkEditor = editor
		}
		await store.send(.ui(.proxyLinks(.save))) {
			var edited = disabled
			edited.name = "Alternative"
			edited.sourceHosts = ["x.com"]
			$0.$proxyLinkRules.withLock { $0 = [proxyRule(), edited] }
			$0.proxyLinkEditor = nil
		}
	}

	/// DEV-767: Cancel closes the form and leaves the rules as they were, for a new rule and an edit.
	@Test
	internal func cancellingTheProxyRuleFormKeepsTheRules() async throws {
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [proxyRule()] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.newRule))) {
			$0.proxyLinkEditor = .init()
		}
		await store.send(.ui(.proxyLinks(.changed(.init(name: "Draft"))))) {
			$0.proxyLinkEditor = .init(name: "Draft")
		}
		await store.send(.ui(.proxyLinks(.cancel))) {
			$0.proxyLinkEditor = nil
		}

		await store.send(.ui(.proxyLinks(.edit(UUID(100))))) {
			$0.proxyLinkEditor = .init(rule: proxyRule())
		}
		await store.send(.ui(.proxyLinks(.changed(.init(name: "Renamed", editingID: UUID(100)))))) {
			$0.proxyLinkEditor = .init(name: "Renamed", editingID: UUID(100))
		}
		await store.send(.ui(.proxyLinks(.cancel))) {
			$0.proxyLinkEditor = nil
		}
		expectNoDifference(store.state.proxyLinkRules, [proxyRule()])

		// An edit made with the form closed is ignored.
		await store.send(.ui(.proxyLinks(.changed(.init(name: "Stray")))))
	}

	/// DEV-767: Delete in a rule's form removes the rule and closes the form.
	@Test
	internal func deletingAProxyRuleFromItsFormClosesIt() async throws {
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [proxyRule()] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.edit(UUID(100))))) {
			$0.proxyLinkEditor = .init(rule: proxyRule())
		}
		await store.send(.ui(.proxyLinks(.delete(UUID(100))))) {
			$0.$proxyLinkRules.withLock { $0 = [] }
			$0.proxyLinkEditor = nil
		}
	}

	/// DEV-1113: when another Mac already deleted the rule, Delete in its form still closes it.
	@Test
	internal func deletingARuleSyncAlreadyRemovedStillClosesItsForm() async throws {
		let state = SettingsFeature.State()
		state.$proxyLinkRules.withLock { $0 = [proxyRule()] }
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		await store.send(.ui(.proxyLinks(.edit(UUID(100))))) {
			$0.proxyLinkEditor = .init(rule: proxyRule())
		}
		store.state.$proxyLinkRules.withLock { $0 = [] }
		await store.send(.ui(.proxyLinks(.delete(UUID(100))))) {
			$0.proxyLinkEditor = nil
		}
	}

	@Test
	internal func proxyRulesRoundTripAndOldPreferencesDecodeWithNoPresets() async throws {
		let preferences = BrowserPreferences(proxyLinkRules: [proxyRule()])
		let encoded = try JSONEncoder().encode(preferences)
		expectNoDifference(try JSONDecoder().decode(BrowserPreferences.self, from: encoded), preferences)
		var old = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
		old.removeValue(forKey: "proxyLinkRules")
		let restored = try JSONDecoder().decode(BrowserPreferences.self, from: JSONSerialization.data(withJSONObject: old))
		expectNoDifference(restored.proxyLinkRules, [])
		let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: directory) }
		let client = BrowserWorkspaceClient(file: directory.appendingPathComponent("workspace.json"))
		try client.save(fixture(), preferences: preferences)
		expectNoDifference(try client.loadWithRecovery().preferences, preferences)
		var duplicate = preferences
		duplicate.proxyLinkRules.append(proxyRule())
		#expect(throws: LinkTransformationError.duplicateRule) { try duplicate.validate() }
	}
}

private func proxyRule(
	id: Int = 100,
	hosts: [String] = ["x.com", "twitter.com"],
	destination: String = "https://fxtwitter.com{path}{query}{fragment}"
) -> ProxyLinkRule {
	.init(id: UUID(id), name: "Example proxy", sourceHosts: hosts, destinationTemplate: destination)
}
