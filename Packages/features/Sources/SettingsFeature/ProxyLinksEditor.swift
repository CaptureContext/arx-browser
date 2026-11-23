import BrowserCore
import Foundation
import _ComposableArchitecture

/// The Proxy Links rule form (DEV-767): a new rule, or a saved one being edited, with a link to
/// test it on. Settings › Links presents it as a sheet while `SettingsFeature.State.proxyLinkEditor`
/// holds one.
public struct ProxyLinksEditor: Equatable, Sendable {
	public var name: String
	public var sourceHosts: String
	public var destinationTemplate: String

	/// The saved rule being edited; nil for a new one.
	public var editingID: UUID?
	public var testURL: String
	public var error: LinkTransformationError?

	public init(
		name: String = "",
		sourceHosts: String = "",
		destinationTemplate: String = "",
		editingID: UUID? = nil,
		testURL: String = "",
		error: LinkTransformationError? = nil
	) {
		self.name = name
		self.sourceHosts = sourceHosts
		self.destinationTemplate = destinationTemplate
		self.editingID = editingID
		self.testURL = testURL
		self.error = error
	}

	/// The form for a saved rule.
	public init(rule: ProxyLinkRule) {
		self.init(
			name: rule.name,
			sourceHosts: rule.sourceHosts.joined(separator: ", "),
			destinationTemplate: rule.destinationTemplate,
			editingID: rule.id
		)
	}

	public var isNew: Bool {
		editingID == nil
	}

	/// The rule as typed, whether or not it's valid yet.
	public func rule(id: UUID) -> ProxyLinkRule {
		.init(
			id: id,
			name: name,
			sourceHosts: sourceHosts.split(separator: ",", omittingEmptySubsequences: false)
				.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) },
			destinationTemplate: destinationTemplate
		)
	}

	/// The rule as typed, under a stand-in id when it's new, for validating and testing it.
	public var draftRule: ProxyLinkRule {
		rule(id: editingID ?? Self.draftID)
	}

	/// Whether the rule as typed is one Save would keep: a name, hosts and a template that all
	/// validate. Save stays disabled until it is.
	public var isValid: Bool {
		do {
			try draftRule.validate()
			return true
		} catch {
			return false
		}
	}

	private static let draftID: UUID = .init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

	@CasePathable
	public enum Action: Sendable {
		case changed(ProxyLinksEditor)

		/// Opens the form for a saved rule.
		case edit(UUID)

		/// Removes a saved rule, closing its form if it's open. A default rule is remembered as
		/// deleted, so no Mac offers it again until Restore Default Links (DEV-1113).
		case delete(UUID)

		/// Moves a rule to an index in the list: of the enabled rules that match a link, the first
		/// one wins. The rows' drag handles and VoiceOver's move actions send it (DEV-1113).
		case move(UUID, to: Int)

		/// Opens an empty form.
		case newRule

		/// Closes the form without saving.
		case cancel

		/// Validates the form's rule, saves it and closes the form.
		case save
		case toggle(UUID)

		/// Brings back Arx's default rules as they ship, keeping the person's own (DEV-1003), and
		/// forgets which were deleted (DEV-1113).
		case restoreDefaults
	}
}

@Reducer
internal struct SettingsProxyLinks {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.proxyLinks.changed) { state, editor in
			guard state.proxyLinkEditor != nil else { return .none }

			state.proxyLinkEditor = editor
			state.proxyLinkEditor?.error = nil
			return .none
		}

		Pullback(\.ui.proxyLinks.newRule) { state in
			state.proxyLinkEditor = .init()
			return .none
		}

		Pullback(\.ui.proxyLinks.edit) { state, id in
			guard let rule = state.proxyLinkRules.first(where: { $0.id == id })
			else { return .none }

			state.proxyLinkEditor = .init(rule: rule)
			return .none
		}

		Pullback(\.ui.proxyLinks.cancel) { state in
			state.proxyLinkEditor = nil
			return .none
		}

		// Proxy Link rules are a shared key: AppFeature saves their edits. Every write is validated first.
		Pullback(\.ui.proxyLinks.save) { state in
			guard let editor = state.proxyLinkEditor else { return .none }

			var rule = editor.rule(id: editor.editingID ?? uuid())
			var rules = state.proxyLinkRules
			if let index = rules.firstIndex(where: { $0.id == rule.id }) {
				rule.isEnabled = rules[index].isEnabled
				rules[index] = rule
			} else {
				rules.append(rule)
			}
			do {
				try BrowserPreferences(proxyLinkRules: rules).validate()
			} catch {
				state.proxyLinkEditor?.error = error as? LinkTransformationError ?? .invalidRule
				return .none
			}
			state.$proxyLinkRules.withLock { $0 = rules }
			state.proxyLinkEditor = nil
			return .none
		}

		Pullback(\.ui.proxyLinks.delete) { state, id in

			// The form closes even when sync already took the rule away.
			if state.proxyLinkEditor?.editingID == id {
				state.proxyLinkEditor = nil
			}
			guard state.proxyLinkRules.contains(where: { $0.id == id }) else { return .none }

			// Recorded first: should the rule's removal not be saved, it's still there to delete again.
			state.$removedProxyLinkDefaults.withLock { $0 = ProxyLinkRule.removedDefaults($0, deleting: id) }
			state.$proxyLinkRules.withLock { $0.removeAll { $0.id == id } }
			return .none
		}

		Pullback(\.ui.proxyLinks.restoreDefaults) { state in
			state.$proxyLinkRules.withLock { $0 = ProxyLinkRule.restoringDefaults($0) }
			state.$removedProxyLinkDefaults.withLock { $0 = [] }
			return .none
		}

		Pullback(\.ui.proxyLinks.toggle) { state, id in
			guard let index = state.proxyLinkRules.firstIndex(where: { $0.id == id })
			else { return .none }

			state.$proxyLinkRules.withLock { $0[index].isEnabled.toggle() }
			return .none
		}

		Pullback(\.ui.proxyLinks.move) { state, value in
			let (id, destination) = value
			guard
				let index = state.proxyLinkRules.firstIndex(where: { $0.id == id }),
				state.proxyLinkRules.indices.contains(destination),
				destination != index
			else { return .none }

			state.$proxyLinkRules.withLock { rules in
				let rule = rules.remove(at: index)
				rules.insert(rule, at: destination)
			}
			return .none
		}
	}
}
