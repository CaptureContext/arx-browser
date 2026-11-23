import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// Air Traffic Control as a list of routes: which URLs, then where they open.
internal struct RoutingSettingsView: View {
	internal let store: StoreOf<SettingsFeature>
	internal let organization: BrowserOrganization
	internal let context: SettingsRoutingContext

	@Environment(\.settingsToolbarAdd)
	private var addsFromToolbar

	internal init(
		store: StoreOf<SettingsFeature>,
		organization: BrowserOrganization,
		context: SettingsRoutingContext = .init()
	) {
		self.store = store
		self.organization = organization
		self.context = context
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 22) {
			Text(localized: .appUI.routing.description)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			routes
			tester
		}

		// An unsaved New Route lasts as long as the page, as it did in the view's own state.
		.onDisappear { send(.draftChanged(nil)) }
	}

	// MARK: - Routes

	private var routes: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(localized: .appUI.routing.routes)
					.font(.system(size: 13, weight: .semibold))
					.accessibilityAddTraits(.isHeader)
				Spacer()
				if !addsFromToolbar {
					Button(String.localized(.appUI.routing.newRoute), systemImage: "plus") {
						send(.newDraft)
					}
					.disabled(store.routingDraft != nil)
				}
			}
			.padding(.horizontal, 14)

			SettingsSection(
				content: {
					let rules = store.routingPreferences.rules
					ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
						RoutingRuleRow(
							rule: rule,
							organization: organization,
							error: store.routing.failedRuleID == rule.id ? store.routing.error : nil,
							canMoveUp: index > 0,
							canMoveDown: index < rules.count - 1,
							onChange: { send(.update($0, organization)) },
							onToggle: { send(.toggle(rule.id)) },
							onMove: { send(.move(rule.id, $0)) },
							onRemove: { send(.delete(rule.id)) }
						)
					}
					if let draft = store.routingDraft {
						RoutingRuleRow(
							rule: draft,
							organization: organization,
							error: store.routing.failedRuleID == draft.id ? store.routing.error : nil,
							isDraft: true,
							onChange: saveDraft,
							onRemove: { send(.draftChanged(nil)) }
						)
					}
					otherwise
				},
				footer: { Text(localized: .appUI.routing.patternHelp) }
			)
		}
	}

	/// Keeps the draft until its pattern names a host, then adds it; the list shows it once it's
	/// saved.
	private func saveDraft(_ rule: RoutingRule) {
		send(.draftChanged(rule))
		guard !rule.host.isEmpty else { return }
		send(.add(rule, organization))
	}

	/// Where links no route matches open, or Ask for a Destination.
	private var otherwise: some View {
		let fallback = store.routingPreferences.fallback
		return HStack(spacing: 8) {
			Image(systemName: "arrow.turn.down.right")
				.foregroundStyle(.secondary)
				.frame(width: 18)
				.accessibilityHidden(true)
			Text(localized: .appUI.routing.otherwise)
			Spacer(minLength: 12)

			// Ask is stored as no fallback, as before.
			RoutingSpaceMenu(organization: organization, scope: fallback?.scope ?? .ask) { scope in
				send(.fallbackChanged(scope == .ask ? nil : .init(scope: scope, mode: fallback?.mode ?? .mainBrowser)))
			}
			if let fallback, fallback.scope != .ask {
				RoutingWindowPicker(mode: fallback.mode) { mode in
					send(.fallbackChanged(.init(scope: fallback.scope, mode: mode)))
				}
			}
		}
		.padding(.vertical, 10)
	}

	// MARK: - Tester

	private var tester: some View {
		VStack(alignment: .leading, spacing: 8) {
			SettingsTextField(
				String.localized(.appUI.links.testURL),
				text: Binding(
					get: { store.routing.testURL },
					set: { value in
						var editor = store.routing
						editor.testURL = value
						send(.changed(editor))
					}
				),
				prompt: String.localized(.appUI.links.testURLPlaceholder)
			)
			Text(localized: .appUI.routing.testerHelp).font(.caption).foregroundStyle(.secondary)
			if !store.routing.testURL.isEmpty {
				if let url = URL(string: store.routing.testURL, encodingInvalidCharacters: false) {
					let decision = URLRouter.decide(
						url,
						preferences: store.routingPreferences,
						organization: organization,
						currentSpaceID: context.currentSpaceID ?? organization.spaces.first?.id,
						recentSpaceIDs: context.recentSpaceIDs
					)
					Text(matchedRuleName(decision.matchedRuleID) ?? String.localized(.appUI.routing.otherwise))
					switch decision.result {
					case let .success(target):
						let destination = RoutingDestination(scope: .space(target.spaceID), mode: target.mode)
						Text(destination.routingTitle(in: organization))

					case let .failure(error):
						Text(routingErrorMessage(error)).foregroundStyle(.red)
					}

				} else {
					Text(routingErrorMessage(.unsupportedURL)).foregroundStyle(.red)
				}
			}
		}
	}

	private func matchedRuleName(_ id: UUID?) -> String? {
		guard let id else { return nil }
		return store.routingPreferences.rules.first(where: { $0.id == id })?.name
	}

	private func send(_ action: RoutingEditor.Action) {
		store.send(.ui(.routing(action)))
	}
}

/// One route: `URL` with how it matches and its pattern, then `Open in` a space and a window.
private struct RoutingRuleRow: View {
	internal let rule: RoutingRule
	internal let organization: BrowserOrganization
	internal let error: URLRoutingError?
	internal var isDraft: Bool = false
	internal var canMoveUp: Bool = false
	internal var canMoveDown: Bool = false
	internal let onChange: (RoutingRule) -> Void
	internal var onToggle: () -> Void = {}
	internal var onMove: (Int) -> Void = { _ in }
	internal let onRemove: () -> Void

