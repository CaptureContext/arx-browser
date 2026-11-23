import BrowserCore
import Foundation
import _ComposableArchitecture

public struct RoutingEditor: Equatable, Sendable {
	public var name: String
	public var host: String
	public var includesSubdomains: Bool
	public var scheme: String
	public var port: String
	public var pathPrefix: String
	public var destination: RoutingDestination
	public var editingID: UUID?
	public var testURL: String
	public var error: URLRoutingError?

	/// The route whose last change was refused, so its row shows `error`.
	public var failedRuleID: UUID?

	public init(
		name: String = "",
		host: String = "",
		includesSubdomains: Bool = false,
		scheme: String = "",
		port: String = "",
		pathPrefix: String = "",
		destination: RoutingDestination = .init(scope: .currentSpace),
		editingID: UUID? = nil,
		testURL: String = "",
		error: URLRoutingError? = nil,
		failedRuleID: UUID? = nil
	) {
		self.name = name
		self.host = host
		self.includesSubdomains = includesSubdomains
		self.scheme = scheme
		self.port = port
		self.pathPrefix = pathPrefix
		self.destination = destination
		self.editingID = editingID
		self.testURL = testURL
		self.error = error
		self.failedRuleID = failedRuleID
	}

	public func rule(id: UUID) throws -> RoutingRule {
		guard port.isEmpty || Int(port) != nil
		else { throw URLRoutingError.invalidDefinition }

		let rule: RoutingRule = .init(
			id: id,
			name: name,
			host: host,
			includesSubdomains: includesSubdomains,
			scheme: scheme.isEmpty ? nil : scheme,
			port: Int(port),
			pathPrefix: pathPrefix.isEmpty ? nil : pathPrefix,
			destination: destination
		)
		try rule.validate()
		return rule
	}

	@CasePathable
	public enum Action: Sendable {
		case changed(RoutingEditor)
		case edit(UUID)
		case delete(UUID)
		case move(UUID, Int)
		case newRule
		case save(BrowserOrganization)
		case toggle(UUID)
		case fallbackChanged(RoutingDestination?)

		/// The builder's New Route: added at the end with an ID of its own.
		case add(RoutingRule, BrowserOrganization)

		/// A route changed in place in the builder.
		case update(RoutingRule, BrowserOrganization)

		/// New Route, from the list or the bar: an empty route at the end of the list, until its
		/// pattern names a host.
		case newDraft

		/// The draft edited, or removed with nil.
		case draftChanged(RoutingRule?)
	}
}

/// A route's pattern as one line: an optional `scheme://`, the host, an optional `:port` and
/// path prefix, such as `localhost:3000` or `github.com/capturecontext`.
public enum RoutingPattern {
	public static func text(for rule: RoutingRule) -> String {
		var text = rule.scheme.map { $0 + "://" } ?? ""

		// An IPv6 address keeps its brackets, so the port and path after it still read.
		text += rule.host.contains(":") ? "[" + rule.host + "]" : rule.host
		if let port = rule.port { text += ":" + String(port) }
		return text + (rule.pathPrefix ?? "")
	}

	/// `rule` matching `text`, or `nil` when `text` isn't a host with an optional port and path.
	public static func apply(
		_ text: String,
		to rule: RoutingRule
	) -> RoutingRule? {
		let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
		let hasScheme = text.contains("://")
		guard
			!text.isEmpty,
			let url = URL(string: hasScheme ? text : "https://" + text, encodingInvalidCharacters: true),
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let host = url.host(percentEncoded: false),
			!host.isEmpty,
			components.query == nil,
			components.fragment == nil
		else { return nil }

		var rule = rule
		rule.name = text
		rule.host = host
		rule.scheme = hasScheme ? components.scheme?.lowercased() : nil
		rule.port = components.port
		let path = components.percentEncodedPath
		rule.pathPrefix = path.isEmpty || path == "/" ? nil : path
		return rule
	}
}

