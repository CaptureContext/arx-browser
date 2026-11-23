import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Settings › Links › Proxy Links, a page of its own (DEV-1114): the rules as a list under New
/// Rule, as Profiles lists its profiles (DEV-767). New Rule and a click on a rule open the rule's form as a modal sheet
/// (`ProxyLinkEditorView`). Each row has its switch and, on the right, a drag handle: of the
/// enabled rules that match a link, the first one wins, so the order matters (DEV-1113). A rule
/// also moves with ⌥⌘↑ and ⌥⌘↓ while it has focus, Move Up and Move Down in its menu, and the same
/// VoiceOver actions (DEV-1163). Every rule, Arx's own too, can be deleted from its menu, its form
/// or with Delete while it has focus.
internal struct ProxyLinksSettingsView: View {
	internal let store: StoreOf<SettingsFeature>

	@Environment(\.settingsToolbarAdd)
	private var addsFromToolbar

	@SwiftUI.State
	private var drag: RuleDrag?

	@SwiftUI.State
	private var rowFrames: [UUID: CGRect] = [:]

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	internal var body: some View {
		rules
		.sheet(
			isPresented: Binding(
				get: { store.proxyLinkEditor != nil },
				set: { if !$0 { send(.cancel) } }
			)
		) {
			ProxyLinkEditorView(store: store)
		}
	}

	/// The parameters removed everywhere, the prefixes as `utm_*`, then a line per site
	/// (DEV-918).
	internal static func cleanRulesSummary(_ rules: CleanLinkRules) -> String {
		let everywhere = (rules.parameters + rules.prefixes.map { $0 + "*" }).joined(separator: ", ")
		let sites = rules.sites.map { site in
			let names = site.parameters
			+ site.prefixes.map { $0 + "*" }
			+ site.pathSegmentPrefixes.map { "/" + $0 + "…" }
			return site.name + ": " + names.joined(separator: ", ")
		}
		return ([everywhere] + sites).joined(separator: "\n")
	}

	private var rules: some View {
		VStack(alignment: .leading, spacing: 6) {
			// The page's bar carries the title.
			HStack {
				Spacer()
				Button(String.localized(.appUI.links.restoreDefaults)) {
					send(.restoreDefaults)
				}
				.help(String.localized(.appUI.links.restoreDefaultsHelp))
				if !addsFromToolbar {
					Button(String.localized(.appUI.links.newRule), systemImage: "plus") {
						send(.newRule)
					}
				}
			}
			.padding(.horizontal, 14)

			SettingsSection(
				caption: String.localized(.appUI.links.proxyDescription)
			) {
				if store.proxyLinkRules.isEmpty {
					Text(localized: .appUI.links.noRules)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
						.settingsRow()
				}
				ForEach(Array(orderedRules.enumerated()), id: \.element.id) { index, rule in
					row(rule, index: index)
				}
			}
			.coordinateSpace(.named(Self.coordinateSpace))

			// When sync removes the dragged rule, or leaves one rule with no handle, the gesture
			// never ends: the drag ends here.
			.onChange(of: store.proxyLinkRules.map(\.id)) { _, ids in
				if let drag, ids.count < 2 || !ids.contains(drag.id) { self.drag = nil }
			}
		}
	}

	/// The rules, with the one being dragged shown in the slot it would drop into.
	private var orderedRules: [ProxyLinkRule] {
		var rules = store.proxyLinkRules
		guard
			let drag,
			let index = rules.firstIndex(where: { $0.id == drag.id })
		else { return rules }

		let rule = rules.remove(at: index)
		rules.insert(rule, at: drag.slot(among: rules.count + 1))
		return rules
	}

	private func row(
		_ rule: ProxyLinkRule,
		index: Int
	) -> some View {
		HStack(spacing: 8) {
			Button { send(.edit(rule.id)) } label: {
				HStack(spacing: 12) {
					VStack(alignment: .leading, spacing: 2) {
						Text(rule.name)
							.lineLimit(1)
						Text(rule.representation)
							.font(.caption.monospaced())
							.foregroundStyle(.secondary)
							.lineLimit(1)
							.truncationMode(.middle)
					}
					Spacer(minLength: 12)
				}
				.settingsRow()
				.contentShape(.rect)
			}

			// The fill reaches the card's leading inset and stops before the row's own controls.
			.buttonStyle(.settingsGroupRow(edges: .leading))
			.accessibilityHint(Text(localized: .appUI.links.editRuleHint))

			// Delete and ⌥⌘↑ or ⌥⌘↓ work on the row the keyboard reached.
			.focusable()
			.onKeyPress(keys: [.delete, .deleteForward]) { _ in
				send(.delete(rule.id))
				return .handled
			}
			.onKeyPress(keys: [.upArrow, .downArrow]) { press in
				guard
					let move = RuleMove(key: press.key, modifiers: press.modifiers),
					let destination = move.destination(from: index, among: store.proxyLinkRules.count)
				else { return .ignored }

				send(.move(rule.id, to: destination))
				return .handled
			}
			.accessibilityActions {
				moveButtons(rule, index: index)
			}
			Toggle(
				rule.name,
				isOn: Binding(
					get: { rule.isEnabled },
					set: { _ in send(.toggle(rule.id)) }
				)
			)
			.toggleStyle(.switch)
			.controlSize(.small)
			.labelsHidden()
			if store.proxyLinkRules.count > 1 {
				dragHandle(rule)
			}
		}
		.opacity(rule.isEnabled ? 1 : 0.55)
		.background {
			if drag?.id == rule.id {
				RoundedRectangle(cornerRadius: 6).fill(.quaternary)
			}
		}
		.onGeometryChange(for: CGRect.self) { proxy in
			proxy.frame(in: .named(Self.coordinateSpace))
		} action: { frame in

			// Kept current while a drag previews its order too, so the order it commits starts the
			// next drag from where the rows are; a drag keeps its own copy from when it began.
			rowFrames[rule.id] = frame
		}
		.contextMenu {
			Button(String.localized(.appUI.links.editRule)) { send(.edit(rule.id)) }
			moveButtons(rule, index: index)
			Button(String.localized(.appUI.links.deleteRule), role: .destructive) { send(.delete(rule.id)) }
		}
	}