	@SwiftUI.State
	private var pattern: String

	@FocusState
	private var isPatternFocused: Bool

	internal init(
		rule: RoutingRule,
		organization: BrowserOrganization,
		error: URLRoutingError?,
		isDraft: Bool = false,
		canMoveUp: Bool = false,
		canMoveDown: Bool = false,
		onChange: @escaping (RoutingRule) -> Void,
		onToggle: @escaping () -> Void = {},
		onMove: @escaping (Int) -> Void = { _ in },
		onRemove: @escaping () -> Void
	) {
		self.rule = rule
		self.organization = organization
		self.error = error
		self.isDraft = isDraft
		self.canMoveUp = canMoveUp
		self.canMoveDown = canMoveDown
		self.onChange = onChange
		self.onToggle = onToggle
		self.onMove = onMove
		self.onRemove = onRemove
		self._pattern = .init(initialValue: rule.host.isEmpty ? "" : RoutingPattern.text(for: rule))
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Image(systemName: "link")
					.foregroundStyle(.secondary)
					.frame(width: 18)
					.accessibilityHidden(true)
				Text(localized: .appUI.routing.url)

				// Inside the rule's row, beside its field: Arx's dropdown, not a system pop-up.
				ArxDropdown(
					String.localized(.appUI.routing.url),
					selection: Binding(
						get: { rule.includesSubdomains },
						set: { change { $0.includesSubdomains = $1 }($0) }
					),
					options: [
						.init(id: false, title: String.localized(.appUI.routing.matchDomain)),
						.init(id: true, title: String.localized(.appUI.routing.matchSubdomains)),
					]
				)
				.fixedSize()
				patternField
				if !isDraft {
					Toggle(rule.name, isOn: Binding(get: { rule.isEnabled }, set: { _ in onToggle() }))
						.toggleStyle(.switch)
						.controlSize(.mini)
						.labelsHidden()
				}
				Button(action: onRemove) {
					Image(systemName: "minus.circle.fill")
						.foregroundStyle(.secondary)
				}
				.buttonStyle(.arx(.plain, size: .small))
				.help(String.localized(.appUI.routing.removeRoute))
				.accessibilityLabel(Text(localized: .appUI.routing.removeRoute))
			}
			HStack(spacing: 8) {
				Image(systemName: "arrow.turn.down.right")
					.foregroundStyle(.secondary)
					.frame(width: 18)
					.accessibilityHidden(true)
				Text(localized: .appUI.routing.openIn)

				// The menus trail, lined up with Otherwise's below the routes.
				Spacer(minLength: 12)
				RoutingSpaceMenu(organization: organization, scope: rule.destination.scope) { scope in
					change { $0.destination.scope = $1 }(scope)
				}

				// Asking chooses the window too, when the link arrives.
				if rule.destination.scope != .ask {
					RoutingWindowPicker(mode: rule.destination.mode) { mode in
						change { $0.destination.mode = $1 }(mode)
					}
				}
			}
			.padding(.leading, 26)
			if let error {
				Text(routingErrorMessage(error))
					.font(.caption)
					.foregroundStyle(.red)
					.padding(.leading, 26)
			}
		}
		.opacity(isDraft || rule.isEnabled ? 1 : 0.55)
		.padding(.vertical, 10)
		.contextMenu {
			if !isDraft {
				Button(String.localized(.appUI.routing.moveUp)) { onMove(-1) }
					.disabled(!canMoveUp)
				Button(String.localized(.appUI.routing.moveDown)) { onMove(1) }
					.disabled(!canMoveDown)
			}
			Button(String.localized(.appUI.routing.removeRoute), role: .destructive, action: onRemove)
		}
		.onChange(of: rule) { _, rule in
			if !isPatternFocused, !rule.host.isEmpty { pattern = RoutingPattern.text(for: rule) }
		}
	}

	/// Saved on Return or when it loses focus.
	private var patternField: some View {
		TextField(
			String.localized(.appUI.routing.url),
			text: $pattern,
			prompt: Text(localized: .appUI.routing.patternExample)
		)
		.textFieldStyle(.arx)
		.focused($isPatternFocused)
		.frame(maxWidth: .infinity)
		.onSubmit(commitPattern)
		.onChange(of: isPatternFocused) { _, focused in
			if !focused { commitPattern() }
		}
	}

	private func commitPattern() {
		let current = rule.host.isEmpty ? "" : RoutingPattern.text(for: rule)
		guard pattern != current else { return }
		guard let next = RoutingPattern.apply(pattern, to: rule) else {
			// Not a host: the draft stays; a saved route keeps its pattern.
			if !isDraft { pattern = current }
			return
		}
		onChange(next)
	}

	/// Applies one edit to the route and reports it.
	private func change<Value>(
		_ edit: @escaping (inout RoutingRule, Value) -> Void
	) -> (Value) -> Void {
		{ value in
			var next = rule
			edit(&next, value)
			onChange(next)
		}
	}
}

/// What decides a link's destination right now: the space in front and the spaces used before it.
/// AppFeature supplies it so Air Traffic Control's tester predicts what an incoming link does.
public struct SettingsRoutingContext: Equatable, Sendable {
	public var currentSpaceID: Space.ID?
	public var recentSpaceIDs: [Space.ID]

	public init(
		currentSpaceID: Space.ID? = nil,
		recentSpaceIDs: [Space.ID] = []
	) {
		self.currentSpaceID = currentSpaceID
		self.recentSpaceIDs = recentSpaceIDs
	}
}
