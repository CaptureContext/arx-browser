import CustomDump
import Foundation
import Testing
@testable import BrowserCore

internal struct AutomationConsequenceTests {
	@Test(arguments: [
		("Pay now", AutomationConsequence.Kind.pay),
		("Buy now", .pay),
		("Place your order", .pay),
		("Send", .send),
		("Post", .post),
		("Publish story", .post),
		("Delete", .delete),
		("Delete forever", .delete),
		("Empty Trash", .delete),
		("Send money", .pay),
		("Send (3)", .send),
		("Transfer", .submit),
		("Cancel subscription", .submit),
		("Jetzt kaufen", .pay),
		("Видалити", .delete),
	])
	internal func pressingAConsequentialButtonIsConsequential(
		label: String,
		kind: AutomationConsequence.Kind
	) {
		let snapshot = Self.snapshot([.init(index: 0, role: "button", name: label, reference: "target")])
		let consequence = AutomationConsequence.of(.click(Self.click("target")), snapshot: snapshot, url: Self.url)
		expectNoDifference(consequence?.kind, kind)
		expectNoDifference(consequence?.host, "shop.example")
	}

	@Test(arguments: [
		"Next", "Search", "Add to cart", "Totally safe submit", "Payment methods", "Posts", "Order history",
		"Sort order", "Sending options", "Proceed to checkout", "Purchase orders", "Undo send",
		"Send this to everyone on the team before the release goes out",
	])
	internal func pressingAnOrdinaryButtonIsNot(label: String) {
		let snapshot = Self.snapshot([.init(index: 0, role: "button", name: label, reference: "target")])
		#expect(AutomationConsequence.of(.click(Self.click("target")), snapshot: snapshot, url: Self.url) == nil)
	}

	@Test
	internal func labelComesFromTheTextInsideTheControl() {
		let snapshot = Self.snapshot([
			.init(index: 0, role: "button", reference: "target"),
			.init(index: 1, parent: 0, role: "staticText", text: "Send"),
		])
		expectNoDifference(
			AutomationConsequence.of(.click(Self.click("target")), snapshot: snapshot, url: Self.url)?.kind,
			.send
		)
	}

	@Test
	internal func clickingInsideAControlPressesTheControl() {
		let snapshot = Self.snapshot([
			.init(index: 0, role: "button", name: "Delete"),
			.init(index: 1, parent: 0, role: "image", reference: "icon"),
		])
		expectNoDifference(
			AutomationConsequence.of(.click(Self.click("icon")), snapshot: snapshot, url: Self.url)?.kind,
			.delete
		)
	}

	@Test
	internal func linksThatGoSomewhereAreReading() {
		let snapshot = Self.snapshot([
			.init(index: 0, role: "link", name: "Delete an API key", reference: "docs"),
			.init(index: 1, role: "link"),
			.init(index: 2, parent: 1, role: "staticText", text: "Send feedback", reference: "footer"),
		])
		for reference in ["docs", "footer"] {
			#expect(AutomationConsequence.of(.click(Self.click(reference)), snapshot: snapshot, url: Self.url) == nil)
		}
	}

	@Test(arguments: ["Continue", "Next", nil] as [String?])
	internal func whateverSendsACardFormPays(label: String?) {
		let card = Self.snapshot([
			.init(index: 0, role: "form"),
			.init(index: 1, parent: 0, role: "textField", name: "Card number"),
			.init(index: 2, parent: 0, role: "button", name: label, reference: "target"),
		])
		expectNoDifference(
			AutomationConsequence.of(.click(Self.click("target")), snapshot: card, url: Self.url)?.kind,
			.pay
		)

		// A checkout whose card fields are a payment service's frame, outside any form.
		let frame = Self.snapshot([
			.init(index: 0, role: "group"),
			.init(index: 1, parent: 0, role: "iframe", name: "Secure card payment input frame"),
			.init(index: 2, parent: 0, role: "button", name: label, reference: "target"),
		])
		expectNoDifference(
			AutomationConsequence.of(.click(Self.click("target")), snapshot: frame, url: Self.url)?.kind,
			.pay
		)

		let address = Self.snapshot([
			.init(index: 0, role: "form"),
			.init(index: 1, parent: 0, role: "textField", name: "Street address"),
			.init(index: 2, parent: 0, role: "button", name: label, reference: "target"),
		])
		#expect(AutomationConsequence.of(.click(Self.click("target")), snapshot: address, url: Self.url) == nil)

		// Another form on the same page, and text that only mentions a card, are not the button's.
		let page = Self.snapshot([
			.init(index: 0, role: "main"),
			.init(index: 1, parent: 0, role: "form"),
			.init(index: 2, parent: 1, role: "searchBox"),
			.init(index: 3, parent: 1, role: "button", name: label, reference: "target"),
			.init(index: 4, parent: 0, role: "paragraph"),
			.init(index: 5, parent: 4, role: "staticText", text: "Card number is on the front"),
			.init(index: 6, parent: 0, role: "form"),
			.init(index: 7, parent: 6, role: "textField", name: "Card number"),
			.init(index: 8, parent: 6, role: "button", name: "Pay"),
		])
		#expect(AutomationConsequence.of(.click(Self.click("target")), snapshot: page, url: Self.url) == nil)
	}

