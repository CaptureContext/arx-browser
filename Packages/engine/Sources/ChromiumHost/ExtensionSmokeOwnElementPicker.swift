import ChromiumEngine
import Foundation

/// Arx's own element picker (DEV-1201) on a page whose content security policy allows no
/// scripts or styles: its outline mounts, a pick saves `site##selector` to My filters, the site
/// menu's list has it, and the element is still hidden after a reload, by uBlock now.
///
/// The smoke can't move a pointer, so it picks through the picker's own testing hook in the
/// translation world, the same pick a click makes.
@MainActor
internal enum ExtensionSmokeOwnElementPicker {
	internal static func run(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		url: URL,
		phase: (String) -> Void
	) async throws {
		phase("own-element-picker")
		guard
			runtime.supportsElementPicker,
			runtime.supportsDeveloperTier
		else { throw Failure.unsupported }

		let fixture = url.deletingLastPathComponent().appending(path: "picker.html")
		try page.navigate(to: fixture)
		try await waitForLoad(page, path: fixture.path())

		guard
			let site = ChromiumElementPicker.site(of: fixture),
			let expected = ChromiumElementPicker.filter(site: site, selector: "aside.arx-pick-target")
		else { throw Failure.navigation }

		let style = ChromiumElementPicker.Style(
			accent: .init(red: 0.04, green: 0.52, blue: 1),
			onAccent: .init(red: 1, green: 1, blue: 1),
			reduceMotion: true
		)
		let session = Task { await runtime.pickElement(on: page, style: style) }

		phase("own-element-picker-overlay")
		try await waitFor(runtime: runtime, page: page, script: "return document.querySelector('arx-element-picker') !== null;")

		phase("own-element-picker-pick")
		try await pick(runtime: runtime, page: page)

		let outcome = await session.value
		guard outcome == .hidden(filter: expected)
		else { throw Failure.outcome(String(describing: outcome), expected: expected) }

		phase("own-element-picker-listed")
		try await waitForListing(expected, site: site, runtime: runtime, page: page)

		// The picker hid it at once; after a reload only uBlock's filter can.
		phase("own-element-picker-reload")
		for _ in 0..<6 {
			try page.reload()
			try await waitForLoad(page, path: fixture.path())
			if try await isHidden(runtime: runtime, page: page) { return }
		}

		throw Failure.notHiddenAfterReload
	}

	/// Hide Element's mode (DEV-1298) on the same fixture: a pick hides and saves its line while
	/// the picker stays open; Undo shows it again and takes the line out; a second pick stays;
	/// the list names it; Done closes the picker, and after a reload only the second is hidden.
	internal static func runMode(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		url: URL,
		phase: (String) -> Void
	) async throws {
		phase("hide-element-mode")
		let fixture = url.deletingLastPathComponent().appending(path: "picker.html")
		try page.navigate(to: fixture)
		try await waitForLoad(page, path: fixture.path())

		guard
			let site = ChromiumElementPicker.site(of: fixture),
			let undone = ChromiumElementPicker.filter(site: site, selector: "div.arx-mode-undo"),
			let kept = ChromiumElementPicker.filter(site: site, selector: "footer.arx-mode-target")
		else { throw Failure.navigation }

		let events = ModeEvents()
		let style = ChromiumElementPicker.Style(
			accent: .init(red: 0.913725, green: 0.258824, blue: 0.247059),
			onAccent: .init(red: 1, green: 1, blue: 1),
			reduceMotion: true,
			keepsOpen: true
		)
		let session = Task { await runtime.hideElements(on: page, style: style) { events.list.append($0) } }

		phase("hide-element-mode-opened")
		try await events.waitFor { $0 == .opened }
		try await waitFor(runtime: runtime, page: page, script: "return document.querySelector('arx-element-picker') !== null;")

		phase("hide-element-mode-pick")
		try await pick(".arx-mode-undo", runtime: runtime, page: page, expecting: "active")
		try await events.waitFor { if case .hidden(undone, _) = $0 { true } else { false } }
		try await waitForListing(undone, site: site, runtime: runtime, page: page)

		phase("hide-element-mode-undo")
		guard runtime.sendHidingCommand(.unhide(undone), on: page), runtime.showHiddenElement(undone, on: page)
		else { throw Failure.mode("Undo wasn't taken") }
		try await events.waitFor { $0 == .shown(filter: undone, isVisible: true) }
		try await waitForUnlisting(undone, site: site, runtime: runtime, page: page)

		phase("hide-element-mode-second-pick")
		try await pick(".arx-mode-target", runtime: runtime, page: page, expecting: "active")
		try await events.waitFor { if case .hidden(kept, _) = $0 { true } else { false } }
		try await waitFor(runtime: runtime, page: page, script: "return document.querySelector('arx-element-picker') !== null;")

		phase("hide-element-mode-describe")
		guard runtime.sendHidingCommand(.describe([kept]), on: page)
		else { throw Failure.mode("the list's names weren't asked for") }
		try await events.waitFor { event in
			guard case let .described(found) = event else { return false }
			return found[kept]??.label == "Hidden in Hide Element's mode"
		}

		phase("hide-element-mode-done")
		guard runtime.sendHidingCommand(.close, on: page) else { throw Failure.mode("Done wasn't taken") }
		guard await session.value else { throw Failure.mode("the mode never opened") }
		try await waitFor(runtime: runtime, page: page, script: "return document.querySelector('arx-element-picker') === null;")
		try await waitForListing(kept, site: site, runtime: runtime, page: page)

		phase("hide-element-mode-reload")
		for _ in 0..<6 {
			try page.reload()
			try await waitForLoad(page, path: fixture.path())
			let value = try await runtime.evaluateScript(
				page,
				source: """
				const kept = document.querySelector('.arx-mode-target');
				const undone = document.querySelector('.arx-mode-undo');
				return kept !== null && undone !== null && getComputedStyle(kept).display === 'none'
					&& getComputedStyle(undone).display !== 'none';
				""",
				maximumBytes: 1024,
				timeoutMilliseconds: 2000
			)
			if value == .json("true") { return }
		}

		throw Failure.mode("after a reload, only the second pick should be hidden")
	}

