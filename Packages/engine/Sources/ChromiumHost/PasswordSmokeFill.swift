import AppKit
import ChromiumEngine

/// `make password-smoke`, the user's fill (DEV-875): Arx's own suggestions for a focused
/// sign-in field, a fill the device owner must approve refused, a fill without asking
/// proven by signing in, the keyboard path, Escape, and nothing for a private page.
/// Suggestions carry only the account; the runner scans every line for the probe.
extension PasswordSmoke {
	internal func verifyUserFill(_ page: ChromiumPage) async throws {
		guard runtime.supportsAutofill else { throw Failure.unsupported }

		let recorder = AutofillRecorder()
		let stream = runtime.autofillEvents()
		let observation = Task { @MainActor in
			for await event in stream {
				reply("autofill", "\(event)")
				recorder.events.append(event)
			}
		}
		defer { observation.cancel() }

		// Refused: the device owner would be asked, and nobody can answer here.
		runtime.setAutofillAuthentication(
			.refuse,
			passwordReason: "fill a saved password",
			cardReason: "fill a payment card"
		)
		try await load(page, "password/login", title: "Arx password login")
		var shown = try await suggestions(page, recorder, focusing: "input[name=username]")
		let account = try account(in: shown)
		guard runtime.acceptAutofillSuggestion(page, session: shown.session, index: account.index)
		else { throw Failure.unexpected("refused accept") }
		try await hidden(page, recorder, session: shown.session)
		try await Task.sleep(for: .milliseconds(500))
		guard try await fieldValue(page, "input[name=username]").isEmpty
		else { throw Failure.unexpected("refused fill filled") }
		diagnostic("ARX_PASSWORD_SMOKE_FILL_REFUSED")

		// Without asking: choosing the account fills both fields, and the site takes them.
		runtime.setAutofillAuthentication(
			.fillPasswordsWithoutAsking,
			passwordReason: "fill a saved password",
			cardReason: "fill a payment card"
		)
		let before = try await state()
		shown = try await suggestions(page, recorder, focusing: "input[name=username]")
		guard !runtime.acceptAutofillSuggestion(page, session: shown.session &+ 1, index: account.index)
		else { throw Failure.unexpected("stale session accepted") }
		guard runtime.acceptAutofillSuggestion(page, session: shown.session, index: try self.account(in: shown).index)
		else { throw Failure.unexpected("accept") }
		try await waitValue(page, "input[name=username]", user)
		try key(page, characters: "\r", keyCode: 36)
		try await waitTitle(page, "Arx password home")
		guard try await state().successes == before.successes + 1
		else { throw Failure.unexpected("fill sign-in") }
		diagnostic("ARX_PASSWORD_SMOKE_FILL_SIGNED_IN")

		// The keyboard: Down chooses the account natively, Return fills it.
		try await load(page, "password/login", title: "Arx password login")
		shown = try await suggestions(page, recorder, focusing: "input[name=username]")
		try key(page, characters: String(Character(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)), keyCode: 125)
		try await wait("selection", seconds: 5) {
			recorder.latest(page.identifier).flatMap { event -> UInt32? in
				guard case let .shown(current) = event, current.session == shown.session else { return nil }
				return current.selected
			} != nil
		}
		try key(page, characters: "\r", keyCode: 36)
		try await waitValue(page, "input[name=username]", user)
		try key(page, characters: "\r", keyCode: 36)
		try await waitTitle(page, "Arx password home")
		guard try await state().successes == before.successes + 2
		else { throw Failure.unexpected("keyboard fill sign-in") }
		diagnostic("ARX_PASSWORD_SMOKE_FILL_KEYBOARD")

		// Escape closes them and fills nothing.
		try await load(page, "password/login", title: "Arx password login")
		shown = try await suggestions(page, recorder, focusing: "input[name=username]")
		try key(page, characters: "\u{1b}", keyCode: 53)
		try await hidden(page, recorder, session: shown.session)
		guard try await fieldValue(page, "input[name=username]").isEmpty
		else { throw Failure.unexpected("escape filled") }
		diagnostic("ARX_PASSWORD_SMOKE_FILL_ESCAPE")

		// A private page is offered nothing. Private pages refuse the script that finds a
		// field, so the click goes where the same form's field is on the ordinary page.
		let field = try await center(of: "input[name=username]", in: page)
		let privateID = UUID()
		try runtime.preparePrivateProfile(privateID)
		let privatePage = try await makePage(profile: privateID)
		try await load(privatePage, "password/login", title: "Arx password login")
		let seen = recorder.events.count
		try await click(privatePage, at: field)
		try await Task.sleep(for: .seconds(2))
		guard !recorder.events.dropFirst(seen).contains(where: { $0.page == privatePage.identifier })
		else { throw Failure.unexpected("private suggestions") }
		privatePage.close()
		runtime.releasePrivateProfile(privateID)
		diagnostic("ARX_PASSWORD_SMOKE_FILL_PRIVATE")

		// Later steps sign in through agents only; nothing fills on its own.
		runtime.setAutofillAuthentication(
			.refuse,
			passwordReason: "fill a saved password",
			cardReason: "fill a payment card"
		)
		try await load(page, "password/home", title: "Arx password home")
	}