	/// Move Up and Move Down, each only where the rule can go that way: for the row's menu and
	/// VoiceOver alike.
	@ViewBuilder
	private func moveButtons(
		_ rule: ProxyLinkRule,
		index: Int
	) -> some View {
		ForEach(RuleMove.allCases, id: \.self) { move in
			if let destination = move.destination(from: index, among: store.proxyLinkRules.count) {
				Button(move.title) { send(.move(rule.id, to: destination)) }
			}
		}
	}

	/// The handle that drags a rule to another place in the list. Not an accessibility element:
	/// the row's own move actions do the same for VoiceOver.
	private func dragHandle(_ rule: ProxyLinkRule) -> some View {
		Image(systemName: "line.3.horizontal")
			.foregroundStyle(.secondary)
			.frame(width: 20, height: 24)
			.contentShape(.rect)
			.pointerStyle(drag == nil ? .grabIdle : .grabActive)
			.help(String.localized(.appUI.links.reorderHelp))
			.accessibilityHidden(true)
			.gesture(moveGesture(rule.id))
	}

	private func moveGesture(_ id: UUID) -> some Gesture {
		DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.coordinateSpace))
			.onChanged { value in

				// A drag whose rule sync removed mid-gesture never ended: this one starts afresh.
				if drag?.id != id {
					let ids: [UUID] = store.proxyLinkRules.map(\.id)
					drag = RuleDrag(id: id, in: ids, frames: ids.map { rowFrames[$0] ?? .zero })
				}
				drag?.track(y: value.location.y)
			}
			.onEnded { _ in
				guard let drag else { return }
				var transaction = Transaction()
				transaction.disablesAnimations = true
				withTransaction(transaction) {
					if let destination = drag.destination(in: store.proxyLinkRules.map(\.id)) {
						send(.move(drag.id, to: destination))
					}
					self.drag = nil
				}
			}
	}

	private nonisolated static let coordinateSpace: String = "proxyLinkRules"

	private func send(_ action: ProxyLinksEditor.Action) {
		store.send(.ui(.proxyLinks(action)))
	}
}

/// A Proxy Links rule moved one place from the keyboard, its menu or VoiceOver (DEV-1163).
internal enum RuleMove: CaseIterable, Hashable, Sendable {
	case up
	case down

	/// ⌥⌘↑ or ⌥⌘↓; nil for any other key or modifiers, so plain arrows still move the focus. An
	/// arrow key also reports the numeric pad and function flags, which don't count.
	internal init?(
		key: KeyEquivalent,
		modifiers: EventModifiers
	) {
		guard modifiers.intersection([.command, .option, .control, .shift]) == [.command, .option] else { return nil }

		switch key {
		case .upArrow: self = .up
		case .downArrow: self = .down
		default: return nil
		}
	}

	internal var title: String {
		switch self {
		case .up: String.localized(.appUI.links.moveUp)
		case .down: String.localized(.appUI.links.moveDown)
		}
	}

	/// Where the rule at `index` of `count` rules goes; nil at the end it would leave.
	internal func destination(
		from index: Int,
		among count: Int
	) -> Int? {
		let destination: Int = switch self {
		case .up: index - 1
		case .down: index + 1
		}
		let rules: Range<Int> = 0..<count
		return rules.contains(index) && rules.contains(destination) ? destination : nil
	}
}

/// A Proxy Links rule being dragged by its handle: where it started and the slot it would drop into.
internal struct RuleDrag: Equatable, Sendable {
	internal let id: UUID
	internal let origin: Int
	internal private(set) var slot: Int

	/// The rows' frames, in list order, when the drag began, so the preview's moves don't move the
	/// slots.
	private let frames: [CGRect]

	internal init?(
		id: UUID,
		in order: [UUID],
		frames: [CGRect]
	) {
		guard let origin = order.firstIndex(of: id), frames.count == order.count else { return nil }
		self.id = id
		self.origin = origin
		self.slot = origin
		self.frames = frames
	}