	/// What Hide Element's mode told the smoke, in order.
	@MainActor
	private final class ModeEvents {
		var list: [ChromiumElementPicker.HidingEvent] = []

		func waitFor(_ matches: (ChromiumElementPicker.HidingEvent) -> Bool) async throws {
			for _ in 0..<100 {
				if list.contains(where: matches) { return }
				try await Task.sleep(for: .milliseconds(100))
			}
			throw Failure.mode("never heard what it waited for; heard \(list)")
		}
	}

	private static func pick(
		_ selector: String,
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		expecting state: String
	) async throws {
		let data = try JSONSerialization.data(withJSONObject: [selector])
		let literal = String(decoding: data, as: UTF8.self).dropFirst().dropLast()
		let source = """
		const picker = globalThis.__arxElementPicker;
		const target = document.querySelector(\(literal));
		return picker && target ? picker.pickForTesting(target).state : 'missing';
		"""
		for _ in 0..<40 {
			do {
				let value = try await runtime.evaluateTranslationScript(page, source: source)
				guard value == .json("\"\(state)\"")
				else { throw Failure.pick(String(describing: value)) }

				return
			} catch ChromiumDeveloperFailure.busy {
				try await Task.sleep(for: .milliseconds(25))
			}
		}

		throw Failure.pick("the translation world stayed busy")
	}

	private static func waitForUnlisting(
		_ filter: String,
		site: String,
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws {
		for _ in 0..<100 {
			if await runtime.hiddenElements(on: page)?.sites[site]?.contains(filter) != true { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		throw Failure.mode("\(filter) stayed in the hidden elements after Undo")
	}

	/// Picks the fixture's target through the picker's hook; the session's polls may hold the
	/// page's translation world for a moment.
	private static func pick(
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws {
		let source = """
		const picker = globalThis.__arxElementPicker;
		const target = document.querySelector('.arx-pick-target');
		return picker && target ? picker.pickForTesting(target).state : 'missing';
		"""
		for _ in 0..<40 {
			do {
				let value = try await runtime.evaluateTranslationScript(page, source: source)
				guard value == .json("\"picked\"")
				else { throw Failure.pick(String(describing: value)) }

				return
			} catch ChromiumDeveloperFailure.busy {
				try await Task.sleep(for: .milliseconds(25))
			}
		}

		throw Failure.pick("the translation world stayed busy")
	}

	private static func waitForListing(
		_ filter: String,
		site: String,
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws {
		for _ in 0..<100 {
			if await runtime.hiddenElements(on: page)?.sites[site]?.contains(filter) == true { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		throw Failure.notListed(filter)
	}

	private static func isHidden(
		runtime: ChromiumRuntime,
		page: ChromiumPage
	) async throws -> Bool {
		for _ in 0..<20 {
			let value = try await runtime.evaluateScript(
				page,
				source: """
				const target = document.querySelector('.arx-pick-target');
				return target !== null && getComputedStyle(target).display === 'none';
				""",
				maximumBytes: 1024,
				timeoutMilliseconds: 2000
			)
			if value == .json("true") { return true }
			try await Task.sleep(for: .milliseconds(100))
		}
		return false
	}

	private static func waitFor(
		runtime: ChromiumRuntime,
		page: ChromiumPage,
		script: String
	) async throws {
		for _ in 0..<50 {
			let value = try await runtime.evaluateScript(page, source: script, maximumBytes: 1024, timeoutMilliseconds: 2000)
			if value == .json("true") { return }
			try await Task.sleep(for: .milliseconds(100))
		}

		throw Failure.overlay
	}

	private static func waitForLoad(
		_ page: ChromiumPage,
		path: String
	) async throws {
		for _ in 0..<100 {
			try Task.checkCancellation()
			if page.navigation.url?.path() == path, !page.navigation.isLoading { return }
			try await Task.sleep(for: .milliseconds(50))
		}

		throw Failure.navigation
	}

	private enum Failure: Error, CustomStringConvertible {
		case unsupported
		case navigation
		case overlay
		case pick(String)
		case outcome(String, expected: String)
		case notListed(String)
		case notHiddenAfterReload
		case mode(String)

		var description: String {
			switch self {
			case .unsupported: "own element picker: unsupported by this engine"
			case .navigation: "own element picker: the fixture page didn't load"
			case .overlay: "own element picker: its outline never mounted on the page"
			case let .pick(value): "own element picker: the pick didn't happen (\(value))"
			case let .outcome(outcome, expected): "own element picker: ended \(outcome), expected hidden(\(expected))"
			case let .notListed(filter): "own element picker: \(filter) never reached the hidden elements"
			case .notHiddenAfterReload: "own element picker: the element shows again after a reload"
			case let .mode(what): "hide element mode: \(what)"
			}
		}
	}
}
