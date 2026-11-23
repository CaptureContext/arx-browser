import AppKit
import BrowserCore
import Foundation
import LocalAuthentication
import _Dependencies

/// The "Passwords and sign-ins" step's service (DEV-650).
///
/// Only the migration assistant's step uses it, in the foreground, after the device owner
/// confirms. Nothing in MCP or the agent tools reaches it. Decrypted records stay in the
/// client's session; features get counts, sites and outcomes.
public struct CredentialMigrationClient: Sendable {
	/// The source's browser and profiles, or nil when Arx can't read its passwords directly.
	public var source: @Sendable (MigrationSource.ID) async -> CredentialSource?

	/// Whether the engine takes decrypted records. When it doesn't, the step goes to CSV
	/// without touching the Keychain.
	public var canWrite: @Sendable () async -> Bool
	public var isForeground: @MainActor @Sendable () -> Bool

	/// Asks the device owner (Touch ID or the login password) with this reason.
	public var confirmPresence: @Sendable (String) async -> Bool

	/// Makes the one Keychain read, then decrypts the profile's passwords and cookies in
	/// memory. After a denial it throws `keyDenied` without asking macOS again.
	public var read: @Sendable (MigrationSource.ID, String) async throws -> CredentialInventory

	/// Reads several profiles of one browser with the one Keychain read, in the given order
	/// (DEV-842). A profile Arx can't decrypt fails the whole read; nothing is kept.
	public var readProfiles: @Sendable (MigrationSource.ID, [String]) async throws -> [CredentialInventory]

	/// Writes the selection into an ordinary Arx profile and ends the read session.
	public var migrate: @Sendable (UUID, CredentialSelection, Profile.ID) async throws -> CredentialReport

	/// Removes exactly what a report's batch added.
	public var undo: @Sendable (UUID) async throws -> Void

	/// Drops a read session's decrypted records without writing them.
	public var discard: @Sendable (UUID) async -> Void

	/// Drops every read session's decrypted records, for hosts that remove the assistant.
	/// Undo records stay: they hold keys, not values.
	public var discardAll: @Sendable () async -> Void

	public init(
		source: @escaping @Sendable (MigrationSource.ID) async -> CredentialSource? = { _ in nil },
		canWrite: @escaping @Sendable () async -> Bool = { false },
		isForeground: @escaping @MainActor @Sendable () -> Bool = { true },
		confirmPresence: @escaping @Sendable (String) async -> Bool = { _ in false },
		read: @escaping @Sendable (MigrationSource.ID, String) async throws -> CredentialInventory = { _, _ in
			throw CredentialMigrationFailure.unreadable
		},
		readProfiles: @escaping @Sendable (MigrationSource.ID, [String]) async throws -> [CredentialInventory] = { _, _ in
			throw CredentialMigrationFailure.unreadable
		},
		migrate: @escaping @Sendable (UUID, CredentialSelection, Profile.ID) async throws -> CredentialReport = { _, _, _ in
			throw CredentialMigrationFailure.unknownSession
		},
		undo: @escaping @Sendable (UUID) async throws -> Void = { _ in
			throw CredentialMigrationFailure.unknownSession
		},
		discard: @escaping @Sendable (UUID) async -> Void = { _ in },
		discardAll: @escaping @Sendable () async -> Void = {}
	) {
		self.source = source
		self.canWrite = canWrite
		self.isForeground = isForeground
		self.confirmPresence = confirmPresence
		self.read = read
		self.readProfiles = readProfiles
		self.migrate = migrate
		self.undo = undo
		self.discard = discard
		self.discardAll = discardAll
	}
}

extension CredentialMigrationClient {
	/// A client over the given Chromium browsers, Keychain reader and writer.
	public static func running(
		browsers: [ChromiumSafeStorage.Browser],
		readSecret: @escaping @Sendable (ChromiumSafeStorage.Item) throws(ChromiumSafeStorage.KeyFailure) -> Data,
		writer: CredentialDestinationWriter,
		makeID: @escaping @Sendable () -> UUID = { UUID() },
		now: @escaping @Sendable () -> Date = { Date() }
	) -> Self {
		.running(
			sources: browsers.map(CredentialBrowser.init),
			readSecret: readSecret,
			writer: writer,
			makeID: makeID,
			now: now
		)
	}

