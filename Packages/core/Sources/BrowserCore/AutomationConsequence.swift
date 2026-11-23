import Foundation

/// What a press on a website would do that the user can't take back: paying, sending,
/// posting or deleting (DEV-1008).
///
/// Arx reads it from the agent's own released snapshot of the page, never from anything the
/// agent says, and asks the user every time, whatever the client's standing approval policy or
/// temporary grant. A label can only make an action ask; it never makes one safe.
///
/// Deliberately narrow, the way people label a last step: a verb at the start of a short
/// button name, so "Send" and "Pay now" ask and "Sending options" doesn't. A link that goes
/// somewhere is reading, whatever it says.
public struct AutomationConsequence: Codable, Equatable, Hashable, Sendable {
	public enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
		/// Pays, buys, orders or donates.
		case pay

		/// Sends a message.
		case send

		/// Posts or publishes.
		case post

		/// Deletes something on the website.
		case delete

		/// Another last step Arx can't name, such as a transfer, ending a subscription, or a
		/// script that presses, submits or sends.
		case submit
	}

	public var kind: Kind

	/// The pressed control's label, as the snapshot shows it.
	public var label: String?

	/// The site the press happens on.
	public var host: String?

	public init(
		kind: Kind,
		label: String? = nil,
		host: String? = nil
	) {
		self.kind = kind
		self.label = label
		self.host = host
	}
}

extension AutomationConsequence {
	/// The consequence of an operation, read from the released snapshot its reference names and
	/// the URL of the tab it acts on. Only clicks, form presses and submissions, and scripts can
	/// have one; a batch's steps are classified one by one.
	public static func of(
		_ operation: AutomationOperation,
		snapshot: PageInspectionSnapshot?,
		url: URL?
	) -> Self? {
		let host = url?.host()
		switch operation {
		case let .click(request):
			guard let snapshot else { return nil }
			return Page(snapshot).pressing(reference: request.reference).map { $0.on(host) }

		case let .form(request):
			guard let snapshot else { return nil }
			return Page(snapshot).consequence(of: request).map { $0.on(host) }

		case let .script(request):
			return scripting(request.script).map { $0.on(host) }

		case .inventory, .wait, .command, .capture, .inspect, .scroll, .signIn, .batch, .data, .link, .load,
			.pdf, .findInPage, .dialog, .media, .settings, .logs, .passwordSignIn:
			return nil
		}
	}

