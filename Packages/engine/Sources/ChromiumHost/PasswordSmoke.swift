import AppKit
import ChromiumEngine

/// `make password-smoke` (DEV-708). Runs only with the host's validated disposable
/// profile, the mock Keychain and the loopback sign-in fixture. The user's part
/// (typing a password and choosing Save) is played with real keyboard input; the
/// agent's part goes through the sign-in ABI. Every reply and failure is printed
/// so the runner can scan them for the probe password.
@MainActor
internal final class PasswordSmoke {
	internal static let argument: String = "--password-fixture"
	internal let runtime: ChromiumRuntime
	private let base: URL
	private let alternate: URL
	internal let probe: String
	internal let user: String = "arx-fixture-user"
	private var pages: [ChromiumPage] = []
	private var windows: [NSWindow] = []
	private var offers: [ChromiumPasswordSaveOffer] = []
	private var consumedOffers: Int = 0
	private var observation: Task<Void, Never>?
	private let session: URLSession = .init(configuration: .ephemeral)
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL,
		probe: String
	) throws {
		guard
			var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.host == "127.0.0.1",
			probe.count >= 16
		else { throw Failure.invalidFixture }

		components.path = ""
		components.query = nil
		guard let base = components.url else { throw Failure.invalidFixture }

		components.host = "localhost"
		guard let alternate = components.url else { throw Failure.invalidFixture }

		self.runtime = runtime
		self.base = base
		self.alternate = alternate
		self.probe = probe
	}

	internal func open() {
		let stream = runtime.passwordSaveOffers()
		observation = Task { [weak self] in
			for await offer in stream {
				diagnostic("ARX_PASSWORD_SMOKE_OFFER origin=\(offer.origin) username=\(offer.username) update=\(offer.isUpdate)")
				self?.offers.append(offer)
			}
		}
		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_PASSWORD_SMOKE_VERIFIED")
			} catch {
				diagnostic("ARX_PASSWORD_SMOKE_FAILED: \(error)")
			}
			observation?.cancel()
			for page in pages { page.close() }
			for window in windows { window.orderOut(nil) }
			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsPasswords else { throw Failure.unsupported }

		// The user signs in by hand and saves the password to profile A.
		let page = try await makePage(profile: nil)
		try await load(page, "password/login", title: "Arx password login")
		let before = try await state()
		try await typeAndSubmit(page, username: user, password: probe)
		try await waitTitle(page, "Arx password home")
		let offer = try await nextOffer()
		guard
			offer.page == page.identifier,
			offer.origin == base.absoluteString.trimmingSuffix("/"),
			offer.username == user,
			!offer.isUpdate
		else { throw Failure.unexpected("offer") }

		guard runtime.answerPasswordSave(page, token: offer.token, answer: .save)
		else { throw Failure.unexpected("answer") }
		guard !runtime.answerPasswordSave(page, token: offer.token, answer: .save)
		else { throw Failure.unexpected("answered twice") }

		guard try await state().successes == before.successes + 1
		else { throw Failure.unexpected("manual sign-in") }

		// An agent signs in with it, never seeing it.
		try await load(page, "password/login", title: "Arx password login")
		let listed = try await credentials(page, until: { $0.credentials.count == 1 })
		guard listed.credentials[0].username == user, listed.credentials[0].hasForm
		else { throw Failure.unexpected("listing") }

		let signedIn = try await signIn(page, listed, credential: listed.credentials[0].id)
		guard
			signedIn.outcome == .signedIn,
			signedIn.reason == "signedIn",
			signedIn.filled,
			!signedIn.passwordVisible
		else { throw Failure.unexpected("sign-in \(signedIn)") }

		try await waitTitle(page, "Arx password home")
		guard try await state().successes == before.successes + 2
		else { throw Failure.unexpected("server sign-in") }
		guard offers.count == consumedOffers
		else { throw Failure.unexpected("offer after agent sign-in") }
		diagnostic("ARX_PASSWORD_SMOKE_SAVE_FILL")

		// The user fills it from Arx's own suggestions (DEV-875). Its sign-ins count on the
		// server too, so later counts start after them.
		let beforeUserFill = try await state().successes
		try await verifyUserFill(page)
		let userFillSuccesses = try await state().successes - beforeUserFill

		// A second step goes to the user.
		try await load(page, "password/login?next=code", title: "Arx password login")
		let coded = try await credentials(page, until: { $0.credentials.count == 1 })
		let code = try await signIn(page, coded, credential: coded.credentials[0].id)
		guard code.outcome == .needsUser, code.reason == "twoFactor"
		else { throw Failure.unexpected("code \(code)") }
		diagnostic("ARX_PASSWORD_SMOKE_TWO_FACTOR")

		// A same-origin frame bound by its frame ID.
		try await load(page, "password/framed", title: "Arx password framed")
		let frame = try await frameID(page)
		let framedListing = try await credentials(page, until: { $0.credentials.count == 1 })
		let framed = try await signIn(page, framedListing, frame: frame, credential: framedListing.credentials[0].id)
		guard framed.outcome == .signedIn, framed.filled
		else { throw Failure.unexpected("framed \(framed)") }
		guard try await state().successes == before.successes + userFillSuccesses + 4
		else { throw Failure.unexpected("framed server") }
		diagnostic("ARX_PASSWORD_SMOKE_FRAME")

		// The bound frame navigates before the attempt: stale, nothing filled.
		try await load(page, "password/framed", title: "Arx password framed")
		let swappedFrame = try await frameID(page)
		let frameListing = try await credentials(page, until: { $0.credentials.count == 1 })
		_ = try await runtime.evaluateScript(page, source: "document.querySelector('iframe').src = '/password/other'; return true;")
		try await Task.sleep(for: .milliseconds(800))
		try await expectStale(page, frameListing, frame: swappedFrame, credential: frameListing.credentials[0].id)
		diagnostic("ARX_PASSWORD_SMOKE_FRAME_SWAP")

		// The listed document navigates, or the origin changes: stale.
		try await load(page, "password/login", title: "Arx password login")
		let oldDocument = try await credentials(page, until: { $0.credentials.count == 1 })
		try await load(page, "password/login", title: "Arx password login")
		try await expectStale(page, oldDocument, credential: oldDocument.credentials[0].id)
		let sameOrigin = try await credentials(page, until: { $0.credentials.count == 1 })
		try await load(page, "password/login", title: "Arx password login", base: alternate)
		try await expectStale(page, sameOrigin, credential: sameOrigin.credentials[0].id)
		let otherOrigin = try await credentials(page, until: { _ in true })
		guard otherOrigin.credentials.isEmpty, otherOrigin.origin.hasPrefix("http://localhost:")
		else { throw Failure.unexpected("origin isolation") }
		diagnostic("ARX_PASSWORD_SMOKE_ORIGIN_SWAP")

		// Never: the other origin isn't offered again.
		try await typeAndSubmit(page, username: user, password: probe)
		try await waitTitle(page, "Arx password home")
		let never = try await nextOffer()
		guard never.origin.hasPrefix("http://localhost:"), never.username == user
		else { throw Failure.unexpected("never offer") }
		guard runtime.answerPasswordSave(page, token: never.token, answer: .never)
		else { throw Failure.unexpected("never answer") }
		try await load(page, "password/login", title: "Arx password login", base: alternate)
		try await typeAndSubmit(page, username: user, password: probe)
		try await waitTitle(page, "Arx password home")
		try await expectNoOffer()
		try await load(page, "password/login", title: "Arx password login", base: alternate)
		guard try await credentials(page, until: { _ in true }).credentials.isEmpty
		else { throw Failure.unexpected("never saved") }
		diagnostic("ARX_PASSWORD_SMOKE_NEVER")

		// Profile B sees none of profile A's passwords.
		let profileB = UUID()
		let other = try await makePage(profile: profileB)
		try await load(other, "password/login", title: "Arx password login")
		let isolated = try await credentials(other, until: { _ in true })
		guard isolated.credentials.isEmpty else { throw Failure.unexpected("profile isolation") }
		diagnostic("ARX_PASSWORD_SMOKE_PROFILE_ISOLATION")

		// A private page gets nothing, and saves nothing.
		let privateID = UUID()
		try runtime.preparePrivateProfile(privateID)
		let privatePage = try await makePage(profile: privateID)
		guard privatePage.isPrivate else { throw Failure.unexpected("not private") }
		try await load(privatePage, "password/login", title: "Arx password login")
		do {
			let listing = try await runtime.signInCredentials(privatePage)
			reply("private", "\(listing)")
			throw Failure.unexpected("private listing")
		} catch let failure as ChromiumSignInFailure {
			reply("private", "\(failure)")
			guard failure == .unavailable else { throw Failure.unexpected("private \(failure)") }
		}
		diagnostic("ARX_PASSWORD_SMOKE_PRIVATE")

		// The site changed the password: the saved one is refused, and the page
		// still shows a filled password field (the app quarantines it).
		_ = try await post("password/rotate")
		try await load(page, "password/login", title: "Arx password login")
		let stale = try await credentials(page, until: { $0.credentials.count == 1 })
		let refused = try await signIn(page, stale, credential: stale.credentials[0].id)
		guard
			refused.outcome == .failed,
			refused.reason == "rejected",
			refused.filled,
			refused.passwordVisible
		else { throw Failure.unexpected("refused \(refused)") }
		diagnostic("ARX_PASSWORD_SMOKE_REJECTED")

		try await verifySettings(
			page: page,
			other: other,
			profileB: profileB,
			privateID: privateID
		)
		try await verifyCredentialImport(privateID: privateID)
	}

	// MARK: - Settings (DEV-721)

	/// Settings' list, edit, add, remove and CSV import over the ABI36 bridge.
	/// Each password goes in through a lent AppKit field or a CSV file outside
	/// the profile, and every edit and import is proven by signing in.
	private func verifySettings(
		page: ChromiumPage,
		other: ChromiumPage,
		profileB: UUID,
		privateID: UUID
	) async throws {
		guard runtime.supportsSavedPasswords else { throw Failure.unsupported }

		// Profile A lists the fixture account and the "never saved" localhost.
		var list = try await settingsList(nil)
		guard
			list.passwords.count == 1,
			list.passwords[0].username == user,
			list.passwords[0].site == "127.0.0.1",
			list.blocked.map(\.site) == ["localhost"]
		else { throw Failure.unexpected("settings list") }
		diagnostic("ARX_PASSWORD_SMOKE_SETTINGS_LIST")

		// Edit: the site's new password goes in through a lent field, and the
		// agent then signs in with it.
		_ = try await post("password/rotate?to=edited")
		let field = NSSecureTextField()
		field.stringValue = probe + "edited"
		let fixtureID = list.passwords[0].id
		let fixtureListing = list.listing
		list = try await settings("edit") {
			try await self.runtime.savePassword(
				profile: nil,
				listing: fixtureListing,
				credential: fixtureID,
				url: nil,
				username: self.user,
				passwordField: field
			)
		}
		guard field.stringValue.isEmpty, list.passwords.count == 1
		else { throw Failure.unexpected("edit") }

		let before = try await state()
		try await load(page, "password/login", title: "Arx password login")
		let edited = try await credentials(page, until: { $0.credentials.count == 1 })
		let editedSignIn = try await signIn(page, edited, credential: edited.credentials[0].id)
		try await waitTitle(page, "Arx password home")
		guard editedSignIn.outcome == .signedIn, try await state().successes == before.successes + 1
		else { throw Failure.unexpected("edited sign-in \(editedSignIn)") }
		diagnostic("ARX_PASSWORD_SMOKE_SETTINGS_EDIT")

		// Add, refuse a second password for the same site and username, then
		// rename it keeping the password (no field).
		field.stringValue = probe + "added"
		list = try await settings("add") {
			try await self.runtime.savePassword(
				profile: nil,
				listing: nil,
				credential: 0,
				url: "https://add.arx.test/login",
				username: "added",
				passwordField: field
			)
		}
		guard
			field.stringValue.isEmpty,
			list.passwords.contains(where: { $0.site == "add.arx.test" && $0.username == "added" })
		else { throw Failure.unexpected("add") }

		field.stringValue = probe + "again"
		try await expectSettingsFailure(.exists, "duplicate") {
			_ = try await self.runtime.savePassword(
				profile: nil,
				listing: nil,
				credential: 0,
				url: "https://add.arx.test",
				username: "added",
				passwordField: field
			)
		}
		guard let added = list.passwords.first(where: { $0.site == "add.arx.test" })
		else { throw Failure.unexpected("added") }

		let addedListing = list.listing
		list = try await settings("rename") {
			try await self.runtime.savePassword(
				profile: nil,
				listing: addedListing,
				credential: added.id,
				url: nil,
				username: "renamed",
				passwordField: nil
			)
		}
		guard list.passwords.map(\.username).sorted() == [user, "renamed"].sorted()
		else { throw Failure.unexpected("rename") }
		diagnostic("ARX_PASSWORD_SMOKE_SETTINGS_ADD")

		// Remove the added password and the "never saved" site. An older listing is stale.
		let older = list
		guard let renamed = list.passwords.first(where: { $0.username == "renamed" })
		else { throw Failure.unexpected("renamed") }

		list = try await settings("remove") {
			try await self.runtime.removeSavedPassword(
				profile: nil,
				listing: older.listing,
				credential: renamed.id
			)
		}
		try await expectSettingsFailure(.stale, "stale remove") {
			_ = try await self.runtime.removeSavedPassword(
				profile: nil,
				listing: older.listing,
				credential: older.passwords[0].id
			)
		}
		guard let blocked = list.blocked.first
		else { throw Failure.unexpected("blocked") }

		let blockedListing = list.listing
		list = try await settings("allow") {
			try await self.runtime.removeSavedPassword(
				profile: nil,
				listing: blockedListing,
				credential: blocked.id
			)
		}
		guard list.passwords.map(\.username) == [user], list.blocked.isEmpty
		else { throw Failure.unexpected("removed") }
		diagnostic("ARX_PASSWORD_SMOKE_SETTINGS_REMOVE")

		// A reveal checks the listing before it asks the device owner, so these
		// never show a prompt.
		try await expectSettingsFailure(.stale, "stale reveal") {
			try await self.runtime.revealSavedPassword(
				profile: nil,
				listing: older.listing,
				credential: older.passwords[0].id,
				reason: "verify Arx's password smoke",
				mode: .copy
			)
		}
		let currentListing = list.listing
		try await expectSettingsFailure(.notFound, "missing reveal") {
			try await self.runtime.revealSavedPassword(
				profile: nil,
				listing: currentListing,
				credential: 9_999,
				reason: "verify Arx's password smoke",
				mode: .show(NSTextField())
			)
		}
		diagnostic("ARX_PASSWORD_SMOKE_SETTINGS_REVEAL_GATE")

		let directory = FileManager.default.temporaryDirectory
			.appending(path: "arx-password-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { cleanUp("password folder") { try FileManager.default.removeItem(at: directory) } }
		let site = base.appending(path: "password/login").absoluteString

		// Chrome's export into profile B: the fixture account (proven by an
		// agent sign-in there), another site and a row without a password.
		let chrome = try write(directory, "chrome.csv", [
			"name,url,username,password,note",
			"Fixture,\(site),\(user),\(probe)edited,\(probe)note",
			"Chrome,https://chrome.arx.test/,c-user,\(probe)chrome,",
			"Broken,https://broken.arx.test/,b-user,,",
		])
		let chromeImport = try await importCSV(profileB, chrome)
		guard
			chromeImport.imported == 2,
			chromeImport.conflictCount == 0,
			chromeImport.skippedCount == 1,
			chromeImport.skipped.first?.reason == "missingPassword"
		else { throw Failure.unexpected("chrome import \(chromeImport)") }
		guard try await settingsList(profileB).passwords.count == 2
		else { throw Failure.unexpected("chrome list") }

		let beforeB = try await state()
		try await load(other, "password/login", title: "Arx password login")
		let imported = try await credentials(other, until: { $0.credentials.count == 1 })
		let importedSignIn = try await signIn(other, imported, credential: imported.credentials[0].id)
		try await waitTitle(other, "Arx password home")
		guard importedSignIn.outcome == .signedIn, try await state().successes == beforeB.successes + 1
		else { throw Failure.unexpected("imported sign-in \(importedSignIn)") }
		diagnostic("ARX_PASSWORD_SMOKE_CSV_CHROME")

		// Apple Passwords' export into a third profile, with a TOTP secret that
		// is never imported. The same file with changed passwords conflicts, and
		// the saved passwords are kept.
		let profileC = UUID()
		try await runtime.prepareProfile(profileC)
		let apple = try write(directory, "apple.csv", [
			"Title,URL,Username,Password,Notes,OTPAuth",
			"Apple,https://apple.arx.test/,a-user,\(probe)apple,,otpauth://totp/Arx:a-user?secret=\(probe)totp&issuer=Arx",
			"Fixture,\(site),\(user),\(probe)edited,,",
		])
		let appleImport = try await importCSV(profileC, apple)
		guard appleImport.imported == 2, appleImport.conflictCount == 0, appleImport.skippedCount == 0
		else { throw Failure.unexpected("apple import \(appleImport)") }

		let changed = try write(directory, "apple-changed.csv", [
			"Title,URL,Username,Password,Notes,OTPAuth",
			"Apple,https://apple.arx.test/,a-user,\(probe)changed,,",
			"Fixture,\(site),\(user),\(probe)changed,,",
		])
		let conflicting = try await importCSV(profileC, changed)
		guard
			conflicting.imported == 0,
			conflicting.conflictCount == 2,
			Set(conflicting.conflicts.map(\.username)) == ["a-user", user],
			Set(conflicting.conflicts.map(\.site)) == ["apple.arx.test", "127.0.0.1"]
		else { throw Failure.unexpected("apple conflicts \(conflicting)") }
		guard try await settingsList(profileC).passwords.count == 2
		else { throw Failure.unexpected("apple list") }
		diagnostic("ARX_PASSWORD_SMOKE_CSV_APPLE")

		let notes = try write(directory, "notes.csv", ["title,body", "Shopping,milk"])
		try await expectSettingsFailure(.invalid(reason: "format"), "format") {
			_ = try await self.importCSV(profileC, notes)
		}
		diagnostic("ARX_PASSWORD_SMOKE_CSV_FORMAT")

		// Each profile lists only its own; a private profile has no list.
		let siteA = try await settingsList(nil).passwords.map(\.site)
		let siteB = try await settingsList(profileB).passwords.map(\.site).sorted()
		let siteC = try await settingsList(profileC).passwords.map(\.site).sorted()
		guard
			siteA == ["127.0.0.1"],
			siteB == ["127.0.0.1", "chrome.arx.test"],
			siteC == ["127.0.0.1", "apple.arx.test"]
		else { throw Failure.unexpected("settings isolation") }
		try await expectSettingsFailure(.unavailable, "private list") {
			_ = try await self.runtime.savedPasswordList(profile: privateID)
		}
		diagnostic("ARX_PASSWORD_SMOKE_SETTINGS_ISOLATION")
	}

	internal func settingsList(_ profile: UUID?) async throws -> ChromiumSavedPasswordList {
		try await settings("list") { try await self.runtime.savedPasswordList(profile: profile) }
	}

	private func settings(
		_ kind: String,
		_ body: () async throws -> ChromiumSavedPasswordList
	) async throws -> ChromiumSavedPasswordList {
		do {
			let list = try await body()
			reply("settings \(kind)", "\(list)")
			return list
		} catch {
			reply("settings \(kind)", "\(error)")
			throw error
		}
	}

	private func expectSettingsFailure(
		_ expected: ChromiumSavedPasswordFailure,
		_ label: String,
		_ body: () async throws -> Void
	) async throws {
		do {
			try await body()
		} catch let failure as ChromiumSavedPasswordFailure {
			reply("settings \(label)", "\(failure)")
			guard failure == expected else { throw Failure.unexpected("\(label) \(failure)") }
			return
		}
		throw Failure.unexpected("\(label) succeeded")
	}

	private func importCSV(
		_ profile: UUID?,
		_ file: URL
	) async throws -> ChromiumPasswordImport {
		do {
			let summary = try await runtime.importPasswords(profile: profile, file: file)
			reply("import", "\(summary)")
			return summary
		} catch {
			reply("import", "\(error)")
			throw error
		}
	}

	/// A CSV outside the disposable profile, deleted once the checks end.
	private func write(
		_ directory: URL,
		_ name: String,
		_ lines: [String]
	) throws -> URL {
		let file = directory.appending(path: name)
		try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
		return file
	}

	// MARK: - Agent side

	private func credentials(
		_ page: ChromiumPage,
		until accept: (ChromiumSignInCredentials) -> Bool
	) async throws -> ChromiumSignInCredentials {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while true {
			do {
				let listing = try await runtime.signInCredentials(page)
				reply("credentials", "\(listing)")
				if accept(listing) { return listing }
			} catch {
				reply("credentials", "\(error)")
				throw error
			}
			guard ContinuousClock.now < deadline else { throw Failure.timedOut("credentials") }
			try await Task.sleep(for: .milliseconds(200))
		}
	}

	private func signIn(
		_ page: ChromiumPage,
		_ listing: ChromiumSignInCredentials,
		frame: String? = nil,
		credential: UInt32
	) async throws -> ChromiumSignInResult {
		do {
			let result = try await runtime.signIn(
				page,
				document: listing.document,
				frame: frame,
				credential: credential,
				timeoutMilliseconds: 20_000
			)
			reply("signIn", "\(result)")
			return result
		} catch {
			reply("signIn", "\(error)")
			throw error
		}
	}

	private func expectStale(
		_ page: ChromiumPage,
		_ listing: ChromiumSignInCredentials,
		frame: String? = nil,
		credential: UInt32
	) async throws {
		do {
			let result = try await signIn(page, listing, frame: frame, credential: credential)
			throw Failure.unexpected("not stale \(result)")
		} catch let failure as ChromiumSignInFailure {
			guard failure == .staleDocument(filled: false)
			else { throw Failure.unexpected("stale \(failure)") }
		}
	}

	internal func reply(_ kind: String, _ value: String) {
		diagnostic("ARX_PASSWORD_SMOKE_REPLY \(kind) \(value)")
	}

	// MARK: - User side

	/// Real mouse and key events, as a person would type: inspection and the
	/// agent tools refuse password fields by design.
	private func typeAndSubmit(
		_ page: ChromiumPage,
		username: String,
		password: String
	) async throws {
		try await click(page, selector: "input[name=username]")
		try type(page, username)
		try await click(page, selector: "input[name=password]")
		try type(page, password)
		try key(page, characters: "\r", keyCode: 36)
	}

	internal func click(
		_ page: ChromiumPage,
		selector: String
	) async throws {
		try await click(page, at: try await center(of: selector, in: page))
	}

	/// The element's center in page coordinates, read with a developer-world script, which
	/// ordinary pages allow and private pages refuse.
	internal func center(
		of selector: String,
		in page: ChromiumPage
	) async throws -> Point {
		let source = """
		const r = document.querySelector('\(selector)').getBoundingClientRect();
		return {x: r.left + r.width / 2, y: r.top + r.height / 2};
		"""
		guard case let .json(text) = try await runtime.evaluateScript(page, source: source)
		else { throw Failure.unexpected("no \(selector)") }

		do {
			return try JSONDecoder().decode(Point.self, from: Data(text.utf8))
		} catch {
			throw Failure.unexpected("no \(selector): \(error)")
		}
	}

	internal func click(
		_ page: ChromiumPage,
		at point: Point
	) async throws {
		guard let window = page.view.window
		else { throw Failure.unexpected("no window") }

		window.makeKeyAndOrderFront(nil)
		let local = NSPoint(x: point.x, y: page.view.isFlipped ? point.y : page.view.bounds.height - point.y)
		let location = page.view.convert(local, to: nil)
		for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
			guard let event = NSEvent.mouseEvent(
				with: type,
				location: location,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				eventNumber: 0,
				clickCount: 1,
				pressure: 1
			)
			else { throw Failure.unexpected("mouse event") }
			window.sendEvent(event)
		}
		try await Task.sleep(for: .milliseconds(200))
	}

	internal func type(
		_ page: ChromiumPage,
		_ text: String
	) throws {
		for character in text {
			try key(page, characters: String(character), keyCode: 0)
		}
	}

	internal func key(
		_ page: ChromiumPage,
		characters: String,
		keyCode: UInt16
	) throws {
		guard let window = page.view.window else { throw Failure.unexpected("no window") }
		for type in [NSEvent.EventType.keyDown, .keyUp] {
			guard let event = NSEvent.keyEvent(
				with: type,
				location: .zero,
				modifierFlags: [],
				timestamp: ProcessInfo.processInfo.systemUptime,
				windowNumber: window.windowNumber,
				context: nil,
				characters: characters,
				charactersIgnoringModifiers: characters,
				isARepeat: false,
				keyCode: keyCode
			)
			else { throw Failure.unexpected("key event") }
			window.sendEvent(event)
		}
	}

	internal struct Point: Decodable {
		internal var x: Double
		internal var y: Double
	}

	private func nextOffer() async throws -> ChromiumPasswordSaveOffer {
		try await wait("offer", seconds: 10) { self.offers.count > self.consumedOffers }
		consumedOffers += 1
		return offers[consumedOffers - 1]
	}

	private func expectNoOffer() async throws {
		try await Task.sleep(for: .seconds(3))
		guard offers.count == consumedOffers else { throw Failure.unexpected("unexpected offer") }
	}

	// MARK: - Pages

	internal func makePage(profile: UUID?) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profile)
		pages.append(page)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 760, height: 520),
			styleMask: [.titled],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)
		windows.append(window)
		return page
	}

	internal func load(
		_ page: ChromiumPage,
		_ path: String,
		title: String,
		base: URL? = nil
	) async throws {
		guard let url = URL(string: path, relativeTo: (base ?? self.base).appending(path: ""))?.absoluteURL
		else { throw Failure.invalidFixture }

		page.view.window?.makeKeyAndOrderFront(nil)
		try page.navigate(to: url)
		try await waitTitle(page, title)
	}

	internal func waitTitle(
		_ page: ChromiumPage,
		_ title: String
	) async throws {
		try await wait("title \(title)", seconds: 15) {
			page.navigation.title == title && !page.navigation.isLoading
		}

		// Let the password manager parse the new document's forms.
		try await Task.sleep(for: .milliseconds(500))
	}

	private func frameID(_ page: ChromiumPage) async throws -> String {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while ContinuousClock.now < deadline {
			let snapshot = try await runtime.inspect(page, scope: UUID())
			if let frame = snapshot.nodes.compactMap(\.frame).first { return frame }
			try await Task.sleep(for: .milliseconds(200))
		}
		throw Failure.timedOut("frame")
	}

	// MARK: - Fixture

	internal struct ServerState: Decodable {
		internal var successes: Int
		internal var failures: Int
	}

	internal func state() async throws -> ServerState {
		let (data, _) = try await session.data(from: base.appending(path: "password/state"))
		return try JSONDecoder().decode(ServerState.self, from: data)
	}

	private func post(_ path: String) async throws -> Data {
		// A relative URL keeps a query, which `appending(path:)` would escape.
		guard let url = URL(string: path, relativeTo: base.appending(path: ""))?.absoluteURL
		else { throw Failure.invalidFixture }

		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		return try await session.data(for: request).0
	}

	internal func wait(
		_ label: String,
		seconds: Int,
		_ condition: () -> Bool
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
		while !condition() {
			guard ContinuousClock.now < deadline else { throw Failure.timedOut(label) }
			try await Task.sleep(for: .milliseconds(50))
		}
	}

	internal enum Failure: Error {
		case invalidFixture
		case unsupported
		case timedOut(String)
		case unexpected(String)
	}
}

extension String {
	fileprivate func trimmingSuffix(_ suffix: String) -> String {
		hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