	@Test
	internal func enterInAFieldSubmitsWithItsFormsButton() {
		let snapshot = Self.snapshot([
			.init(index: 0, role: "form"),
			.init(index: 1, parent: 0, role: "textField", reference: "message"),
			.init(index: 2, parent: 0, role: "button", name: "Send"),
			.init(index: 3, role: "form"),
			.init(index: 4, parent: 3, role: "searchBox", reference: "search"),
			.init(index: 5, parent: 3, role: "button", name: "Search"),
		])
		let enter = AutomationOperation.form(Self.form("message", kind: .keyPress, value: "Enter"))
		let chord = AutomationOperation.form(Self.form("message", kind: .keyChord, value: "Enter", modifiers: [.command]))
		let line = AutomationOperation.form(Self.form("message", kind: .typeText, value: "Hi\n"))
		for operation in [enter, chord, line] {
			expectNoDifference(AutomationConsequence.of(operation, snapshot: snapshot, url: Self.url)?.kind, .send)
		}

		// Outside a form, only a nearby Send counts: a filter box beside a key's Delete never asks.
		let keys = Self.snapshot([
			.init(index: 0, role: "group"),
			.init(index: 1, parent: 0, role: "textField", reference: "filter"),
			.init(index: 2, parent: 0, role: "button", name: "Delete"),
		])
		let filter = AutomationOperation.form(Self.form("filter", kind: .keyPress, value: "Enter"))
		#expect(AutomationConsequence.of(filter, snapshot: keys, url: Self.url) == nil)
		let chat = Self.snapshot([
			.init(index: 0, role: "group"),
			.init(index: 1, parent: 0, role: "textField", reference: "composer"),
			.init(index: 2, parent: 0, role: "button", name: "Attach"),
			.init(index: 3, parent: 0, role: "button", name: "Send"),
		])
		let message = AutomationOperation.form(Self.form("composer", kind: .keyPress, value: "Enter"))
		expectNoDifference(AutomationConsequence.of(message, snapshot: chat, url: Self.url)?.kind, .send)

		// An auxiliary button before the form's Send doesn't hide it.
		let preview = Self.snapshot([
			.init(index: 0, role: "form"),
			.init(index: 1, parent: 0, role: "textField", reference: "message"),
			.init(index: 2, parent: 0, role: "button", name: "Preview"),
			.init(index: 3, parent: 0, role: "button", name: "Send"),
		])
		let previewEnter = AutomationOperation.form(Self.form("message", kind: .keyPress, value: "Enter"))
		expectNoDifference(AutomationConsequence.of(previewEnter, snapshot: preview, url: Self.url)?.kind, .send)

		let typing = AutomationOperation.form(Self.form("message", kind: .typeText, value: "Hi"))
		let search = AutomationOperation.form(Self.form("search", kind: .keyPress, value: "Enter"))
		let text = AutomationOperation.form(Self.form("message", kind: .replaceText, value: "Hi"))
		for operation in [typing, search, text] {
			#expect(AutomationConsequence.of(operation, snapshot: snapshot, url: Self.url) == nil)
		}
	}