	/// A script that can press, submit or send asks: it calls `click`, `submit`, `requestSubmit`,
	/// `dispatchEvent` or `sendBeacon`, or `fetch` or `XMLHttpRequest` with a writing method.
	/// Scripts that only read run under the client's policy. This catches an agent's mistakes, not
	/// a script written to hide what it does.
	internal static func scripting(_ script: String) -> Self? {
		// `el.click ()` calls the same as `el.click()`.
		let source = String(script.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
		let presses = [".click(", ".submit(", "requestsubmit(", "dispatchevent(", "sendbeacon("]
		let requests = ["fetch(", "xmlhttprequest"]
		let writes: Set<String> = ["post", "put", "patch", "delete"]
		let words = script.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
		let writesRequest = requests.contains(where: source.contains) && words.contains(where: writes.contains)
		guard presses.contains(where: source.contains) || writesRequest
		else { return nil }

		return .init(kind: .submit)
	}

	private func on(_ host: String?) -> Self {
		var consequence = self
		consequence.host = host
		return consequence
	}
}

extension AutomationConsequence {
	/// A released snapshot read for what its controls do.
	fileprivate struct Page {
		let nodes: [PageInspectionNode]
		let positions: [Int: Int]

		/// Whether the snapshot is one window of a longer document.
		let isPartial: Bool

		init(_ snapshot: PageInspectionSnapshot) {
			self.nodes = snapshot.nodes
			self.isPartial = snapshot.windowStart > 0 || snapshot.totalNodes > snapshot.windowStart + snapshot.nodes.count
			self.positions = Dictionary(
				snapshot.nodes.enumerated().map { ($0.element.index, $0.offset) },
				uniquingKeysWith: { first, _ in first }
			)
		}

		func consequence(of request: AutomationFormRequest) -> AutomationConsequence? {
			switch request.kind {
			case .pointerClick where request.targetsViewport:
				return request.pointer?.point.flatMap(pressing(at:))

			case .pointerClick:
				return pointing(at: request.target.reference)

			// A drag that captures nothing ends in a mouse-down and -up: a click wherever it ends.
			case .drag where request.targetsViewport:
				let start = request.pointer?.point.flatMap(pressing(at:))
				return start ?? dragEnd(request.pointer)

			case .drag:
				return pointing(at: request.target.reference) ?? dragEnd(request.pointer)

			case .keyPress, .keyChord:
				guard
					["Enter", " "].contains(request.value),
					let position = position(of: request.target.reference)
				else { return nil }

				// Enter or Space on a button presses it; Enter in a field submits; on a link, it follows it.
				if let control = control(around: position) { return committing(control) }
				guard request.value == "Enter", nodes[position].role != "link" else { return nil }
				return submitting(from: position)

			case .typeText:
				// A typed line break presses Enter.
				guard
					request.value.contains("\n"),
					let position = position(of: request.target.reference)
				else { return nil }
				return submitting(from: position)

			case .replaceText, .selectValue, .hover, .selectValues, .setChecked, .upload:
				return nil
			}
		}

		/// Real mouse input at a reference's centre: the control around it, or one inside it.
		private func pointing(at reference: String) -> AutomationConsequence? {
			guard let position = position(of: reference) else { return nil }
			if let consequence = control(around: position).flatMap(committing) { return consequence }
			return descendants(of: position).lazy
				.filter { isControl(nodes[$0]) }
				.compactMap(committing)
				.first
		}

		private func dragEnd(_ pointer: AutomationPointer?) -> AutomationConsequence? {
			if let reference = pointer?.destinationReference { return pointing(at: reference) }
			return pointer?.destinationPoint.flatMap(pressing(at:))
		}

		/// A click presses the button or menu item around the node. A link that goes
		/// somewhere is reading, whatever it says.
		func pressing(reference: String) -> AutomationConsequence? {
			guard
				let position = position(of: reference),
				let control = control(around: position)
			else { return nil }
			return committing(control)
		}

		/// What a point could press. Bounds can't say which of overlapping nodes takes the click
		/// (an overlay may let it through), and a scroll since the snapshot moves everything
		/// without changing the document, so a point asks when any control on the page would
		/// commit; one under the point is named first.
		func pressing(at point: AutomationPointer.Point) -> AutomationConsequence? {
			let hits = nodes.indices.filter { position in
				guard let bounds = nodes[position].bounds else { return false }
				return bounds.x <= point.x
				&& point.x < bounds.x + bounds.width
				&& bounds.y <= point.y
				&& point.y < bounds.y + bounds.height
			}
			let hit = hits.reversed().lazy
				.compactMap { control(around: $0) }
				.compactMap(committing)
				.first
			let shown = nodes.indices.lazy
				.filter { isControl(nodes[$0]) }
				.compactMap(committing)
				.first

			// A point reaches the whole document, the part the window left out too.
			return hit ?? shown ?? (isPartial ? .init(kind: .submit) : nil)
		}

		/// What pressing the control commits: its label's verb, or paying when it sends a form
		/// that takes a card, however it is labeled, Continue and Next included.
		func committing(_ control: Int) -> AutomationConsequence? {
			let label = label(of: control)
			if let kind = label.kind { return .init(kind: kind, label: label.text) }
			guard takesCard(control) else { return nil }
			return .init(kind: .pay, label: label.text)
		}

		/// Enter in a field submits its form. The snapshot can't tell its submit button from
		/// auxiliary ones, so any of the form's buttons that would commit counts. Outside a form,
		/// only a Send-like button of the nearest box with any buttons counts, as in a chat box,
		/// so a filter box beside a Delete never asks.
		///
		/// When the snapshot is one window of the page and the form, or the box searched, runs
		/// past the window's edge, its buttons may be out of sight, so the submission asks.
		func submitting(from position: Int) -> AutomationConsequence? {
			let ancestors = ancestors(of: position).dropFirst()
			let unseen = AutomationConsequence(kind: .submit)
			if let form = ancestors.first(where: { nodes[$0].role == "form" }) {
				let consequence = descendants(of: form).lazy
					.filter { nodes[$0].role == "button" }
					.compactMap(committing)
					.first
				return consequence ?? (isPartial && runsPastWindow(form) ? unseen : nil)
			}
			for ancestor in ancestors.prefix(4) {
				let buttons = descendants(of: ancestor).filter { isControl(nodes[$0]) }
				guard !buttons.isEmpty else { continue }
				let consequence = buttons.lazy
					.compactMap(committing)
					.first { [.send, .post, .pay].contains($0.kind) }
				let isCut = runsPastWindow(ancestor) || startsAboveWindow(position)
				return consequence ?? (isPartial && isCut ? unseen : nil)
			}

			// A form above the window's first node, or buttons past its last, can't be seen.
			let outermost = ancestors.last ?? position
			let isCut = startsAboveWindow(position) || runsPastWindow(outermost)
			return isPartial && isCut ? unseen : nil
		}

		/// Whether the node's ancestry goes on above the window's first node.
		private func startsAboveWindow(_ position: Int) -> Bool {
			let outermost = ancestors(of: position).last ?? position
			return nodes[outermost].parent != nil
		}

		/// Whether the node's subtree may go on past the window's last node.
		private func runsPastWindow(_ position: Int) -> Bool {
			(descendants(of: position).last ?? position) == nodes.count - 1
		}

		private func position(of reference: String) -> Int? {
			nodes.firstIndex { $0.reference == reference }
		}

		private func isControl(_ node: PageInspectionNode) -> Bool {
			["button", "menuItem"].contains(node.role)
		}

		/// The button or menu item at or around the node, or nil when a link holds it.
		private func control(around position: Int) -> Int? {
			for ancestor in ancestors(of: position) {
				if isControl(nodes[ancestor]) { return ancestor }
				if nodes[ancestor].role == "link" { return nil }
			}
			return nil
		}

		/// Whether the control sends a form that takes a card: its form, or else the nearest box
		/// around it with a field, has a field, or a frame a payment service puts one in, named
		/// for a card number or code.
		private func takesCard(_ control: Int) -> Bool {
			let ancestors = ancestors(of: control).dropFirst()
			let form = ancestors.first { nodes[$0].role == "form" }
			?? ancestors.prefix(4).first { ancestor in
				descendants(of: ancestor).contains { isField($0) || nodes[$0].role == "iframe" }
			}
			guard let form else { return false }

			return descendants(of: form).contains { position in
				let node = nodes[position]
				guard isField(position) || node.role == "iframe" else { return false }
				let name = Label(node.name ?? "")
				return Label.cardFields.contains(where: name.starts)
				|| (node.role == "iframe" && name.tokens.contains { ["card", "payment"].contains($0) })
			}
		}

		private func isField(_ position: Int) -> Bool {
			["textField", "searchBox", "spinButton", "comboBoxGrouping", "textFieldWithComboBox"]
				.contains(nodes[position].role)
		}

		/// The node itself, then its parents inside this snapshot window.
		private func ancestors(of position: Int) -> [Int] {
			var result: [Int] = [position]
			var current = nodes[position].parent
			while let index = current, let parent = positions[index], !result.contains(parent) {
				result.append(parent)
				current = nodes[parent].parent
			}
			return result
		}

		/// Nodes come in document order, so a subtree is the run of nodes after its root.
		private func descendants(of position: Int) -> [Int] {
			var inside: Set<Int> = [nodes[position].index]
			var result: [Int] = []
			for next in nodes.indices.dropFirst(position + 1) {
				guard let parent = nodes[next].parent, inside.contains(parent) else { break }
				inside.insert(nodes[next].index)
				result.append(next)
			}
			return result
		}

		/// The control's own name, or else the text inside it.
		private func label(of position: Int) -> Label {
			if let name = nodes[position].name, !name.isEmpty { return Label(name) }
			let text = descendants(of: position)
				.compactMap { nodes[$0].text ?? nodes[$0].name }
				.joined(separator: " ")
			return Label(text)
		}
	}

