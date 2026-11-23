import AppUpdaterClient
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// Settings › General › Update channel and What's New after an update (DEV-888).
@Suite(.dependencies)
@MainActor
internal struct UpdateChannelSettingsTests {
	private static let ready: AppUpdaterClient.Status = .init(
		availability: .available,
		canCheck: true,
		automaticallyChecks: true,
		channel: .stable,
		offersBeta: true
	)

	private static let whatsNew: AppUpdaterClient.WhatsNew = .init(
		version: "0.3.0",
		build: "12",
		notes: "- Update channels",
		fullNotesURL: URL(string: "https://manual.arx.capturecontext.dev/help/release-notes")!
	)

	private static func settings(_ updates: AppUpdaterClient.Status?) -> SettingsFeature.State {
		var state: SettingsFeature.State = .init()
		state.updates = updates
		return state
	}

	// MARK: - Channel

	@Test
	internal func choosingBetaTellsTheUpdater() async {
		let channels: LockIsolated<[AppUpdaterClient.Channel]> = .init([])
		let store = TestStore(initialState: Self.settings(Self.ready)) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.setChannel = { channel in channels.withValue { $0.append(channel) } }
		}

		await store.send(.ui(.updateChannel(.beta))) {
			$0.updates?.channel = .beta
		}

		// Already on Beta: nothing to tell Sparkle.
		await store.send(.ui(.updateChannel(.beta)))
		await store.send(.ui(.updateChannel(.stable))) {
			$0.updates?.channel = .stable
		}
		await store.finish()
		#expect(channels.value == [.beta, .stable])
	}

	@Test
	internal func aBuildWithoutABetaFeedStaysOnStable() async {
		var stableOnly: AppUpdaterClient.Status = Self.ready
		stableOnly.offersBeta = false

		// testValue's setChannel is unimplemented, so reaching it would fail the test.
		let store = TestStore(initialState: Self.settings(stableOnly)) { SettingsFeature() }
		await store.send(.ui(.updateChannel(.beta)))

		let unavailable = TestStore(initialState: Self.settings(.unavailable(.debugBuild))) { SettingsFeature() }
		await unavailable.send(.ui(.updateChannel(.beta)))

		let notStarted = TestStore(initialState: Self.settings(nil)) { SettingsFeature() }
		await notStarted.send(.ui(.updateChannel(.beta)))
	}

	// MARK: - What's New

	@Test
	internal func whatsNewArrivesWithTheUpdatersFirstState() async {
		let store = TestStore(initialState: SettingsFeature.State()) {
			SettingsFeature()
		} withDependencies: {
			$0.appUpdater.start = {
				AsyncStream { continuation in
					continuation.yield(.status(Self.ready))
					continuation.yield(.whatsNew(Self.whatsNew))
					continuation.finish()
				}
			}
		}

		await store.send(.ui(.startUpdates))
		await store.receive(\.event.updatesChanged) { $0.updates = Self.ready }
		await store.receive(\.event.whatsNewReady) { $0.whatsNew = Self.whatsNew }
		await store.send(.ui(.dismissWhatsNew)) { $0.whatsNew = nil }

		// Closed already: the link does nothing.
		await store.send(.ui(.openReleaseNotes))
	}

	@Test
	internal func theFullNotesOpenInANewTab() async {
		let organization = IntegrationFeatureTests().fixture()
		var initial: AppFeature.State = .init(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		initial.settings.whatsNew = Self.whatsNew
		let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
			$0.uuid = .incrementing
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.settings(.ui(.openReleaseNotes))) {
			$0.settings.whatsNew = nil
		}
		await store.receive(\.settings.delegate.openReleaseNotes)
		await store.receive(\.main.ui.openInNewTab)
		await store.skipReceivedActions()
		#expect(store.state.main.sidebar.selectedTab?.restoration.url == Self.whatsNew.fullNotesURL)
	}
}