	@Test
	internal func enterAsksWhenTheWindowMayHideTheFormsButtons() {
		// The window ends inside the form: its Send may be past the edge.
		var cut = Self.snapshot([
			.init(index: 0, role: "form"),
			.init(index: 1, parent: 0, role: "textField", reference: "message"),
		])
		cut.totalNodes = 300
		let enter = AutomationOperation.form(Self.form("message", kind: .keyPress, value: "Enter"))
		expectNoDifference(AutomationConsequence.of(enter, snapshot: cut, url: Self.url)?.kind, .submit)

		// A later window whose field's form starts above it.
		let later = PageInspectionSnapshot(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: "frame",
			domVersion: "1",
			nodes: [.init(index: 256, parent: 12, role: "textField", reference: "message")],
			omissions: PageInspectionOmission.allCases,
			windowStart: 256,
			totalNodes: 300
		)
		expectNoDifference(AutomationConsequence.of(enter, snapshot: later, url: Self.url)?.kind, .submit)

		// A whole form in a partial window decides by what it shows.
		var whole = Self.snapshot([
			.init(index: 0, role: "form"),
			.init(index: 1, parent: 0, role: "searchBox", reference: "message"),
			.init(index: 2, parent: 0, role: "button", name: "Search"),
			.init(index: 3, role: "paragraph"),
		])
		whole.totalNodes = 300
		#expect(AutomationConsequence.of(enter, snapshot: whole, url: Self.url) == nil)
	}

	@Test
	internal func keysOnAButtonPressIt() {
		let snapshot = Self.snapshot([.init(index: 0, role: "button", name: "Post", reference: "target")])
		for key in ["Enter", " "] {
			let operation = AutomationOperation.form(Self.form("target", kind: .keyPress, value: key))
			expectNoDifference(AutomationConsequence.of(operation, snapshot: snapshot, url: Self.url)?.kind, .post)
		}
	}

	@Test
	internal func pointerClicksPressWhatTheyLandOn() {
		let snapshot = Self.snapshot([
			.init(index: 0, role: "button", name: "Delete", reference: "delete", bounds: .init(x: 0, y: 0, width: 50, height: 20)),
			.init(index: 1, role: "button", name: "Edit", reference: "edit", bounds: .init(x: 60, y: 0, width: 50, height: 20)),
		])
		expectNoDifference(
			AutomationConsequence.of(.form(Self.pointer(reference: "delete")), snapshot: snapshot, url: Self.url)?.kind,
			.delete
		)
		expectNoDifference(
			AutomationConsequence.of(.form(Self.pointer(at: .init(x: 10, y: 10))), snapshot: snapshot, url: Self.url)?.kind,
			.delete
		)

		// A scroll since the snapshot moves the page without changing it: a point elsewhere may
		// still land on the Delete, so it asks too, and only a page without one doesn't.
		for point in [AutomationPointer.Point(x: 70, y: 10), .init(x: 300, y: 300)] {
			expectNoDifference(
				AutomationConsequence.of(.form(Self.pointer(at: point)), snapshot: snapshot, url: Self.url)?.kind,
				.delete
			)
		}
		let ordinary = Self.snapshot([
			.init(index: 0, role: "button", name: "Edit", reference: "edit", bounds: .init(x: 60, y: 0, width: 50, height: 20)),
		])
		#expect(AutomationConsequence.of(.form(Self.pointer(at: .init(x: 70, y: 10))), snapshot: ordinary, url: Self.url) == nil)

		// A point reaches the part of the page a partial window left out.
		var partial = ordinary
		partial.totalNodes = 300
		expectNoDifference(
			AutomationConsequence.of(.form(Self.pointer(at: .init(x: 70, y: 10))), snapshot: partial, url: Self.url)?.kind,
			.submit
		)

		// A drag that captures nothing clicks where it ends, or where it starts.
		let send = Self.snapshot([
			.init(index: 0, role: "button", name: "Send", reference: "send", bounds: .init(x: 0, y: 0, width: 50, height: 20)),
			.init(index: 1, role: "listItem", reference: "item", bounds: .init(x: 0, y: 40, width: 50, height: 20)),
		])
		let ontoItself = AutomationFormRequest(
			target: Self.click("send"),
			kind: .drag,
			value: "",
			pointer: .init(destinationReference: "send")
		)
		expectNoDifference(AutomationConsequence.of(.form(ontoItself), snapshot: send, url: Self.url)?.kind, .send)
		let ontoSend = AutomationFormRequest(
			target: Self.click("item"),
			kind: .drag,
			value: "",
			pointer: .init(destinationPoint: .init(x: 10, y: 10))
		)
		expectNoDifference(AutomationConsequence.of(.form(ontoSend), snapshot: send, url: Self.url)?.kind, .send)

		// A pointer click on a container may land on the Send inside it.
		let composer = Self.snapshot([
			.init(index: 0, role: "group", reference: "composer"),
			.init(index: 1, parent: 0, role: "button", name: "Send"),
		])
		expectNoDifference(
			AutomationConsequence.of(.form(Self.pointer(reference: "composer")), snapshot: composer, url: Self.url)?.kind,
			.send
		)

		// An overlay later in the document may let the click through to the Delete under it.
		let covered = Self.snapshot([
			.init(index: 0, role: "button", name: "Delete", reference: "delete", bounds: .init(x: 0, y: 0, width: 50, height: 20)),
			.init(index: 1, role: "genericContainer", bounds: .init(x: 0, y: 0, width: 400, height: 400)),
		])
		expectNoDifference(
			AutomationConsequence.of(.form(Self.pointer(at: .init(x: 10, y: 10))), snapshot: covered, url: Self.url)?.kind,
			.delete
		)

		// Without bounds a point could land anywhere, so a page with a consequential control asks.
		let unbounded = Self.snapshot([.init(index: 0, role: "button", name: "Delete", reference: "delete")])
		expectNoDifference(
			AutomationConsequence.of(.form(Self.pointer(at: .init(x: 70, y: 10))), snapshot: unbounded, url: Self.url)?.kind,
			.delete
		)
	}

