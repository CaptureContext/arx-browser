import AppKit
import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import SettingsFeature
import Testing
import _ComposableArchitecture

@MainActor
@Suite(.dependencies, .serialized)
internal struct SavedPasswordsFeatureTests {
	// MARK: - Opening

	@Test
	internal func onlyListedProfilesOpenTheirPasswords() async throws {
		let profile = Profile(id: .init(rawValue: UUID()), name: "Work")
		var state = SettingsFeature.State()
		state.extensionProfiles = [profile]
		let store = TestStore(initialState: state) {
			SettingsFeature()
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		// A private or unknown profile isn't listed, so nothing opens.
		await store.send(.ui(.showSavedPasswords(.init(rawValue: UUID()))))
		#expect(store.state.savedPasswords == nil)

		await store.send(.ui(.showSavedPasswords(profile.id)))
		#expect(store.state.savedPasswords == .init(profileID: profile.id, profileName: "Work"))

		await store.send(.savedPasswords(.delegate(.dismiss)))
		#expect(store.state.savedPasswords == nil)

		await store.send(.ui(.showSavedPasswords(profile.id)))
		await store.send(.configureExtensions([]))
		#expect(store.state.savedPasswords == nil)
	}

	// MARK: - Listing

	@Test
	internal func appearingListsTheProfilesPasswords() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine)