@Reducer
internal struct SettingsRouting {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	@Dependency(\.uuid)
	private var uuid

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.routing.changed) { state, editor in
			state.routing = editor
			state.routing.error = nil
			return .none
		}

		Pullback(\.ui.routing.newRule) { state in
			state.routing = .init(testURL: state.routing.testURL)
			return .none
		}

		Pullback(\.ui.routing.edit) { state, id in
			guard let rule = state.routingPreferences.rules.first(where: { $0.id == id })
			else { return .none }

			state.routing = .init(
				name: rule.name,
				host: rule.host,
				includesSubdomains: rule.includesSubdomains,
				scheme: rule.scheme ?? "",
				port: rule.port.map(String.init) ?? "",
				pathPrefix: rule.pathPrefix ?? "",
				destination: rule.destination,
				editingID: rule.id,
				testURL: state.routing.testURL
			)
			return .none
		}

		// Routing is a shared key: AppFeature saves its edits. Every write is validated first.
		Pullback(\.ui.routing.save) { state, organization in
			do {
				var rule = try state.routing.rule(id: state.routing.editingID ?? uuid())
				if rule.destination.scope != .ask {
					_ = try URLRouter.resolve(
						rule.destination,
						preferences: state.routingPreferences,
						organization: organization,
						currentSpaceID: organization.spaces.first?.id
					)
				}
				var routing = state.routingPreferences
				if let index = routing.rules.firstIndex(where: { $0.id == rule.id }) {
					rule.isEnabled = routing.rules[index].isEnabled
					routing.rules[index] = rule
				} else {
					routing.rules.append(rule)
				}
				try routing.validate()
				state.$routingPreferences.withLock { $0 = routing }
				state.routing = .init(testURL: state.routing.testURL)
				return .none

			} catch {
				state.routing.error = error as? URLRoutingError ?? .invalidDefinition
				return .none
			}
		}

		Pullback(\.ui.routing.newDraft) { state in
			guard state.routingDraft == nil else { return .none }

			state.routingDraft = .init(
				id: uuid(),
				name: "",
				host: "",
				includesSubdomains: true,
				destination: .init(scope: .currentSpace, mode: .mainBrowser)
			)
			return .none
		}

		Pullback(\.ui.routing.draftChanged) { state, draft in
			state.routingDraft = draft
			return .none
		}

		Pullback(\.ui.routing.add) { state, value in
			let (draft, organization) = value
			var rule = draft
			rule.id = uuid()
			let effect = save(rule, in: &state, organization: organization)

			// A refused draft keeps its error on the draft's own row; a saved one leaves the list
			// to show it.
			if state.routing.failedRuleID == rule.id {
				state.routing.failedRuleID = draft.id
			} else if state.routingDraft?.id == draft.id {
				state.routingDraft = nil
			}
			return effect
		}

		Pullback(\.ui.routing.update) { state, value in
			let (rule, organization) = value
			return save(rule, in: &state, organization: organization)
		}

		Pullback(\.ui.routing.delete) { state, id in
			state.$routingPreferences.withLock { $0.rules.removeAll { $0.id == id } }
			if state.routing.editingID == id {
				state.routing = .init(testURL: state.routing.testURL)
			}
			return .none
		}

		Pullback(\.ui.routing.toggle) { state, id in
			guard let index = state.routingPreferences.rules.firstIndex(where: { $0.id == id })
			else { return .none }

			state.$routingPreferences.withLock { $0.rules[index].isEnabled.toggle() }
			return .none
		}

		Pullback(\.ui.routing.move) { state, value in
			let (id, offset) = value
			guard
				let index = state.routingPreferences.rules.firstIndex(where: { $0.id == id }),
				offset == -1 || offset == 1,
				state.routingPreferences.rules.indices.contains(index + offset)
			else { return .none }

			state.$routingPreferences.withLock { $0.rules.swapAt(index, index + offset) }
			return .none
		}

		Pullback(\.ui.routing.fallbackChanged) { state, destination in
			var routing = state.routingPreferences
			routing.fallback = destination
			do {
				try routing.validate()
			} catch {
				state.routing.error = error as? URLRoutingError ?? .invalidDefinition
				return .none
			}
			state.$routingPreferences.withLock { $0 = routing }
			return .none
		}
	}

	/// Validates `rule` and its destination, then adds it or replaces the route with its ID.
	private func save(
		_ rule: RoutingRule,
		in state: inout State,
		organization: BrowserOrganization
	) -> Effect<Action> {
		do {
			try rule.validate()

			// Ask has no space to check: the person picks one when a link arrives.
			if rule.destination.scope != .ask {
				_ = try URLRouter.resolve(
					rule.destination,
					preferences: state.routingPreferences,
					organization: organization,
					currentSpaceID: organization.spaces.first?.id
				)
			}
			var routing = state.routingPreferences
			if let index = routing.rules.firstIndex(where: { $0.id == rule.id }) {
				routing.rules[index] = rule
			} else {
				routing.rules.append(rule)
			}
			try routing.validate()
			state.$routingPreferences.withLock { $0 = routing }
			state.routing.error = nil
			state.routing.failedRuleID = nil
		} catch {
			state.routing.error = error as? URLRoutingError ?? .invalidDefinition
			state.routing.failedRuleID = rule.id
		}
		return .none
	}
}
