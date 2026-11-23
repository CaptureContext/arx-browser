import AppKit
import ChromiumEngine

/// Runs only after the host validates fresh owned storage and its loopback server.
@MainActor
internal final class InspectionSmoke {
	internal static let argument: String = "--inspection-fixture"
	private let runtime: ChromiumRuntime
	private let baseURL: URL
	private var pages: [ChromiumPage] = []
	private var windows: [UInt64: NSWindow] = [:]
	private var revisions: [UInt64: Int] = [:]
	private var scopes: [UUID] = []
	private var privateProfiles: [UUID] = []
	private var phase: String = "startup"
	internal private(set) var verified: Bool = false

	internal init(
		runtime: ChromiumRuntime,
		url: URL
	) throws {
		self.runtime = runtime
		self.baseURL = try InspectionSmokeContract.baseURL(url)
	}

	internal func open() {
		NSApplication.shared.setActivationPolicy(.regular)
		NSApplication.shared.activate(ignoringOtherApps: true)

		Task { [self] in
			do {
				try await verify()
				verified = true
				diagnostic("ARX_INSPECTION_SMOKE_VERIFIED")
			} catch {
				// Fixed phases and types only: never print snapshot content or secrets.
				let reason = safeReason(error)
				diagnostic("ARX_INSPECTION_SMOKE_FAILED phase=\(phase) reason=\(reason)")
			}

			for scope in scopes {
				runtime.revokeInspectionScope(scope)
			}
			for page in pages {
				page.close()
			}
			for profile in privateProfiles {
				runtime.releasePrivateProfile(profile)
			}
			for window in windows.values {
				window.orderOut(nil)
				window.close()
			}

			runtime.requestQuit()
		}
	}

