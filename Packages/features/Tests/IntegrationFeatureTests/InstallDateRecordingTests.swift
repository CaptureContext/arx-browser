import BrowserCore
import BrowserWorkspaceClient
import Foundation
import MemberNumberClient
import SettingsFeature
import Testing
import _ComposableArchitecture

@testable import AppFeature

/// DEV-1323: the launch records when this Arx was first installed on this Mac, once, and Settings'
/// identity card reads it for Member since, until a member number's sign-in hands it over to the
/// account's day from Arx's server.
@Suite(.dependencies)
@MainActor
internal struct InstallDateRecordingTests {
	private static let now: Date = .init(timeIntervalSince1970: 1_795_000_000)

	@Test
	internal func aFirstLaunchRecordsToday() async {
		let document: WorkspaceDocument = Self.document(installedAt: nil)
		let initial: AppFeature.State = Self.state(document: document)
		let store = TestStore(initialState: initial) {
			SharedPreferences()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.installDateEvidence = InstallDateEvidence(creationDates: { [] })
			$0.date = DateGenerator.constant(Self.now)
		}

		await store.send(.recordInstallDate)
		#expect(document.preferences.installedAt == Self.now)
	}

	@Test
	internal func anExistingInstallRecordsItsDataFolderDate() async {
		let document: WorkspaceDocument = Self.document(installedAt: nil)
		let dataFolder: Date = Self.now.addingTimeInterval(-86_400 * 11)
		let profileFolder: Date = Self.now.addingTimeInterval(-86_400 * 10)
		let initial: AppFeature.State = Self.state(document: document)
		let store = TestStore(initialState: initial) {
			SharedPreferences()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.installDateEvidence = InstallDateEvidence(creationDates: { [profileFolder, dataFolder] })
			$0.date = DateGenerator.constant(Self.now)
		}

		await store.send(.recordInstallDate)
		#expect(document.preferences.installedAt == dataFolder)
	}

	@Test
	internal func theDateIsRecordedOnlyOnce() async {
		let recorded: Date = Self.now.addingTimeInterval(-86_400 * 30)
		let document: WorkspaceDocument = Self.document(installedAt: recorded)
		let initial: AppFeature.State = Self.state(document: document)
		// The evidence isn't read again: InstallDateEvidence's test value fails the test if it is.
		let store = TestStore(initialState: initial) {
			SharedPreferences()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.date = DateGenerator.constant(Self.now)
		}

		await store.send(.recordInstallDate)
		await store.send(.recordInstallDate)
		#expect(document.preferences.installedAt == recorded)
	}

	@Test
	internal func settingsReadsTheRecordedDate() {
		let recorded: Date = Self.now.addingTimeInterval(-86_400 * 30)
		let document: WorkspaceDocument = Self.document(installedAt: recorded)
		let state: SettingsFeature.State = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			SettingsFeature.State()
		}
		#expect(state.installDate == recorded)
		#expect(state.cardMemberSince == recorded)
	}

	/// Before a sign-in the card shows this Mac's install date; the claim sends that day, and
	/// from then on the card shows the account's day the server answers with, which is saved with
	/// the number, so it comes back offline after a relaunch.
	@Test
	internal func signingInHandsTheCardOverToTheAccountsDay() async throws {
		// This Mac installed Arx on 16 November; the account's other Mac on 2 November.
		let installed: Date = try #require(Self.localDate(day: 16, hour: 9))
		let document: WorkspaceDocument = Self.document(installedAt: installed)
		let suite: String = "InstallDateRecordingTests.\(UUID().uuidString)"
		let defaults: UserDefaults = try #require(UserDefaults(suiteName: suite))
		defer { defaults.removePersistentDomain(forName: suite) }
		let sentDays: LockIsolated<[String?]> = .init([])

		var client: MemberNumberClient = .live(defaults: defaults)
		client.availableProviders = { [.apple] }
		client.signIn = { _ throws(MemberNumberFailure) in "token" }
		client.claim = { provider, _, memberSince throws(MemberNumberFailure) in
			sentDays.withValue { $0.append(memberSince) }
			return MemberNumber(index: 42, registeredOn: "2026-11-18", provider: provider, memberSince: "2026-11-02")
		}
		let claiming: MemberNumberClient = client

		let state: SettingsFeature.State = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			SettingsFeature.State()
		}
		#expect(state.cardMemberSince == installed)

		let store = TestStore(initialState: state) {
			SettingsFeature()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.memberNumber = claiming
		}
		store.exhaustivity = .off

		await store.send(.memberNumber(.ui(.appeared)))
		await store.send(.memberNumber(.ui(.claim(.apple))))
		await store.receive(\.memberNumber.event.claimFinished)

		#expect(sentDays.value == ["2026-11-16"])
		let shown: Date = try #require(store.state.cardMemberSince)
		let expected: Date = try #require(Self.localDate(day: 2, hour: 12))
		#expect(shown == expected)

		// A relaunch, offline: the saved number brings the account's day back.
		var offline: MemberNumberClient = .live(defaults: defaults)
		offline.availableProviders = { [.apple] }
		let reading: MemberNumberClient = offline
		let relaunched: SettingsFeature.State = withDependencies {
			$0.workspaceDocument = document
		} operation: {
			SettingsFeature.State()
		}
		let second = TestStore(initialState: relaunched) {
			SettingsFeature()
		} withDependencies: {
			$0.workspaceDocument = document
			$0.memberNumber = reading
		}
		second.exhaustivity = .off
		await second.send(.memberNumber(.ui(.appeared)))
		#expect(second.state.cardMemberSince == expected)
	}

	/// A day of November 2026 at `hour` on this Mac's calendar.
	private static func localDate(
		day: Int,
		hour: Int
	) -> Date? {
		var calendar: Calendar = .init(identifier: .gregorian)
		calendar.timeZone = .current
		var components: DateComponents = .init()
		components.year = 2026
		components.month = 11
		components.day = day
		components.hour = hour
		return calendar.date(from: components)
	}

	private static func document(installedAt: Date?) -> WorkspaceDocument {
		var preferences: BrowserPreferences = .init()
		preferences.installedAt = installedAt
		return WorkspaceDocument(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: IntegrationFeatureTests().fixture(),
			preferences: preferences
		)
	}

	private static func state(document: WorkspaceDocument) -> AppFeature.State {
		let organization: BrowserOrganization = IntegrationFeatureTests().fixture()
		return withDependencies {
			$0.workspaceDocument = document
		} operation: {
			AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		}
	}
}