	/// Moves the slot to the one under `y`: past every other row whose middle is above it.
	internal mutating func track(y: CGFloat) {
		slot = frames.indices
			.filter { $0 != origin && frames[$0].midY < y }
			.count
	}

	/// The slot in a list of `count` rules, which sync may have shortened since the drag began:
	/// the last one at most, as the preview shows it.
	internal func slot(among count: Int) -> Int {
		max(0, min(slot, count - 1))
	}

	/// Where the drop moves the rule in `order`, the rules as they are now; nil when it stays where
	/// it is or is gone.
	internal func destination(in order: [UUID]) -> Int? {
		guard let index = order.firstIndex(of: id) else { return nil }

		let destination = slot(among: order.count)
		return destination == index ? nil : destination
	}
}

/// A Proxy Links rule's form, in the shared modal style: Name, Source hosts and the destination
/// template, a link to test the rule on, and Cancel (Esc) and Save (↩). Save stays disabled until
/// the rule is valid. A saved rule's form also has Delete.
internal struct ProxyLinkEditorView: View {
	internal let store: StoreOf<SettingsFeature>

	internal init(store: StoreOf<SettingsFeature>) {
		self.store = store
	}

	private var editor: ProxyLinksEditor {
		store.proxyLinkEditor ?? .init()
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(localized: editor.isNew ? .appUI.links.newRule : .appUI.links.editRule)
				.font(.title2.bold())
				.accessibilityAddTraits(.isHeader)
			VStack(alignment: .leading, spacing: 10) {
				SettingsTextField(
					String.localized(.appUI.common.name),
					text: field(\.name),
					prompt: String.localized(.appUI.settings.example.proxyName)
				)
				SettingsTextField(
					String.localized(.appUI.links.sourceHosts),
					text: field(\.sourceHosts),
					prompt: String.localized(.appUI.settings.example.hosts)
				)
				SettingsFieldFrame(String.localized(.appUI.links.destinationTemplate)) {
					TemplateField(
						String.localized(.appUI.settings.example.proxyTemplate),
						text: field(\.destinationTemplate),
						placeholders: [.subdomain, .host, .path, .query, .fragment],
						isBordered: false,
						label: String.localized(.appUI.links.destinationTemplate)
					)
				}
				Text(localized: .appUI.links.templateHelp)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
					.fixedSize(horizontal: false, vertical: true)
			}
			if let error = editor.error {
				Text(linkErrorMessage(error))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			tester
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				if let id = editor.editingID {
					ArxModalButton(
						String.localized(.appUI.links.deleteRule),
						prominence: .destructive,
						key: nil
					) {
						send(.delete(id))
					}
				}
				Spacer()
				ArxModalButton.cancel { send(.cancel) }
				ArxModalButton(String.localized(.appUI.common.save)) { send(.save) }
					.disabled(!editor.isValid)
			}
		}
		.font(SettingsTypography.body)
		.padding(24)
		.frame(width: 520)
		.arxModalSheet()
		.settingsControls()
	}

	/// Test a link: what this rule, as typed, and Copy Clean Link make of it.
	private var tester: some View {
		VStack(alignment: .leading, spacing: 8) {
			SettingsTextField(
				String.localized(.appUI.links.testURL),
				text: field(\.testURL),
				prompt: String.localized(.appUI.links.testURLPlaceholder)
			)
			Text(localized: .appUI.links.testHelp)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			if !editor.testURL.isEmpty {
				if let url = URL(string: editor.testURL, encodingInvalidCharacters: false) {
					let item = LinkCopyItem(title: "", url: url)
					testResult(
						String.localized(.appUI.links.draftRule),
						result: draftResult(item)
					)
					testResult(
						String.localized(.appUI.links.copyClean),
						result: LinkTransformer.clean(item)
					)

				} else {
					Text(linkErrorMessage(.invalidURL))
						.font(SettingsTypography.caption)
						.foregroundStyle(.red)
				}
			}
		}
	}

	private func testResult(
		_ label: String,
		result: LinkTransformation
	) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(label).font(.callout.bold())
			Text(linkTransformationMessage(result.outcome)).foregroundStyle(.secondary)
			Text(result.output.absoluteString)
				.font(.caption.monospaced())
				.textSelection(.enabled)
		}
	}

	private func draftResult(_ item: LinkCopyItem) -> LinkTransformation {
		let rule = editor.draftRule
		do {
			try rule.validate()
			return LinkTransformer.proxy(item, rules: [rule])

		} catch {
			return .init(
				original: item,
				output: item.url,
				outcome: .preserved(error as? LinkTransformationError ?? .invalidRule)
			)
		}
	}

	private func send(_ action: ProxyLinksEditor.Action) {
		store.send(.ui(.proxyLinks(action)))
	}

	private func field(_ path: WritableKeyPath<ProxyLinksEditor, String>) -> Binding<String> {
		Binding(
			get: { editor[keyPath: path] },
			set: { value in
				var next = editor
				next[keyPath: path] = value
				send(.changed(next))
			}
		)
	}
}