	private func verify() async throws {
		guard runtime.supportsInspection
		else { throw Failure.unavailable }

		phase = "semantic-privacy"
		let page = try await makePage()
		try await load(page, path: "inspection/main", title: "Arx inspection ready")
		let scope = newScope()
		let navigation = page.navigation
		let bounds = page.view.bounds
		let responder = page.view.window?.firstResponder
		let snapshot = try await runtime.inspect(page, scope: scope)
		try InspectionSmokeContract.verify(snapshot)
		guard
			page.navigation == navigation,
			page.view.bounds == bounds,
			page.view.window?.firstResponder === responder,
			runtime.inspectionDocumentIsCurrent(snapshot, on: page, scope: scope)
		else { throw Failure.changedPage }

		let reference = try InspectionSmokeContract.reference(
			in: snapshot,
			named: InspectionSmokeContract.buttonName
		)
		try await runtime.validateInspectionReference(reference, in: snapshot, on: page, scope: scope)
		diagnostic("ARX_INSPECTION_SMOKE_SEMANTICS_PRIVACY")

		phase = "limits-scope"
		try await requireFailure(.limitExceeded) { [self] in

			// ABI25 windows never fail on node count; the text budget still fails closed.
			_ = try await runtime.inspect(page, scope: scope, limits: .init(maximumTextBytes: 1))
		}
		let otherScope = newScope()
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: snapshot, on: page, scope: otherScope)
		}
		let otherSnapshot = try await runtime.inspect(page, scope: otherScope)
		let otherPage = try await makePage(profile: UUID())
		try await load(otherPage, path: "inspection/main", title: "Arx inspection ready")
		let otherProfileSnapshot = try await runtime.inspect(otherPage, scope: otherScope)
		guard otherProfileSnapshot.documentID != snapshot.documentID
		else { throw Failure.scopeIsolation }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: snapshot, on: otherPage, scope: scope)
		}
		otherPage.close()

		runtime.revokeInspectionScope(scope)
		guard
			!runtime.inspectionDocumentIsCurrent(snapshot, on: page, scope: scope),
			runtime.inspectionDocumentIsCurrent(otherSnapshot, on: page, scope: otherScope)
		else { throw Failure.scopeIsolation }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: snapshot, on: page, scope: scope)
		}
		runtime.revokeInspectionScope(otherScope)
		diagnostic("ARX_INSPECTION_SMOKE_LIMIT_SCOPE")

		try await verifyWindows(page)
		try await verifyFrames(page)
		try await verifyFormValues(page)
		try await verifyOffscreenAndPDF(page)
		try await verifyPointer(page)
		try await verifyKeyboard(page)
		try await verifyFormState(page)
		try await verifyUpload(page)
		try await verifyPersonUpload(page)
		try await verifyFileDrop(page)
		try await verifyDialogs(page)

		// The mutation phases click the main fixture's own controls.
		try await load(page, path: "inspection/main", title: "Arx inspection ready")
		try await verifyDOMMutations(page)
		try await verifyNavigation(page)
		try await verifyCancellationAndClosure()
		try await verifyPrivateAndUnsupported()
		try await verifyExpiry()
	}

	/// Concatenated windows cover the whole page in order and never mix versions.
	private func verifyWindows(_ page: ChromiumPage) async throws {
		phase = "windows"
		try await load(page, path: "inspection/large", title: "Arx inspection large")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		var nodes: [ChromiumInspectionNode] = []
		var first: ChromiumInspectionSnapshot?
		repeat {
			let window = try await runtime.inspect(
				page,
				scope: scope,
				limits: .init(maximumNodes: 512, windowStart: nodes.count)
			)
			guard
				window.windowStart == nodes.count,
				window.nodes.first?.index == nodes.count,
				first.map({ $0.documentID == window.documentID && $0.domVersion == window.domVersion }) ?? true,
				first.map({ $0.totalNodes == window.totalNodes }) ?? (window.totalNodes > 1_500),
				!window.nodes.isEmpty
			else { throw Failure.window }

			first = first ?? window
			nodes += window.nodes
		} while nodes.count < (first?.totalNodes ?? 0)

		let texts = nodes.compactMap(\.text)
		guard
			nodes.map(\.index) == Array(0..<nodes.count),
			texts.contains("ARX_LARGE_ITEM_0"),
			texts.contains("ARX_LARGE_ITEM_1499")
		else { throw Failure.window }
		diagnostic("ARX_INSPECTION_SMOKE_WINDOWS")
	}

	/// Same-origin and cross-site frames read through their own IDs and references.
	private func verifyFrames(_ page: ChromiumPage) async throws {
		phase = "frames"
		try await load(page, path: "inspection/frames", title: "Arx inspection frames")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		let main = try await runtime.inspect(page, scope: scope)
		let frames = main.nodes.compactMap(\.frame)
		guard
			frames.count == 2,
			!main.nodes.contains(where: { $0.text == "ARX_FRAME_CHILD_TEXT" })
		else { throw Failure.frame }

		for frame in frames {
			let child = try await runtime.inspect(page, scope: scope, frameID: frame)
			guard
				child.frameID == frame,
				child.nodes.contains(where: { $0.text == "ARX_FRAME_CHILD_TEXT" }),
				!child.nodes.contains(where: { $0.text == "ARX_FRAMES_MAIN_TEXT" })
			else { throw Failure.frame }

			let reference = try InspectionSmokeContract.reference(in: child, named: "Arx frame button")
			try await runtime.validateInspectionReference(reference, in: child, on: page, scope: scope)
		}

		// Reading a frame retires only that frame's snapshot.
		guard runtime.inspectionDocumentIsCurrent(main, on: page, scope: scope)
		else { throw Failure.frame }
		try await requireFailure(.unsupportedDocument) { [self] in
			_ = try await runtime.inspect(page, scope: scope, frameID: String(repeating: "a", count: 32))
		}
		diagnostic("ARX_INSPECTION_SMOKE_FRAMES")
	}

	/// Opt-in values reach ordinary controls only; bounds describe laid-out elements.
	private func verifyFormValues(_ page: ChromiumPage) async throws {
		phase = "form-values"
		try await load(page, path: "inspection/values", title: "Arx inspection values")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		let plain = try await runtime.inspect(page, scope: scope)
		guard !plain.nodes.contains(where: { $0.value != nil || $0.checked != nil || $0.bounds != nil })
		else { throw Failure.formValues }

		let snapshot = try await runtime.inspect(
			page,
			scope: scope,
			limits: .init(includesFormValues: true, includesBounds: true)
		)
		let values = snapshot.nodes.compactMap(\.value)
		let everything = values + snapshot.nodes.flatMap { [$0.name, $0.text].compactMap { $0 } }
		let secrets = ["ARX_PASSWORD_SECRET", "ARX_CARD_SECRET", "ARX_HIDDEN_SECRET"]
		guard
			values.contains("ARX_ORDINARY_VALUE"),
			snapshot.nodes.contains(where: { $0.checked == true }),
			!everything.contains(where: { value in secrets.contains { value.contains($0) } }),
			!snapshot.omissions.contains(.formValues),
			snapshot.omissions.contains(.passwordSubtrees),
			let button = snapshot.nodes.first(where: { $0.name == "Arx values button" }),
			let bounds = button.bounds,
			bounds.width > 0,
			bounds.height > 0
		else { throw Failure.formValues }
		diagnostic("ARX_INSPECTION_SMOKE_FORM_VALUES")
	}

	/// ABI27 pointer input. A clean hover keeps its snapshot (DEV-669); a DOM
	/// mutation or a consuming pointer action retires it.
	private func verifyPointer(_ page: ChromiumPage) async throws {
		phase = "pointer-hover"
		guard runtime.supportsReferencePointer else { throw Failure.unavailable }
		try await load(page, path: "inspection/pointer", title: "Arx pointer ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		var snapshot = try await pointerSnapshot(page, scope: scope)
		let hover = try pointerReference("Arx hover target", in: snapshot)
		for _ in 0..<2 {
			try await pointer(.hover(at: nil), reference: hover, snapshot: snapshot, page: page, scope: scope)
			try await runtime.validateInspectionReference(hover, in: snapshot, on: page, scope: scope)
		}
		let mutate = try pointerReference("Arx hover mutation", in: snapshot)
		try await pointer(.hover(at: nil), reference: mutate, snapshot: snapshot, page: page, scope: scope)
		try await wait { page.navigation.title == "Arx pointer hovered" }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(hover, in: snapshot, on: page, scope: scope)
		}
		diagnostic("ARX_INSPECTION_SMOKE_POINTER_HOVER")

		phase = "pointer-click"
		snapshot = try await pointerSnapshot(page, scope: scope)
		let quiet = try pointerReference("Arx hover target", in: snapshot)
		try await pointer(
			.click(at: nil, count: 1, modifiers: []),
			reference: quiet,
			snapshot: snapshot,
			page: page,
			scope: scope
		)

		// A click consumes its snapshot even though this one changed nothing.
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(quiet, in: snapshot, on: page, scope: scope)
		}
		snapshot = try await pointerSnapshot(page, scope: scope)
		try await pointer(
			.click(at: nil, count: 2, modifiers: []),
			reference: try pointerReference("Arx double click", in: snapshot),
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		try await wait { page.navigation.title == "Arx pointer double clicked" }

		snapshot = try await pointerSnapshot(page, scope: scope)
		let covered = try pointerReference("Arx covered button", in: snapshot)
		let obscured = await runtime.performInspectionFormAction(
			.init(
				operationID: UUID(),
				snapshot: snapshot,
				reference: covered,
				action: .pointer(.click(at: nil, count: 1, modifiers: []))
			),
			on: page,
			scope: scope,
			authorize: { true }
		)
		guard
			obscured.disposition == .notDispatched,
			obscured.failure == .obscured,
			page.navigation.title == "Arx pointer double clicked"
		else { throw Failure.pointer }

		snapshot = try await pointerSnapshot(page, scope: scope)
		guard let box = snapshot.nodes.first(where: { $0.name == "Arx covered button" })?.bounds
		else { throw Failure.pointer }
		let centre = ChromiumPointerPoint(x: box.midX, y: box.midY)
		try await pointer(
			.click(at: centre, count: 1, modifiers: []),
			reference: snapshot.snapshotID,
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		try await wait { page.navigation.title == "Arx pointer point clicked trusted" }
		diagnostic("ARX_INSPECTION_SMOKE_POINTER_CLICK")

		phase = "pointer-drag"
		snapshot = try await pointerSnapshot(page, scope: scope)
		guard let slider = snapshot.nodes.first(where: { $0.name == "Arx slider" })?.bounds
		else { throw Failure.pointer }
		try await pointer(
			.drag(
				from: nil,
				to: .point(.init(x: slider.midX + 120, y: slider.midY)),
				steps: 8,
				modifiers: []
			),
			reference: try pointerReference("Arx slider", in: snapshot),
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		try await wait { page.navigation.title == "Arx pointer slid far" }

		snapshot = try await pointerSnapshot(page, scope: scope)
		try await pointer(
			.drag(
				from: nil,
				to: .reference(try pointerReference("Arx drop zone", in: snapshot)),
				steps: 8,
				modifiers: []
			),
			reference: try pointerReference("Arx drag source", in: snapshot),
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		try await wait { page.navigation.title == "Arx pointer dropped ARX_DRAG_DATA" }
		diagnostic("ARX_INSPECTION_SMOKE_POINTER_DRAG")
	}

	/// ABI28 typing and key chords. Values come from opt-in form values; other
	/// effects from the page's own log paragraph.
	private func verifyKeyboard(_ page: ChromiumPage) async throws {
		phase = "keyboard-type"
		try await load(page, path: "inspection/keyboard", title: "Arx keyboard ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		try await keyboard(.typeText("cd🙂"), on: "Arx type field", page: page, scope: scope)
		try await keyboard(.typeText("one\ntwo"), on: "Arx type area", page: page, scope: scope)
		try await keyboard(.typeText("hi there"), on: "Arx type editor", page: page, scope: scope)
		var snapshot = try await keyboardSnapshot(page, scope: scope)
		guard
			snapshot.nodes.first(where: { $0.name == "Arx type field" })?.value == "ABcd🙂",
			snapshot.nodes.first(where: { $0.name == "Arx type area" })?.value == "one\ntwo",
			keyboardLog(snapshot).contains("ARX_EDITOR_hi_there")
		else { throw Failure.keyboard }

		// A single-line input refuses a line feed before any event.
		let refused = await runtime.performInspectionFormAction(
			.init(
				operationID: UUID(),
				snapshot: snapshot,
				reference: try pointerReference("Arx type field", in: snapshot),
				action: .typeText("a\nb")
			),
			on: page,
			scope: scope,
			authorize: { true }
		)
		guard refused.disposition == .notDispatched, refused.failure == .invalidValue
		else { throw Failure.keyboard }
		diagnostic("ARX_INSPECTION_SMOKE_KEYBOARD_TYPE")

		phase = "keyboard-redirect"
		snapshot = try await keyboardSnapshot(page, scope: scope)
		let redirected = await runtime.performInspectionFormAction(
			.init(
				operationID: UUID(),
				snapshot: snapshot,
				reference: try pointerReference("Arx redirect field", in: snapshot),
				action: .typeText("abc")
			),
			on: page,
			scope: scope,
			authorize: { true }
		)
		snapshot = try await keyboardSnapshot(page, scope: scope)
		guard
			redirected.disposition == .possiblyDispatched,
			!keyboardLog(snapshot).contains("ARX_SECRET_LEAKED"),
			snapshot.nodes.first(where: { $0.name == "Arx redirect field" })?.value == ""
		else { throw Failure.keyboard }

		// A password field never gets a reference, so it can't be a typing target.
		guard !snapshot.nodes.contains(where: { $0.name == "Arx secret field" })
		else { throw Failure.keyboard }
		diagnostic("ARX_INSPECTION_SMOKE_KEYBOARD_REDIRECT")

		phase = "keyboard-keys"
		try await load(page, path: "inspection/keyboard", title: "Arx keyboard ready")
		try await keyboard(.keyChord("k", modifiers: [.control]), on: "Arx type field", page: page, scope: scope)
		phase = "keyboard-tab"
		try await keyboard(.keyChord("Tab", modifiers: []), on: "Arx before field", page: page, scope: scope)
		phase = "keyboard-log"
		snapshot = try await keyboardSnapshot(page, scope: scope)
		try await pointer(
			.hover(at: nil),
			reference: try pointerReference("Arx focus probe", in: snapshot),
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		snapshot = try await keyboardSnapshot(page, scope: scope)
		guard
			keyboardLog(snapshot).contains("ARX_SHORTCUT_SEEN"),
			keyboardLog(snapshot).contains("ARX_ACTIVE_after"),
			snapshot.nodes.first(where: { $0.name == "Arx type field" })?.value == "AB"
		else { throw Failure.keyboard }
		try await pointer(
			.click(at: nil, count: 1, modifiers: []),
			reference: try pointerReference("Arx dialog opener", in: snapshot),
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		phase = "keyboard-escape"
		try await keyboard(.keyChord("Escape", modifiers: []), on: "Arx dialog button", page: page, scope: scope)

		// The dialog closes at once; its close event follows in a later task.
		var closed = false
		for _ in 0..<50 where !closed {
			closed = keyboardLog(try await keyboardSnapshot(page, scope: scope)).contains("ARX_DIALOG_CLOSED")
			if !closed { try await Task.sleep(for: .milliseconds(50)) }
		}
		guard closed else { throw Failure.keyboard }
		diagnostic("ARX_INSPECTION_SMOKE_KEYBOARD_KEYS")
	}

	/// ABI29 checked state and multiple-select values, including unchanged.
	private func verifyFormState(_ page: ChromiumPage) async throws {
		phase = "form-state-checked"
		try await load(page, path: "inspection/state", title: "Arx state ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		try await formState(.setChecked(true), on: "Arx state agree", expect: .dispatched, page: page, scope: scope)
		try await formState(.setChecked(true), on: "Arx state agree", expect: .unchanged, page: page, scope: scope)
		try await formState(.setChecked(true), on: "Arx state blue", expect: .dispatched, page: page, scope: scope)
		try await formState(
			.setChecked(false),
			on: "Arx state blue",
			expect: .notDispatched,
			failure: .invalidValue,
			page: page,
			scope: scope
		)
		var snapshot = try await keyboardSnapshot(page, scope: scope)
		var log = stateLog(snapshot)
		guard
			snapshot.nodes.first(where: { $0.name == "Arx state agree" })?.checked == true,
			snapshot.nodes.first(where: { $0.name == "Arx state blue" })?.checked == true,
			snapshot.nodes.first(where: { $0.name == "Arx state red" })?.checked == false,
			log.components(separatedBy: "ARX_CHANGE_agree_true").count == 2,
			log.contains("ARX_INPUT_agree"),
			log.contains("ARX_CHANGE_blue")
		else { throw Failure.formState }
		diagnostic("ARX_INSPECTION_SMOKE_FORM_STATE_CHECKED")

		phase = "form-state-select"
		try await formState(
			.selectValues(["green", "blue"]),
			on: "Arx state colors",
			expect: .dispatched,
			page: page,
			scope: scope
		)
		try await formState(
			.selectValues(["blue", "green"]),
			on: "Arx state colors",
			expect: .unchanged,
			page: page,
			scope: scope
		)
		try await formState(
			.selectValues(["gray"]),
			on: "Arx state colors",
			expect: .notDispatched,
			failure: .notInteractable,
			page: page,
			scope: scope
		)
		try await formState(
			.selectValues(["purple"]),
			on: "Arx state colors",
			expect: .notDispatched,
			failure: .optionNotFound,
			page: page,
			scope: scope
		)
		snapshot = try await keyboardSnapshot(page, scope: scope)
		log = stateLog(snapshot)
		guard log.components(separatedBy: "ARX_SELECT_").count == 2, log.contains("ARX_SELECT_green_blue")
		else { throw Failure.formState }
		diagnostic("ARX_INSPECTION_SMOKE_FORM_STATE_SELECT")
	}

	private func stateLog(_ snapshot: ChromiumInspectionSnapshot) -> String {
		snapshot.nodes.compactMap(\.text).filter { $0.hasPrefix("ARX_STATE_START") }.joined()
	}

	/// Inspects afresh, then performs one form state action on the named reference.
	private func formState(
		_ action: ChromiumReferenceFormAction,
		on name: String,
		expect disposition: ChromiumReferenceFormDisposition,
		failure: ChromiumReferenceFormFailure? = nil,
		page: ChromiumPage,
		scope: UUID
	) async throws {
		let snapshot = try await keyboardSnapshot(page, scope: scope)
		let result = await runtime.performInspectionFormAction(
			.init(
				operationID: UUID(),
				snapshot: snapshot,
				reference: try pointerReference(name, in: snapshot),
				action: action
			),
			on: page,
			scope: scope,
			authorize: { true }
		)
		guard result.disposition == disposition, result.failure == failure else {
			diagnostic("ARX_INSPECTION_SMOKE_FORM_STATE_RESULT \(result.disposition) \(result.failure.map { "\($0)" } ?? "none")")
			throw Failure.formState
		}
	}

	/// ABI30: a chooser opened by a pointer action is held, answered with a
	/// file, and a second one is cancelled.
	private func verifyUpload(_ page: ChromiumPage) async throws {
		phase = "upload"
		try await load(page, path: "inspection/upload", title: "Arx upload ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		guard page.fileChooser() == nil else { throw Failure.upload }
		let directory = URL.temporaryDirectory.appending(path: "arx-upload-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { cleanUp("upload folder") { try FileManager.default.removeItem(at: directory) } }
		let file = directory.appending(path: "arx-upload.txt")
		try Data("ARX_UPLOAD_BYTES".utf8).write(to: file)

		let chooser = try await openChooser(page, scope: scope)
		guard chooser.allowsMultiple else { throw Failure.upload }
		try page.answerFileChooser(chooser, paths: [file.path])
		guard page.fileChooser() == nil else { throw Failure.upload }
		try await waitForUploadLog("ARX_FILES_arx-upload.txt:16", page: page, scope: scope)

		let cancelled = try await openChooser(page, scope: scope)
		try page.answerFileChooser(cancelled, paths: [])

		// A chooser is answered once.
		do {
			try page.answerFileChooser(cancelled, paths: [file.path])
			throw Failure.upload
		} catch let failure as ChromiumFileChooserFailure where failure == .stale {}
		try await waitForUploadLog("ARX_FILE_CANCEL", page: page, scope: scope)
		diagnostic("ARX_INSPECTION_SMOKE_UPLOAD")
	}

	private func openChooser(
		_ page: ChromiumPage,
		scope: UUID
	) async throws -> ChromiumFileChooser {
		let snapshot = try await keyboardSnapshot(page, scope: scope)
		try await pointer(
			.click(at: nil, count: 1, modifiers: []),
			// A file input's accessible name appends its chosen files, so the
			// inspector never reports it; it is the page's only control.
			reference: try uploadReference(in: snapshot),
			snapshot: snapshot,
			page: page,
			scope: scope
		)
		var chooser: ChromiumFileChooser?
		try await wait {
			chooser = page.fileChooser()
			return chooser != nil
		}
		guard let chooser else { throw Failure.upload }
		return chooser
	}

	private func uploadReference(in snapshot: ChromiumInspectionSnapshot) throws -> String {
		let references = snapshot.nodes.compactMap(\.reference)
		guard references.count == 1, let reference = references.first else { throw Failure.upload }
		return reference
	}

	private func waitForUploadLog(
		_ text: String,
		page: ChromiumPage,
		scope: UUID
	) async throws {
		for _ in 0..<50 {
			let snapshot = try await keyboardSnapshot(page, scope: scope)
			if snapshot.nodes.compactMap(\.text).contains(where: { $0.contains(text) }) { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		throw Failure.upload
	}

	/// DEV-1309: a chooser a person opens shows the macOS open panel, from a
	/// plain input, from script with a detached input, and from a cross-site
	/// frame. Clicks go in as window events, not automation actions, so nothing
	/// arms the page; before the fix each was cancelled and no panel opened.
	private func verifyPersonUpload(_ page: ChromiumPage) async throws {
		phase = "person-upload"
		try await load(page, path: "inspection/person-upload", title: "Arx person upload ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }

		// Past the automation window an earlier phase may have left armed.
		try await Task.sleep(for: .seconds(4))

		// Page points of each opener, from the fixture's fixed layout.
		let openers: [(name: String, point: CGPoint)] = [
			("plain", .init(x: 60, y: 40)),
			("script", .init(x: 60, y: 100)),
			("frame", .init(x: 60, y: 160)),
		]
		for opener in openers {
			phase = "person-upload-\(opener.name)"
			try sendClick(at: opener.point, in: page)
			var panel: NSSavePanel?
			try await wait {
				panel = Self.filePanel(for: page)
				return panel != nil
			}
			guard let panel, page.fileChooser() == nil else { throw Failure.personUpload }
			panel.cancel(nil)
			try await waitForUploadLog("ARX_CANCEL_\(opener.name)", page: page, scope: scope)
			try await wait { Self.filePanel(for: page) == nil }
		}
		diagnostic("ARX_INSPECTION_SMOKE_PERSON_UPLOAD")
	}

	/// DEV-1309: a file dragged from Finder reaches the page's drop target.
	/// AppKit's own lookup picks the destination, so a view over the page that
	/// took file drags would fail here, and the drop reaches the page through
	/// Chromium's drag destination as a real drag's would.
	private func verifyFileDrop(_ page: ChromiumPage) async throws {
		phase = "file-drop"
		try await load(page, path: "inspection/person-upload", title: "Arx person upload ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		let directory = URL.temporaryDirectory.appending(path: "arx-drop-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { cleanUp("drop folder") { try FileManager.default.removeItem(at: directory) } }
		let file = directory.appending(path: "arx-drop.png")
		try Data("ARX_DROP_BYTES".utf8).write(to: file)

		guard let window = page.view.window else { throw Failure.fileDrop }
		let location = page.view.convert(Self.viewPoint(.init(x: 160, y: 290), in: page.view), to: nil)
		let info = FileDraggingInfo(window: window, location: location, file: file)
		guard
			let view = Self.dragDestination(in: window, at: location, types: info.types),
			view === page.view || view.isDescendant(of: page.view)
		else { throw Failure.fileDrop }

		let destination: any NSDraggingDestination = view
		_ = destination.draggingEntered?(info)
		try await Task.sleep(for: .milliseconds(300))
		_ = destination.draggingUpdated?(info)
		try await Task.sleep(for: .milliseconds(300))
		_ = destination.prepareForDragOperation?(info)
		_ = destination.performDragOperation?(info)
		destination.concludeDragOperation?(info)
		try await waitForUploadLog("ARX_DROPPED_arx-drop.png:14", page: page, scope: scope)
		diagnostic("ARX_INSPECTION_SMOKE_FILE_DROP")
	}

	/// A left click at a page point, sent through the window as a person's is.
	private func sendClick(
		at point: CGPoint,
		in page: ChromiumPage
	) throws {
		guard let window = page.view.window else { throw Failure.personUpload }
		let location = page.view.convert(Self.viewPoint(point, in: page.view), to: nil)
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
				pressure: type == .leftMouseDown ? 1 : 0
			) else { throw Failure.personUpload }
			window.sendEvent(event)
		}
	}

	/// A page point, from the page's top left corner, in the page view's own coordinates.
	private static func viewPoint(
		_ point: CGPoint,
		in view: NSView
	) -> NSPoint {
		.init(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
	}

	/// The open or save panel Chrome shows for the page, as a sheet on its window or on its own.
	private static func filePanel(for page: ChromiumPage) -> NSSavePanel? {
		if let sheet = page.view.window?.attachedSheet as? NSSavePanel { return sheet }
		return NSApplication.shared.windows.lazy.compactMap { $0 as? NSSavePanel }.first { $0.isVisible }
	}

	/// The view AppKit sends a drag to: its own lookup, which skips hidden views but not
	/// transparent ones or ones whose `hitTest` refuses the point.
	private static func dragDestination(
		in window: NSWindow,
		at location: NSPoint,
		types: [NSPasteboard.PasteboardType]
	) -> NSView? {
		guard let root = window.contentView?.superview ?? window.contentView else { return nil }
		let selector = NSSelectorFromString("_hitTest:dragTypes:")
		guard root.responds(to: selector) else { return nil }
		typealias Lookup = @convention(c) (NSView, Selector, UnsafePointer<NSPoint>, NSSet) -> NSView?
		let lookup = unsafeBitCast(root.method(for: selector), to: Lookup.self)
		var point = root.superview?.convert(location, from: nil) ?? location
		let set = NSSet(array: types.map(\.rawValue))
		return withUnsafePointer(to: &point) { lookup(root, selector, $0, set) }
	}

	/// ABI31: JavaScript dialogs and a permission prompt, read and answered.
	private func verifyDialogs(_ page: ChromiumPage) async throws {
		phase = "dialogs-javascript"
		try runtime.configureContentHosting(on: page, enabled: true)
		defer { cleanUp("content host") { try runtime.configureContentHosting(on: page, enabled: false) } }
		try await load(page, path: "inspection/dialogs", title: "Arx dialogs ready")
		let scope = newScope()
		defer { runtime.revokeInspectionScope(scope) }
		guard page.dialog() == nil else { throw Failure.dialogs }

		var dialog = try await openDialog("Arx alert", page: page, scope: scope) { dialog in
			guard dialog.kind == .alert, dialog.message == "ARX_ALERT_TEXT" else { throw Failure.dialogs }
			try page.answerDialog(dialog, accept: true)
		}
		do {
			try page.answerDialog(dialog, accept: true)
			throw Failure.dialogs
		} catch let failure as ChromiumPageDialogFailure where failure == .stale {}
		dialog = try await openDialog("Arx confirm", page: page, scope: scope) { dialog in
			guard dialog.kind == .confirm else { throw Failure.dialogs }
			try page.answerDialog(dialog, accept: false)
		}
		dialog = try await openDialog("Arx prompt", page: page, scope: scope) { dialog in
			guard dialog.kind == .prompt, dialog.defaultPrompt == "ARX_DEFAULT"
			else { throw Failure.dialogs }
			try page.answerDialog(dialog, accept: true, text: "ARX_ANSWER")
		}
		try await waitForDialogLog(["ARX_ALERT_DONE", "ARX_CONFIRM_false", "ARX_PROMPT_ARX_ANSWER"], page: page, scope: scope)
		diagnostic("ARX_INSPECTION_SMOKE_DIALOGS_JAVASCRIPT")

		phase = "dialogs-before-unload"
		let guarded = try await keyboardSnapshot(page, scope: scope)
		try await pointer(
			.click(at: nil, count: 1, modifiers: []),
			reference: try pointerReference("Arx guard", in: guarded),
			snapshot: guarded,
			page: page,
			scope: scope
		)
		try await waitForDialogLog(["ARX_GUARDED"], page: page, scope: scope)
		try page.navigate(to: url("inspection/main"))
		try await answerNextDialog(page, kind: .beforeUnload, accept: false)
		try await Task.sleep(for: .milliseconds(300))
		guard page.navigation.title == "Arx dialogs ready" else { throw Failure.dialogs }
		let before = revisions[page.identifier, default: 0]
		try page.navigate(to: url("inspection/main"))
		try await answerNextDialog(page, kind: .beforeUnload, accept: true)
		try await waitLoaded(page, after: before, path: "inspection/main", title: "Arx inspection ready")
		diagnostic("ARX_INSPECTION_SMOKE_DIALOGS_BEFORE_UNLOAD")

		phase = "dialogs-permission"
		try await load(page, path: "inspection/dialogs", title: "Arx dialogs ready")
		_ = try await openDialog("Arx location", page: page, scope: scope) { dialog in
			guard dialog.kind == .permission, !dialog.origin.isEmpty, !dialog.message.isEmpty
			else { throw Failure.dialogs }
			try page.answerDialog(dialog, accept: false)
		}
		_ = try await openDialog("Arx screens", page: page, scope: scope) { dialog in
			guard dialog.kind == .permission else { throw Failure.dialogs }
			try page.answerDialog(dialog, accept: true)
		}
		try await waitForDialogLog(["ARX_GEO_ERROR_1", "ARX_SCREENS_"], page: page, scope: scope)
		diagnostic("ARX_INSPECTION_SMOKE_DIALOGS_PERMISSION")
	}

	/// Clicks the named button, waits for the dialog it opens and answers it.
	/// A JavaScript dialog blocks the click's own task until it is answered.
	@discardableResult
	private func openDialog(
		_ name: String,
		page: ChromiumPage,
		scope: UUID,
		answer: (ChromiumPageDialog) async throws -> Void
	) async throws -> ChromiumPageDialog {
		let snapshot = try await keyboardSnapshot(page, scope: scope)
		let reference = try pointerReference(name, in: snapshot)
		let click = Task {
			await runtime.performInspectionFormAction(
				.init(
					operationID: UUID(),
					snapshot: snapshot,
					reference: reference,
					action: .pointer(.click(at: nil, count: 1, modifiers: []))
				),
				on: page,
				scope: scope,
				authorize: { true }
			)
		}
		var dialog: ChromiumPageDialog?
		try await wait {
			dialog = page.dialog()
			return dialog != nil
		}
		guard let dialog else { throw Failure.dialogs }
		try await answer(dialog)

		// The click finishes once the page continues; a slow page may report uncertainty.
		_ = await click.value
		guard page.dialog()?.token != dialog.token else { throw Failure.dialogs }
		return dialog
	}

	private func answerNextDialog(
		_ page: ChromiumPage,
		kind: ChromiumPageDialog.Kind,
		accept: Bool
	) async throws {
		var dialog: ChromiumPageDialog?
		try await wait {
			dialog = page.dialog()
			return dialog != nil
		}
		guard let dialog, dialog.kind == kind else { throw Failure.dialogs }
		try page.answerDialog(dialog, accept: accept)
	}

	private func waitForDialogLog(
		_ texts: [String],
		page: ChromiumPage,
		scope: UUID
	) async throws {
		for _ in 0..<60 {
			let log = try await keyboardSnapshot(page, scope: scope).nodes.compactMap(\.text).joined(separator: " ")
			if texts.allSatisfy(log.contains) { return }
			try await Task.sleep(for: .milliseconds(50))
		}
		diagnostic("ARX_INSPECTION_SMOKE_DIALOGS_MISSING " + texts.joined(separator: ","))
		throw Failure.dialogs
	}

	private func keyboardSnapshot(
		_ page: ChromiumPage,
		scope: UUID
	) async throws -> ChromiumInspectionSnapshot {
		try await runtime.inspect(page, scope: scope, limits: .init(includesFormValues: true))
	}

	private func keyboardLog(_ snapshot: ChromiumInspectionSnapshot) -> String {
		snapshot.nodes.compactMap(\.text).filter { $0.hasPrefix("ARX_KEYBOARD_START") }.joined()
	}

	/// Inspects afresh, then performs one keyboard action on the named reference.
	private func keyboard(
		_ action: ChromiumReferenceFormAction,
		on name: String,
		page: ChromiumPage,
		scope: UUID
	) async throws {
		let snapshot = try await keyboardSnapshot(page, scope: scope)
		let result = await runtime.performInspectionFormAction(
			.init(
				operationID: UUID(),
				snapshot: snapshot,
				reference: try pointerReference(name, in: snapshot),
				action: action
			),
			on: page,
			scope: scope,
			authorize: { true }
		)
		guard result.disposition == .dispatched, result.failure == nil else {
			diagnostic("ARX_INSPECTION_SMOKE_KEYBOARD_RESULT \(result.disposition) \(result.failure.map { "\($0)" } ?? "none")")
			throw Failure.keyboard
		}
	}

	private func pointerSnapshot(
		_ page: ChromiumPage,
		scope: UUID
	) async throws -> ChromiumInspectionSnapshot {
		try await runtime.inspect(page, scope: scope, limits: .init(includesBounds: true))
	}

	private func pointerReference(
		_ name: String,
		in snapshot: ChromiumInspectionSnapshot
	) throws -> String {
		guard let reference = snapshot.nodes.first(where: { $0.name == name })?.reference
		else { throw Failure.pointer }
		return reference
	}

	private func pointer(
		_ action: ChromiumPointerAction,
		reference: String,
		snapshot: ChromiumInspectionSnapshot,
		page: ChromiumPage,
		scope: UUID
	) async throws {
		let result = await runtime.performInspectionFormAction(
			.init(operationID: UUID(), snapshot: snapshot, reference: reference, action: .pointer(action)),
			on: page,
			scope: scope,
			authorize: { true }
		)
		guard result.disposition == .dispatched, result.failure == nil else {
			diagnostic("ARX_INSPECTION_SMOKE_POINTER_RESULT \(result.disposition) \(result.failure.map { "\($0)" } ?? "none")")
			throw Failure.pointer
		}
	}

	/// Hidden and detached pages capture without being shown; pages print to PDF
	/// and a PDF document's own bytes are read.
	private func verifyOffscreenAndPDF(_ page: ChromiumPage) async throws {
		phase = "offscreen-hidden"
		guard runtime.supportsOffscreenCapture, runtime.supportsPDF
		else { throw Failure.unavailable }

		// A background tab: its window is ordered out and stays out.
		let hidden = try await makePage()
		try await load(hidden, path: "inspection/values", title: "Arx inspection values")
		let window = hidden.view.window
		window?.orderOut(nil)
		let background = try await runtime.capture(hidden, offscreen: true)
		guard
			background.width > 0,
			background.height > 0,
			background.png.starts(with: [0x89, 0x50, 0x4E, 0x47]),
			window?.isVisible == false
		else { throw Failure.offscreen }

		// A page that was never attached to any window.
		phase = "offscreen-detached"
		let detached = try runtime.makePage()
		detached.onNavigation = { [weak self, weak detached] _ in
			guard let self, let detached else { return }
			self.revisions[detached.identifier, default: 0] += 1
		}
		pages.append(detached)
		let detachedBefore = revisions[detached.identifier, default: 0]
		try detached.navigate(to: url("inspection/values"))

		// Unlike load, the page has no window to wait for.
		try await wait {
			revisions[detached.identifier, default: 0] > detachedBefore
			&& detached.navigation.title == "Arx inspection values"
			&& !detached.navigation.isLoading
		}
		let unattached = try await runtime.capture(detached, offscreen: true)
		guard unattached.width > 0, detached.view.window == nil
		else { throw Failure.offscreen }
		diagnostic("ARX_INSPECTION_SMOKE_OFFSCREEN")

		phase = "pdf"
		let exported = try await runtime.pdf(page, kind: .export(.init()))
		guard exported.data.starts(with: Data("%PDF".utf8))
		else { throw Failure.pdf }

		// An HTML page has no PDF source to read.
		do {
			_ = try await runtime.pdf(page, kind: .source)
			throw Failure.acceptedInvalid
		} catch ChromiumPDFFailure.unsupportedDocument {}

		let document = try await makePage()
		let before = revisions[document.identifier, default: 0]
		try document.navigate(to: url("inspection/document.pdf"))
		try await wait {
			revisions[document.identifier, default: 0] > before
			&& document.navigation.url?.path == "/inspection/document.pdf"
			&& !document.navigation.isLoading
		}
		let source = try await runtime.pdf(document, kind: .source)
		guard source.data.starts(with: Data("%PDF".utf8)), source.data.count < 4_096
		else { throw Failure.pdf }
		diagnostic("ARX_INSPECTION_SMOKE_PDF")

		try await verifyLoadingPDF(html: page)
		try await verifySavePage(page)
	}

	/// ABI48 (DEV-819): a PDF reads as one while it's still loading, which is how Save Page As
	/// offers only PDF for it, and its own bytes are read once it has loaded. The fixture sends
	/// the document's second half after a pause.
	private func verifyLoadingPDF(html page: ChromiumPage) async throws {
		phase = "pdf-loading"
		guard runtime.supportsDocumentTypes
		else { throw Failure.unavailable }
		guard runtime.documentType(of: page) == .web
		else { throw Failure.pdf }

		let document = try await makePage()
		let before = revisions[document.identifier, default: 0]
		try document.navigate(to: url("inspection/slow.pdf"))
		try await wait {
			revisions[document.identifier, default: 0] > before
			&& document.navigation.url?.path == "/inspection/slow.pdf"
			&& document.navigation.isLoading
			&& runtime.documentType(of: document) == .pdf
		}
		try await wait {
			!document.navigation.isLoading
		}
		guard runtime.documentType(of: document) == .pdf
		else { throw Failure.pdf }
		let source = try await runtime.pdf(document, kind: .source)
		guard source.data.starts(with: Data("%PDF".utf8)), source.data.count < 4_096
		else { throw Failure.pdf }
		diagnostic("ARX_INSPECTION_SMOKE_PDF_LOADING")
	}

	/// ABI45 (DEV-795): Save Page As writes a web archive, and the app may load a page's
	/// source and a local file, but never the source of anything that isn't the web.
	private func verifySavePage(_ page: ChromiumPage) async throws {
		phase = "save-page"
		guard runtime.supportsPageMenu, let pageURL = page.navigation.url
		else { throw Failure.unavailable }

		let folder = FileManager.default.temporaryDirectory
			.appending(path: "arx-save-page-" + UUID().uuidString, directoryHint: .isDirectory)
		try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		defer { cleanUp("save-page folder") { try FileManager.default.removeItem(at: folder) } }

		let archive = folder.appending(path: "page.mhtml")
		try runtime.savePage(page, to: archive, kind: .webArchive)

		// The archive doesn't exist until saving writes it; until then it reads as empty.
		func size(_ url: URL) -> Int {
			(try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0
		}
		try await wait { size(archive) > 0 }
		diagnostic("ARX_INSPECTION_SMOKE_SAVE_PAGE")

		phase = "view-source"
		let viewer = try await makePage()
		let before = revisions[viewer.identifier, default: 0]
		guard
			let source = URL(string: "view-source:" + pageURL.absoluteString),
			let localSource = URL(string: "view-source:" + folder.appending(path: "local.html").absoluteString)
		else { throw Failure.acceptedInvalid }
		try viewer.navigate(to: source)
		try await wait {
			revisions[viewer.identifier, default: 0] > before
			&& !viewer.navigation.isLoading
			&& viewer.navigation.errorCode == nil
		}

		// Only the web's source: a local file's source stays out of reach.
		let file = folder.appending(path: "local.html")
		try Data("<title>Arx local file</title>".utf8).write(to: file)
		do {
			try viewer.navigate(to: localSource)
			throw Failure.acceptedInvalid
		} catch ChromiumError.invalidURL {}
		diagnostic("ARX_INSPECTION_SMOKE_VIEW_SOURCE")

		phase = "open-file"
		let local = try await makePage()
		try local.navigate(to: file)
		try await wait { local.navigation.title == "Arx local file" && !local.navigation.isLoading }
		diagnostic("ARX_INSPECTION_SMOKE_OPEN_FILE")
	}

	/// The page mutates itself from a trusted click, dispatched through the same
	/// reference path an agent uses, so the window never has to be key.
	private func verifyDOMMutations(_ page: ChromiumPage) async throws {
		phase = "replace-node"
		guard runtime.supportsReferenceClick
		else { throw Failure.unavailable }

		let scope = newScope()
		let original = try await runtime.inspect(page, scope: scope)
		let reference = try InspectionSmokeContract.reference(
			in: original,
			named: InspectionSmokeContract.buttonName
		)
		try await click(
			InspectionSmokeContract.replaceControlName,
			in: original,
			on: page,
			scope: scope
		)
		try await wait { page.navigation.title == "Arx inspection replaced" }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: original, on: page, scope: scope)
		}

		phase = "remove-reinsert"
		let replaced = try await runtime.inspect(page, scope: scope)
		let replacementReference = try InspectionSmokeContract.reference(
			in: replaced,
			named: "Arx replacement button"
		)
		guard replaced.domVersion != original.domVersion
		else { throw Failure.mutationNotObserved }
		try await runtime.validateInspectionReference(replacementReference, in: replaced, on: page, scope: scope)
		try await click(
			InspectionSmokeContract.reinsertControlName,
			in: replaced,
			on: page,
			scope: scope
		)
		try await wait { page.navigation.title == "Arx inspection reinserted" }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(
				replacementReference,
				in: replaced,
				on: page,
				scope: scope
			)
		}
		let reinserted = try await runtime.inspect(page, scope: scope)
		guard reinserted.domVersion != replaced.domVersion
		else { throw Failure.mutationNotObserved }
		runtime.revokeInspectionScope(scope)
		diagnostic("ARX_INSPECTION_SMOKE_DOM_INVALIDATION")
	}

	private func verifyNavigation(_ page: ChromiumPage) async throws {
		phase = "navigation"
		let scope = newScope()
		let before = try await runtime.inspect(page, scope: scope)
		let reference = try InspectionSmokeContract.reference(in: before, named: "Arx replacement button")
		try await load(page, path: "inspection/replacement", title: "Arx inspection replacement")
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: before, on: page, scope: scope)
		}
		let replacement = try await runtime.inspect(page, scope: scope)
		guard replacement.documentID != before.documentID
		else { throw Failure.mutationNotObserved }
		let replacementReference = try InspectionSmokeContract.reference(
			in: replacement,
			named: "Replacement document button"
		)

		phase = "reload"
		let beforeReload = revisions[page.identifier, default: 0]
		try page.reload()
		try await waitLoaded(
			page,
			after: beforeReload,
			path: "inspection/replacement",
			title: "Arx inspection replacement"
		)
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(
				replacementReference,
				in: replacement,
				on: page,
				scope: scope
			)
		}
		let reloaded = try await runtime.inspect(page, scope: scope)
		guard reloaded.documentID != replacement.documentID
		else { throw Failure.mutationNotObserved }

		phase = "history-return"
		let beforeBack = revisions[page.identifier, default: 0]
		try page.goBack()
		try await wait {
			self.revisions[page.identifier, default: 0] > beforeBack
			&& page.navigation.url == self.url("inspection/main")
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
		}
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: before, on: page, scope: scope)
		}
		let returned = try await runtime.inspect(page, scope: scope)
		guard returned.snapshotID != before.snapshotID
		else { throw Failure.scopeIsolation }

		// Back can restore BFCache or reload. The old authority must fail in either case.
		runtime.revokeInspectionScope(scope)
		diagnostic("ARX_INSPECTION_SMOKE_NAVIGATION_RELOAD_HISTORY")
	}

	private func verifyCancellationAndClosure() async throws {
		phase = "cancel-pending"
		let page = try await makePage()
		try await load(page, path: "inspection/main", title: "Arx inspection ready")
		let scope = newScope()
		var dispatched = false
		let pending = Task { [self] in
			dispatched = true
			return try await runtime.inspect(page, scope: scope)
		}
		let dispatchDeadline = ContinuousClock.now.advanced(by: .seconds(15))
		while !dispatched {
			guard ContinuousClock.now < dispatchDeadline
			else { throw Failure.timeout }

			await Task.yield()
		}
		pending.cancel()
		do {
			_ = try await pending.value
			throw Failure.acceptedCancelled
		} catch is CancellationError {
			// The caller cannot release a result after cancellation.
		}
		runtime.revokeInspectionScope(scope)

		phase = "close-current"
		let closeScope = newScope()
		let current = try await runtime.inspect(page, scope: closeScope)
		let reference = try InspectionSmokeContract.reference(
			in: current,
			named: InspectionSmokeContract.buttonName
		)
		page.close()
		guard !runtime.inspectionDocumentIsCurrent(current, on: page, scope: closeScope)
		else { throw Failure.acceptedClosed }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: current, on: page, scope: closeScope)
		}
		diagnostic("ARX_INSPECTION_SMOKE_CANCEL_CLOSE")
	}

	private func verifyPrivateAndUnsupported() async throws {
		phase = "private-denied"
		let profile = UUID()
		try runtime.preparePrivateProfile(profile)
		privateProfiles.append(profile)
		let page = try await makePage(profile: profile)
		try await load(page, path: "inspection/main", title: "Arx inspection ready")
		let scope = newScope()
		try await requireFailure(.unavailable) { [self] in
			_ = try await runtime.inspect(page, scope: scope)
		}
		page.close()

		phase = "unsupported-document"
		let blank = try await makePage()
		let beforeBlank = revisions[blank.identifier, default: 0]
		try blank.navigate(to: URL(string: "about:blank")!)
		try await wait {
			self.revisions[blank.identifier, default: 0] > beforeBlank
			&& blank.navigation.url?.absoluteString == "about:blank"
			&& !blank.navigation.isLoading
		}
		try await requireFailure(.unsupportedDocument) { [self] in
			_ = try await runtime.inspect(blank, scope: scope)
		}
		blank.close()
		diagnostic("ARX_INSPECTION_SMOKE_PRIVATE_UNSUPPORTED")
	}

	private func verifyExpiry() async throws {
		phase = "expiry"
		let page = try await makePage()
		try await load(page, path: "inspection/main", title: "Arx inspection ready")
		let scope = newScope()
		let snapshot = try await runtime.inspect(page, scope: scope)
		let reference = try InspectionSmokeContract.reference(
			in: snapshot,
			named: InspectionSmokeContract.buttonName
		)
		try await runtime.validateInspectionReference(reference, in: snapshot, on: page, scope: scope)
		try await Task.sleep(for: .seconds(32))
		guard !runtime.inspectionDocumentIsCurrent(snapshot, on: page, scope: scope)
		else { throw Failure.acceptedExpired }
		try await requireFailure(.staleReference) { [self] in
			try await runtime.validateInspectionReference(reference, in: snapshot, on: page, scope: scope)
		}
		diagnostic("ARX_INSPECTION_SMOKE_EXPIRED")
	}

	private func makePage(profile: UUID? = nil) async throws -> ChromiumPage {
		let page = try await runtime.makePage(profile: profile)
		let window = NSWindow(
			contentRect: .init(x: 0, y: 0, width: 640, height: 480),
			styleMask: [.titled, .closable],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.contentView = page.view
		window.makeKeyAndOrderFront(nil)
		page.onNavigation = { [weak self, weak page] _ in
			guard let self, let page else { return }
			self.revisions[page.identifier, default: 0] += 1
		}
		pages.append(page)
		windows[page.identifier] = window
		return page
	}

	private func load(
		_ page: ChromiumPage,
		path: String,
		title: String
	) async throws {
		let before = revisions[page.identifier, default: 0]
		try page.navigate(to: url(path))
		try await waitLoaded(page, after: before, path: path, title: title)
	}

	private func click(
		_ control: String,
		in snapshot: ChromiumInspectionSnapshot,
		on page: ChromiumPage,
		scope: UUID
	) async throws {
		guard
			pages.contains(where: { $0 === page }),
			!page.isClosed,
			!page.isPrivate,
			page.navigation.url == url("inspection/main")
		else { throw InspectionSmokeContract.Failure.invalidFixture }

		let request = ChromiumReferenceClickRequest(
			operationID: UUID(),
			snapshot: snapshot,
			reference: try InspectionSmokeContract.reference(in: snapshot, named: control)
		)
		let result = await runtime.clickInspectionReference(
			request,
			on: page,
			scope: scope,
			authorize: { true }
		)
		guard
			result.operationID == request.operationID,
			result.disposition == .dispatched,
			result.failure == nil
		else { throw Failure.click }
	}

	private func waitLoaded(
		_ page: ChromiumPage,
		after revision: Int,
		path: String,
		title: String
	) async throws {
		try await wait {
			self.revisions[page.identifier, default: 0] > revision
			&& page.navigation.url == self.url(path)
			&& page.navigation.title == title
			&& !page.navigation.isLoading
			&& page.navigation.errorCode == nil
			&& page.view.window != nil
		}
	}

	private func wait(_ condition: () -> Bool) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(15))
		while !condition() {
			guard clock.now < deadline
			else { throw Failure.timeout }

			try await Task.sleep(for: .milliseconds(20))
		}
	}

	private func requireFailure(
		_ expected: ChromiumInspectionFailure,
		action: () async throws -> Void
	) async throws {
		do {
			try await action()
			throw Failure.acceptedInvalid
		} catch let error as ChromiumInspectionFailure where error == expected {
			// Only the exact expected boundary failure counts as acceptance evidence.
		}
	}

	private func newScope() -> UUID {
		let scope = UUID()
		scopes.append(scope)
		return scope
	}

	private func url(_ path: String) -> URL { baseURL.appending(path: path) }

	private func diagnostic(_ message: String) {
		FileHandle.standardError.write(Data("\(message)\n".utf8))
	}

	private func safeReason(_ error: any Error) -> String {
		switch error {
		case let error as ChromiumInspectionFailure: String(describing: error)
		case let error as InspectionSmokeContract.Failure: String(describing: error)
		case let error as ChromiumCaptureFailure: "capture-" + String(describing: error)
		case let error as ChromiumPDFFailure: "pdf-" + String(describing: error)
		case let error as Failure: String(describing: error)
		case is CancellationError: "cancelled"
		default: "unexpected-error"
		}
	}

	private enum Failure: Error {
		case unavailable
		case changedPage
		case scopeIsolation
		case mutationNotObserved
		case acceptedInvalid
		case acceptedCancelled
		case acceptedClosed
		case acceptedExpired
		case timeout
		case window
		case frame
		case formValues
		case offscreen
		case pdf
		case pointer
		case click
		case keyboard
		case formState
		case upload
		case personUpload
		case fileDrop
		case dialogs
	}
}

extension ChromiumInspectionBounds {
	fileprivate var midX: Double { Double(x) + Double(width) / 2 }
	fileprivate var midY: Double { Double(y) + Double(height) / 2 }
}

/// What AppKit hands a drag destination for one file dragged from Finder (DEV-1309).
@MainActor
private final class FileDraggingInfo: NSObject, @MainActor NSDraggingInfo {
	private let window: NSWindow
	private let location: NSPoint
	private let pasteboard: NSPasteboard
	private static var sequence: Int = 2_000

	internal init(
		window: NSWindow,
		location: NSPoint,
		file: URL
	) {
		self.window = window
		self.location = location
		self.pasteboard = NSPasteboard(name: .init("dev.capturecontext.arx.smoke.drop.\(UUID().uuidString)"))
		pasteboard.clearContents()
		pasteboard.writeObjects([file as NSURL])
		Self.sequence += 1
		self.draggingSequenceNumber = Self.sequence
	}

	internal var types: [NSPasteboard.PasteboardType] { pasteboard.types ?? [] }

	internal var draggingDestinationWindow: NSWindow? { window }
	internal var draggingSourceOperationMask: NSDragOperation { .copy }
	internal var draggingLocation: NSPoint { location }
	internal var draggedImageLocation: NSPoint { location }
	internal var draggedImage: NSImage? { nil }
	internal var draggingPasteboard: NSPasteboard { pasteboard }
	internal var draggingSource: Any? { nil }
	internal let draggingSequenceNumber: Int
	internal var draggingFormation: NSDraggingFormation = .none
	internal var animatesToDestination: Bool = false
	internal var numberOfValidItemsForDrop: Int = 1
	internal var springLoadingHighlight: NSSpringLoadingHighlight { .none }

	internal func slideDraggedImage(to screenPoint: NSPoint) {}

	internal func enumerateDraggingItems(
		options enumOpts: NSDraggingItemEnumerationOptions = [],
		for view: NSView?,
		classes classArray: [AnyClass],
		searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
		using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
	) {}

	internal func resetSpringLoading() {}
}