	@Test
	internal func scriptsThatPressOrWriteAreConsequential() {
		let pressing = [
			"document.querySelector('#buy').click()",
			"form.requestSubmit()",
			"await fetch('/api/messages', { method: 'POST', body })",
			"navigator.sendBeacon('/log', data)",
			"element.click ()",
			"await fetch ('/messages', { method: 'POST' })",
		]
		for script in pressing {
			expectNoDifference(AutomationConsequence.scripting(script)?.kind, .submit)
		}

		let reading = [
			"return document.title",
			"return [...document.querySelectorAll('a')].map(a => a.href)",
			"return await (await fetch('/api/items')).json()",
		]
		for script in reading {
			#expect(AutomationConsequence.scripting(script) == nil)
		}
	}

	@Test(arguments: AutomationApprovalPolicy.allCases)
	internal func everyPolicyAsksForAConsequentialAction(policy: AutomationApprovalPolicy) {
		#expect(!policy.skipsApproval(for: .consequential))
		let client = AutomationClient(
			id: UUID(),
			name: "Agent",
			credentialDigest: String(repeating: "a", count: 64),
			scopes: [],
			capabilities: [.read, .pageContent, .interact],
			approvalPolicy: policy,
			grantRevision: UUID()
		)
		let click = AutomationOperation.click(Self.click("target"))
		let payment = AutomationConsequence(kind: .pay)
		let skips = client.skipsApproval(for: click, consequence: payment)
		#expect(!skips)
		expectNoDifference(client.skipsApproval(for: click), policy != .alwaysAsk)
	}

	private static let url: URL = URL(string: "https://shop.example/item/42")!

	private static func snapshot(_ nodes: [PageInspectionNode]) -> PageInspectionSnapshot {
		.init(
			snapshotID: "snapshot",
			documentID: "document",
			frameID: "frame",
			domVersion: "1",
			nodes: nodes,
			omissions: PageInspectionOmission.allCases
		)
	}

	private static func click(_ reference: String) -> AutomationClickRequest {
		.init(
			operationID: UUID(),
			targetID: UUID(),
			expectedRevision: String(repeating: "a", count: 64),
			snapshotID: "snapshot",
			reference: reference
		)
	}

	private static func form(
		_ reference: String,
		kind: AutomationFormRequest.Kind,
		value: String,
		modifiers: [AutomationFormRequest.KeyModifier]? = nil
	) -> AutomationFormRequest {
		.init(target: click(reference), kind: kind, value: value, keyModifiers: modifiers)
	}

	private static func pointer(reference: String) -> AutomationFormRequest {
		.init(target: click(reference), kind: .pointerClick, value: "", pointer: .init())
	}

	private static func pointer(at point: AutomationPointer.Point) -> AutomationFormRequest {
		.init(target: click("snapshot"), kind: .pointerClick, value: "", pointer: .init(point: point))
	}
}