	/// A client over the given browsers of any kind, Keychain reader and writer (DEV-896).
	public static func running(
		sources browsers: [CredentialBrowser],
		readSecret: @escaping @Sendable (ChromiumSafeStorage.Item) throws(ChromiumSafeStorage.KeyFailure) -> Data,
		writer: CredentialDestinationWriter,
		makeID: @escaping @Sendable () -> UUID = { UUID() },
		now: @escaping @Sendable () -> Date = { Date() }
	) -> Self {
		let sessions: CredentialMigrationSessions = .init(
			browsers: browsers,
			readSecret: readSecret,
			writer: writer,
			makeID: makeID,
			now: now
		)
		return .init(
			source: { await sessions.source($0) },
			canWrite: { await writer.isAvailable() },
			isForeground: { NSApplication.shared.isActive },
			confirmPresence: { reason in
				let context = LAContext()
				var error: NSError?
				guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
				else { return false }

				let confirmed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false

				// The Touch ID or password panel deactivates Arx, and Arx becomes active again a
				// moment after it closes. Wait for that, so the foreground check that follows
				// doesn't refuse a user who never left (Maxim's Arc import, 11 Nov).
				if confirmed { await Self.awaitActivation(timeout: .seconds(3)) }
				return confirmed
			},
			read: { try await sessions.read(source: $0, profiles: [$1])[0] },
			readProfiles: { try await sessions.read(source: $0, profiles: $1) },
			migrate: { try await sessions.migrate(session: $0, selection: $1, into: $2) },
			undo: { try await sessions.undo(batch: $0) },
			discard: { await sessions.discard($0) },
			discardAll: { await sessions.discardAll() }
		)
	}
}

extension CredentialMigrationClient {
	/// Waits until Arx is the active app again, or `timeout` passes.
	@MainActor
	fileprivate static func awaitActivation(timeout: Duration) async {
		let deadline: ContinuousClock.Instant = .now + timeout
		while !NSApplication.shared.isActive, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(50))
		}
	}
}

extension CredentialMigrationClient: DependencyKey {
	/// The real browsers and login keychain with `writer`. Firefox, Zen and Safari need no
	/// Keychain item (DEV-896). AppFeature passes the engine's
	/// writer (ABI46); it reports itself unavailable on an older engine, and then the step
	/// offers the CSV import without reading the Keychain.
	public static func live(writer: CredentialDestinationWriter) -> Self {
		.running(
			sources: CredentialBrowser.all(),
			readSecret: { item throws(ChromiumSafeStorage.KeyFailure) in
				try ChromiumSafeStorage.readSecret(item)
			},
			writer: writer
		)
	}

	/// Without an engine to write into, nothing can move: the step offers CSV.
	public static var liveValue: Self { .live(writer: .unavailable) }

	/// For `Arx --headless`: no source is offered, nothing is read and no prompt is shown,
	/// not the Keychain's, Touch ID's or a Mozilla profile's (DEV-896). Every read fails
	/// with `unattended`, and the step, were it ever shown, would offer CSV.
	public static var unattended: Self {
		.init(
			source: { _ in nil },
			canWrite: { false },
			isForeground: { false },
			confirmPresence: { _ in false },
			read: { _, _ in throw CredentialMigrationFailure.unattended },
			readProfiles: { _, _ in throw CredentialMigrationFailure.unattended },
			migrate: { _, _, _ in throw CredentialMigrationFailure.unattended },
			undo: { _ in throw CredentialMigrationFailure.unattended }
		)
	}

	public static var testValue: Self { .init() }
	public static var previewValue: Self { .init() }
}

extension DependencyValues {
	public var credentialMigration: CredentialMigrationClient {
		get { self[CredentialMigrationClient.self] }
		set { self[CredentialMigrationClient.self] = newValue }
	}
}