		await store.send(.ui(.appeared))
		await store.receive(\.event.listed) {
			$0.isLoading = false
			$0.list = PasswordsEngineDouble.list
		}
		#expect(engine.listed == [Self.profileID])
		#expect(store.state.visiblePasswords.map(\.site) == ["a.test", "b.test"])
	}

	@Test
	internal func searchMatchesSitesAndUsernames() async throws {
		var state = SavedPasswordsFeature.State(profileID: Self.profileID, profileName: "Work", list: PasswordsEngineDouble.list, isLoading: false)
		state.query = "ME"
		#expect(state.visiblePasswords.map(\.site) == ["b.test"])
		state.query = "a.t"
		#expect(state.visiblePasswords.map(\.site) == ["a.test"])
	}

	@Test
	internal func unavailableEnginesSaySo() async throws {
		let engine = PasswordsEngineDouble()
		engine.listFailure = .unavailable
		let store = makeStore(engine)

		await store.send(.ui(.appeared))
		await store.receive(\.event.listed) {
			$0.isLoading = false
			$0.notice = .failure(.unavailable)
		}
	}

	// MARK: - Adding and editing

	@Test
	internal func addingLendsTheFieldAndKeepsTheValueOutOfState() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)
		let field = NSSecureTextField()
		field.stringValue = Self.probe

		await store.send(.ui(.addPassword)) {
			$0.editor = .init(mode: .add, site: "", username: "", passwordField: Self.field(0))
		}
		BrowserPasswordFields.register(field, as: Self.field(0))
		defer { BrowserPasswordFields.unregister(Self.field(0)) }
		await store.send(.ui(.editorSiteChanged(" c.test "))) {
			$0.editor?.site = " c.test "
		}
		await store.send(.ui(.editorUsernameChanged(" me "))) {
			$0.editor?.username = " me "
		}
		await store.send(.ui(.saveEditor)) {
			$0.editor?.isSaving = true
		}
		await store.receive(\.event.saved) {
			$0.list = PasswordsEngineDouble.changed
			$0.editor = nil
		}
		expectNoDifference(engine.edits, [.init(
			profileID: Self.profileID,
			target: .new(url: "c.test"),
			username: "me",
			passwordField: Self.field(0)
		)])

		// The double read the field the way native does; nothing kept the value.
		#expect(engine.readValues == [Self.probe])
		#expect(field.stringValue.isEmpty)
		#expect(!String(customDumping: store.state).contains(Self.probe))
	}

	@Test
	internal func addingNeedsASite() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.addPassword)) {
			$0.editor = .init(mode: .add, site: "", username: "", passwordField: Self.field(0))
		}
		await store.send(.ui(.saveEditor)) {
			$0.notice = .failure(.invalid)
		}
		#expect(engine.edits.isEmpty)
	}

	@Test
	internal func editingNamesTheListedPassword() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.editPassword(2))) {
			$0.editor = .init(mode: .edit(2), site: "b.test", username: "me", passwordField: Self.field(0))
		}
		await store.send(.ui(.saveEditor)) {
			$0.editor?.isSaving = true
		}
		await store.receive(\.event.saved) {
			$0.list = PasswordsEngineDouble.changed
			$0.editor = nil
		}
		#expect(engine.edits.map(\.target) == [.existing(listing: "L1", id: 2)])
	}

	@Test
	internal func aSiteAndUsernameAlreadySavedKeepTheEditorOpen() async throws {
		let engine = PasswordsEngineDouble()
		engine.failure = .exists
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.editPassword(1))) {
			$0.editor = .init(mode: .edit(1), site: "a.test", username: "", passwordField: Self.field(0))
		}
		await store.send(.ui(.saveEditor)) {
			$0.editor?.isSaving = true
		}
		await store.receive(\.event.saved) {
			$0.editor?.isSaving = false
			$0.notice = .failure(.exists)
		}
	}

	// MARK: - Removing

	@Test
	internal func removingAsksFirst() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.removePassword(1))) {
			$0.removal = .init(id: 1, site: "a.test", isNeverSaved: false)
		}
		await store.send(.ui(.cancelRemoval)) {
			$0.removal = nil
		}
		#expect(engine.removed.isEmpty)

		await store.send(.ui(.removeNeverSavedSite(3))) {
			$0.removal = .init(id: 3, site: "never.test", isNeverSaved: true)
		}
		await store.send(.ui(.confirmRemoval)) {
			$0.removal = nil
		}
		await store.receive(\.event.removed) {
			$0.list = PasswordsEngineDouble.changed
		}
		#expect(engine.removed.map(\.id) == [3])
		#expect(engine.removed.map(\.listing) == ["L1"])
	}

	@Test
	internal func aStaleListIsReloaded() async throws {
		let engine = PasswordsEngineDouble()
		engine.failure = .stale
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.removePassword(2))) {
			$0.removal = .init(id: 2, site: "b.test", isNeverSaved: false)
		}
		await store.send(.ui(.confirmRemoval)) {
			$0.removal = nil
		}
		await store.receive(\.event.removed) {
			$0.notice = .failure(.stale)
			$0.isLoading = true
		}
		await store.receive(\.event.listed) {
			$0.isLoading = false
		}
	}

	// MARK: - Revealing

	@Test
	internal func copyingAuthenticatesInTheEngine() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.copyPassword(1)))
		await store.receive(\.event.copied) {
			$0.notice = .copied
		}
		#expect(engine.reveals.map(\.mode) == [.copy])
		#expect(engine.reveals.map(\.id) == [1])

		engine.failure = .denied
		await store.send(.ui(.copyPassword(1))) {
			$0.notice = nil
		}
		await store.receive(\.event.copied) {
			$0.notice = .failure(.denied)
		}
	}

	@Test
	internal func showingWritesIntoTheLentFieldOnceItsInAWindow() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.showPassword(2))) {
			$0.reveal = .init(id: 2, site: "b.test", username: "me", field: Self.field(0))
		}
		#expect(engine.reveals.isEmpty)
		await store.send(.ui(.revealFieldReady))
		await store.receive(\.event.revealed)
		#expect(engine.reveals.map(\.mode) == [.show(Self.field(0))])

		await store.send(.ui(.closeReveal)) {
			$0.reveal = nil
		}
	}

	@Test
	internal func aDeniedRevealClosesTheSheet() async throws {
		let engine = PasswordsEngineDouble()
		engine.failure = .denied
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.showPassword(2))) {
			$0.reveal = .init(id: 2, site: "b.test", username: "me", field: Self.field(0))
		}
		await store.send(.ui(.revealFieldReady))
		await store.receive(\.event.revealed) {
			$0.reveal = nil
			$0.notice = .failure(.denied)
		}
	}

	// MARK: - Importing

	@Test
	internal func importingReportsConflictsAndReloads() async throws {
		let engine = PasswordsEngineDouble()
		let store = makeStore(engine, loaded: true)
		let file = URL(fileURLWithPath: "/tmp/passwords.csv")

		await store.send(.ui(.importPresented(true))) {
			$0.isImporting = true
		}
		await store.send(.ui(.importFile(file))) {
			$0.isImporting = false
			$0.isLoading = true
		}
		await store.receive(\.event.imported) {
			$0.importSummary = PasswordsEngineDouble.summary
		}
		await store.receive(\.event.listed) {
			$0.isLoading = false
		}
		#expect(engine.imports == [file])
		await store.send(.ui(.dismissImportSummary)) {
			$0.importSummary = nil
		}
	}

	@Test
	internal func aFileWithoutAPasswordHeaderIsExplained() async throws {
		let engine = PasswordsEngineDouble()
		engine.failure = .badFormat
		let store = makeStore(engine, loaded: true)

		await store.send(.ui(.importFile(URL(fileURLWithPath: "/tmp/notes.csv")))) {
			$0.isLoading = true
		}
		await store.receive(\.event.imported) {
			$0.notice = .failure(.badFormat)
		}
		await store.receive(\.event.listed) {
			$0.isLoading = false
			$0.notice = .failure(.badFormat)
		}
	}

	// MARK: - Support

	private static let profileID = Profile.ID(rawValue: UUID(9))
	private static let probe = "arx-probe-\(UUID().uuidString)"

	private static func field(_ index: Int) -> BrowserPasswordFieldID {
		.init(rawValue: UUID(index))
	}

	private func makeStore(
		_ engine: PasswordsEngineDouble,
		loaded: Bool = false
	) -> TestStoreOf<SavedPasswordsFeature> {
		TestStore(
			initialState: .init(
				profileID: Self.profileID,
				profileName: "Work",
				list: loaded ? PasswordsEngineDouble.list : .init(),
				isLoading: !loaded
			)
		) {
			SavedPasswordsFeature()
		} withDependencies: {
			$0.browserEngine = engine.client
			$0.uuid = .incrementing
		}
	}
}