	/// A label normalized into lowercase words, without a trailing parenthetical such as a count.
	fileprivate struct Label {
		let text: String?
		let tokens: [String]

		init(_ text: String) {
			var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "("), open > trimmed.startIndex {
				trimmed = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
			}
			self.text = trimmed.isEmpty ? nil : String(trimmed.prefix(256))
			self.tokens = trimmed.lowercased()
				.components(separatedBy: CharacterSet.alphanumerics.inverted)
				.filter { !$0.isEmpty }
		}

		/// The verb a short label starts with.
		var kind: Kind? {
			guard let text, text.count <= 32 else { return nil }
			if Self.records.contains(where: starts) { return nil }
			return Kind.allCases.first { kind in
				(Self.verbs[kind] ?? []).contains(where: starts)
			}
		}

		/// Whether the label starts with the words of `phrase`.
		func starts(_ phrase: String) -> Bool {
			let words = Label(phrase).tokens
			return !words.isEmpty && tokens.starts(with: words)
		}

		/// Last steps by what they commit, in English, German, French, Spanish, Portuguese,
		/// Italian, Ukrainian and Russian. Paying comes first: "Send money" pays.
		private static let verbs: [Kind: [String]] = [
			.pay: [
				"pay", "buy", "place order", "place your order", "order now", "purchase", "complete purchase",
				"complete order", "complete payment", "confirm and pay", "confirm payment", "confirm purchase",
				"confirm order", "confirm transfer", "submit payment", "submit order", "transfer money",
				"transfer funds", "transfer now", "withdraw money", "withdraw funds", "withdraw now", "send money",
				"donate",
				"bezahlen", "jetzt kaufen", "kaufen", "bestellen", "zahlungspflichtig bestellen", "überweisen",
				"spenden",
				"payer", "acheter", "commander", "valider la commande", "valider ma commande",
				"confirmer le paiement", "confirmer la commande", "faire un don",
				"pagar", "comprar", "realizar pedido", "finalizar compra", "finalizar pedido", "confirmar pago",
				"confirmar pagamento", "confirmar pedido", "confirmar compra", "donar", "doar",
				"paga", "acquista", "ordina", "conferma pagamento", "conferma ordine", "conferma acquisto", "dona",
				"оплатити", "купити", "замовити", "оплатить", "купить", "заказать",
			],
			.send: [
				"send", "senden", "absenden", "envoyer", "enviar", "invia", "надіслати", "відправити", "отправить",
			],
			.post: [
				"post", "publish", "tweet", "veröffentlichen", "publier", "publicar", "pubblica", "опублікувати",
				"опубликовать",
			],
			.delete: [
				"delete", "empty trash", "löschen", "endgültig löschen", "supprimer", "eliminar", "excluir", "borrar",
				"elimina", "видалити", "удалить",
			],
			// A bare Transfer or Withdraw is GitHub's Transfer repository or Withdraw invitation:
			// a last step, not a payment.
			.submit: [
				"transfer", "withdraw", "cancel subscription", "cancel plan", "cancel membership",
				"cancel my subscription", "cancel my plan", "cancel my membership", "cancel your subscription",
				"cancel your plan", "cancel your membership", "yes cancel subscription", "yes cancel plan",
				"yes cancel membership", "confirm cancellation", "confirm cancelation", "finish cancellation",
				"finish cancelation", "complete cancellation", "complete cancelation", "turn off auto renew",
				"turn off autorenew", "turn off auto renewal", "turn off autorenewal", "don t renew", "dont renew",
				"end subscription", "end plan", "end membership",
			],
		]

		/// Records, not presses: "Purchase orders" names a table in a business app.
		private static let records: [String] = [
			"purchase order", "purchase orders", "purchase requisition", "purchase requisitions",
			"purchase request", "purchase requests", "purchase history", "purchase histories",
			"purchase invoice", "purchase invoices", "purchase record", "purchase records",
		]

		/// The names of the fields a card is typed into.
		static let cardFields: [String] = [
			"card number", "credit card number", "debit card number", "cardnumber", "cvc", "cvv", "csc",
			"security code", "card security code",
		]
	}
}