/// Holds decrypted records between the read and the write, and undo records after it.
internal actor CredentialMigrationSessions {
	private struct Session {
		internal var inventory: CredentialInventory
		internal var contents: ChromiumCredentialStore.Contents
	}

	private let browsers: [CredentialBrowser]
	private let readSecret: @Sendable (ChromiumSafeStorage.Item) throws(ChromiumSafeStorage.KeyFailure) -> Data
	private let writer: CredentialDestinationWriter
	private let makeID: @Sendable () -> UUID
	private let now: @Sendable () -> Date

	/// Sources whose prompt was denied in this run. They aren't asked again.
	private var denied: Set<MigrationSource.ID> = []
	private var sessions: [UUID: Session] = [:]
	private var batches: [UUID: CredentialUndoRecord] = [:]

	internal init(
		browsers: [CredentialBrowser],
		readSecret: @escaping @Sendable (ChromiumSafeStorage.Item) throws(ChromiumSafeStorage.KeyFailure) -> Data,
		writer: CredentialDestinationWriter,
		makeID: @escaping @Sendable () -> UUID,
		now: @escaping @Sendable () -> Date
	) {
		self.browsers = browsers
		self.readSecret = readSecret
		self.writer = writer
		self.makeID = makeID
		self.now = now
	}

	internal func source(_ id: MigrationSource.ID) -> CredentialSource? {
		guard let browser = browsers.first(where: { $0.sourceID == id }) else { return nil }

		let profiles = browser.profiles()
		guard !profiles.isEmpty else { return nil }

		return .init(
			sourceID: id,
			browserName: browser.name,
			access: browser.access,
			profiles: profiles
		)
	}

	internal func read(
		source id: MigrationSource.ID,
		profiles profileIDs: [String]
	) async throws -> [CredentialInventory] {
		guard !denied.contains(id) else { throw CredentialMigrationFailure.keyDenied }
		guard let browser = browsers.first(where: { $0.sourceID == id }), !profileIDs.isEmpty
		else { throw CredentialMigrationFailure.unreadable }

		// Only profiles the browser lists, so a crafted ID can't point elsewhere.
		let listed = Set(browser.profiles().map(\.id))
		guard profileIDs.allSatisfy(listed.contains)
		else { throw CredentialMigrationFailure.unreadable }

		// Nothing could be written, so don't make macOS ask.
		guard await writer.isAvailable()
		else { throw CredentialMigrationFailure.writerUnavailable }

		let read: [(CredentialInventory, ChromiumCredentialStore.Contents)]
		switch browser.store {
		case let .chromium(chromium):
			read = try readChromium(chromium, source: id, profiles: profileIDs)

		case let .mozilla(root):
			read = try profileIDs.map { profileID in
				guard let directory = browser.mozillaDirectory(profile: profileID, root: root)
				else { throw CredentialMigrationFailure.unreadable }

				let contents: ChromiumCredentialStore.Contents
				do {
					contents = try MozillaCredentialStore.read(profile: directory, now: now())
				} catch MozillaCredentialStore.Failure.primaryPassword {
					throw CredentialMigrationFailure.primaryPassword
				} catch {
					throw CredentialMigrationFailure.unreadable
				}
				return (inventory(contents, source: id, profile: profileID), contents)
			}

		case let .safari(home):
			read = try profileIDs.map { profileID in
				var contents: ChromiumCredentialStore.Contents = .init()
				let file = SafariCookies.files(home: home).first {
					FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
				}
				guard let file else { throw CredentialMigrationFailure.unreadable }

				do {
					try SafariCookies.read(Data(contentsOf: file), now: now(), into: &contents)
				} catch {
					throw CredentialMigrationFailure.unreadable
				}
				return (inventory(contents, source: id, profile: profileID), contents)
			}
		}

		for (inventory, contents) in read {
			sessions[inventory.sessionID] = .init(inventory: inventory, contents: contents)
		}
		return read.map(\.0)
	}

	private func readChromium(
		_ browser: ChromiumSafeStorage.Browser,
		source id: MigrationSource.ID,
		profiles profileIDs: [String]
	) throws -> [(CredentialInventory, ChromiumCredentialStore.Contents)] {
		let secret: Data
		do {
			secret = try readSecret(browser.item)
		} catch .denied {
			denied.insert(id)
			throw CredentialMigrationFailure.keyDenied
		} catch {
			throw CredentialMigrationFailure.keyMissing
		}

		var key: ChromiumCipher.Key = .init(secret: secret)
		defer { key.erase() }

		return try profileIDs.map { profileID in
			let contents: ChromiumCredentialStore.Contents
			do {
				contents = try ChromiumCredentialStore.read(
					profile: browser.directory(profile: profileID),
					key: key,
					now: now()
				)
			} catch {
				throw CredentialMigrationFailure.unreadable
			}
			return (inventory(contents, source: id, profile: profileID), contents)
		}
	}

	private func inventory(
		_ contents: ChromiumCredentialStore.Contents,
		source id: MigrationSource.ID,
		profile: String
	) -> CredentialInventory {
		.init(
			sessionID: makeID(),
			sourceID: id,
			sourceProfileID: profile,
			passwordCount: contents.passwords.count,
			unreadablePasswordCount: contents.unreadablePasswords,
			httpAuthPasswordCount: contents.httpAuthPasswords,
			sites: ChromiumCredentialStore.sites(of: contents)
		)
	}

	internal func migrate(
		session id: UUID,
		selection: CredentialSelection,
		into profile: Profile.ID
	) async throws -> CredentialReport {
		// The records are written once; a failed write needs a fresh read.
		guard let session = sessions.removeValue(forKey: id)
		else { throw CredentialMigrationFailure.unknownSession }

		var undo: CredentialUndoRecord = .init(profileID: profile)
		var passwords: CredentialReport.Passwords?
		if selection.passwords, !session.contents.passwords.isEmpty {
			let result = try await writer.importPasswords(profile, session.contents.passwords)

			// Unconfirmed rows may be stored; undo removes them only if they are.
			undo.passwords = result.imported + result.unconfirmed
			passwords = .init(
				imported: result.imported.count,
				conflicts: result.conflicts,
				skipped: result.skipped + session.inventory.unreadablePasswordCount,
				httpAuthNotImported: session.inventory.httpAuthPasswordCount
			)
		} else if session.inventory.httpAuthPasswordCount > 0 {
			// Nothing else to import, but the summary still says what stayed behind.
			passwords = .init(imported: 0, httpAuthNotImported: session.inventory.httpAuthPasswordCount)
		}

		let grouping = session.contents.grouping
		let cookies = session.contents.cookies.filter {
			selection.signInHosts.contains(grouping.site(forHost: $0.domain))
		}
		var writes: [String: CredentialCookieWrite] = [:]
		var checks: [String: Bool]?
		if !cookies.isEmpty {
			do {
				let result = try await writer.setCookies(profile, cookies)
				undo.cookies = result.accepted + result.unconfirmed
				for cookie in result.accepted {
					writes[grouping.site(forHost: cookie.domain), default: .init()].accepted += 1
				}
				for cookie in result.existing {
					writes[grouping.site(forHost: cookie.domain), default: .init()].existing += 1
				}
				for cookie in result.rejected {
					writes[grouping.site(forHost: cookie.domain), default: .init()].rejected += 1
				}

				// A site counts as kept only when every cookie Arx set for it is there.
				if let present = await writer.checkCookies(profile, result.accepted) {
					var sites: [String: Bool] = [:]
					for site in writes.keys { sites[site] = true }
					for cookie in result.accepted where !present.contains(cookie) {
						sites[grouping.site(forHost: cookie.domain)] = false
					}
					checks = sites
				}
			} catch {
				// Passwords already written stay undoable: report them, with every selected
				// sign-in as refused, instead of losing the batch.
				guard !undo.passwords.isEmpty else { throw error }

				writes = [:]
				checks = nil
			}
		}

		let report: CredentialReport = .init(
			batchID: makeID(),
			passwords: passwords,
			sites: CredentialReporting.outcomes(
				inventory: session.inventory,
				selection: selection,
				writes: writes,
				checks: checks
			)
		)
		batches[report.batchID] = undo
		return report
	}

	internal func undo(batch id: UUID) async throws {
		guard let record = batches[id] else { throw CredentialMigrationFailure.unknownSession }

		try await writer.undo(record)
		batches[id] = nil
	}

	internal func discard(_ id: UUID) {
		sessions[id] = nil
	}

	internal func discardAll() {
		sessions = [:]
	}
}