/// Records what Settings asks the engine. Like native, it reads a lent field once and empties it.
@MainActor
private final class PasswordsEngineDouble {
	struct Reveal: Equatable {
		var id: UInt32
		var mode: BrowserPasswordReveal
	}

	static let list = BrowserSavedPasswordList(
		listing: "L1",
		passwords: [
			.init(id: 2, site: "b.test", origin: "https://b.test", username: "me"),
			.init(id: 1, site: "a.test", origin: "https://a.test", username: ""),
		],
		neverSaved: [.init(id: 3, site: "never.test", origin: "https://never.test")]
	)

	static let changed = BrowserSavedPasswordList(
		listing: "L2",
		passwords: [.init(id: 1, site: "c.test", origin: "https://c.test", username: "me")]
	)

	static let summary = BrowserPasswordImportSummary(
		imported: 2,
		conflicts: [.init(site: "a.test", username: "")],
		conflictCount: 1,
		skipped: [.init(site: "", username: "x", reason: .missingURL)],
		skippedCount: 1
	)

	/// Every call but listing fails with this.
	var failure: BrowserSavedPasswordFailure?
	var listFailure: BrowserSavedPasswordFailure?
	var listed: [Profile.ID] = []
	var edits: [BrowserPasswordEdit] = []
	var readValues: [String] = []
	var removed: [(listing: String, id: UInt32)] = []
	var reveals: [Reveal] = []
	var imports: [URL] = []

	var client: BrowserEngineClient {
		var client = BrowserEngineClient(status: { .ready })
		client.savedPasswordsAreAvailable = { true }
		client.savedPasswords = { [self] id throws(BrowserSavedPasswordFailure) in
			listed.append(id)
			if let listFailure { throw listFailure }
			return Self.list
		}
		client.savePassword = { [self] edit throws(BrowserSavedPasswordFailure) in
			edits.append(edit)
			if let id = edit.passwordField, let field = BrowserPasswordFields.field(id) {
				readValues.append(field.stringValue)
				field.stringValue = ""
			}
			if let failure { throw failure }
			return Self.changed
		}
		client.removeSavedPassword = { [self] _, listing, id throws(BrowserSavedPasswordFailure) in
			removed.append((listing, id))
			if let failure { throw failure }
			return Self.changed
		}
		client.revealSavedPassword = { [self] _, _, id, reason, mode throws(BrowserSavedPasswordFailure) in
			#expect(!reason.isEmpty)
			reveals.append(.init(id: id, mode: mode))
			if let failure { throw failure }
		}
		client.importPasswords = { [self] _, file throws(BrowserSavedPasswordFailure) in
			imports.append(file)
			if let failure { throw failure }
			return Self.summary
		}
		return client
	}
}