	private func suggestions(
		_ page: ChromiumPage,
		_ recorder: AutofillRecorder,
		focusing selector: String
	) async throws -> ChromiumAutofillSuggestions {
		let seen = recorder.events.count
		try await click(page, selector: selector)
		var shown: ChromiumAutofillSuggestions?
		try await wait("suggestions", seconds: 10) {
			for event in recorder.events.dropFirst(seen) {
				if case let .shown(suggestions) = event, suggestions.page == page.identifier { shown = suggestions }
			}
			return shown != nil
		}
		guard let shown else { throw Failure.unexpected("suggestions") }

		// Native ignores a choice in the list's first half second.
		try await Task.sleep(for: .milliseconds(700))
		for item in shown.items {
			guard !item.title.contains(probe), !(item.subtitle ?? "").contains(probe)
			else { throw Failure.unexpected("suggestion carries a password") }
		}
		return shown
	}

	private func account(in shown: ChromiumAutofillSuggestions) throws -> ChromiumAutofillItem {
		guard
			shown.product == .password,
			let account = shown.items.first(where: { $0.kind == .password && $0.title == user })
		else { throw Failure.unexpected("no account suggestion") }
		return account
	}

	private func hidden(
		_ page: ChromiumPage,
		_ recorder: AutofillRecorder,
		session: UInt64
	) async throws {
		try await wait("hidden", seconds: 10) {
			recorder.events.contains(.hidden(page: page.identifier, session: session, open: nil))
		}
	}

	/// A text field's value, read in Arx's developer world (which never reads a password).
	private func fieldValue(
		_ page: ChromiumPage,
		_ selector: String
	) async throws -> String {
		guard
			case let .json(text) = try await runtime.evaluateScript(
				page,
				source: "return document.querySelector('\(selector)').value;"
			)
		else { throw Failure.unexpected("value of \(selector)") }

		do {
			return try JSONDecoder().decode(String.self, from: Data(text.utf8))
		} catch {
			throw Failure.unexpected("value of \(selector): \(error)")
		}
	}

	private func waitValue(
		_ page: ChromiumPage,
		_ selector: String,
		_ expected: String
	) async throws {
		let deadline = ContinuousClock.now.advanced(by: .seconds(10))
		while try await fieldValue(page, selector) != expected {
			guard ContinuousClock.now < deadline else { throw Failure.timedOut("value of \(selector)") }
			try await Task.sleep(for: .milliseconds(100))
		}
	}
}

@MainActor
private final class AutofillRecorder {
	internal var events: [ChromiumAutofillEvent] = []

	internal func latest(_ page: UInt64) -> ChromiumAutofillEvent? {
		events.last(where: { $0.page == page })
	}
}

private func diagnostic(_ message: String) {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
}
