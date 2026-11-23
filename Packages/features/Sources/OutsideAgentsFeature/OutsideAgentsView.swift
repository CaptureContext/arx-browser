import AgentToolsClient
import AppUI
import BrowserAutomationClient
import SwiftUI
import _ComposableArchitecture

/// The command, the MCP switch and the agent apps, as one scrolling column.
///
/// Onboarding shows it inside its page layout and Settings inside the Local assistants
/// sheet. Every control is a standard button or toggle, so it works with the keyboard
/// and VoiceOver; the review of an app's change is a sheet with Cancel on Escape.
public struct OutsideAgentsView: View {
	public let store: StoreOf<OutsideAgents>

	public init(store: StoreOf<OutsideAgents>) {
		self.store = store
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			toolSection
			Divider()
			mcpSection
			Divider()
			agentsSection
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.task { store.send(.ui(.task)) }
		.sheet(
			isPresented: Binding(
				get: { store.reviewedApp != nil },
				set: { isPresented in
					if !isPresented {
						store.send(.ui(.cancelReview))
					}
				}
			)
		) {
			if let app = store.reviewedApp, let change = app.change {
				OutsideAgentsReview(
					app: app,
					change: change,
					add: { store.send(.ui(.confirmAdd)) },
					cancel: { store.send(.ui(.cancelReview)) }
				)
			}
		}
	}

	// MARK: - Command-line tool

	private var toolSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(alignment: .firstTextBaseline, spacing: 12) {
				VStack(alignment: .leading, spacing: 2) {
					Text(localized: .appUI.outsideAgents.tool.title)
						.font(.headline)
						.accessibilityAddTraits(.isHeader)
					Text(localized: .appUI.outsideAgents.tool.detail)
						.foregroundStyle(.secondary)
					if let status = toolStatusText {
						Text(status)
							.foregroundStyle(store.toolFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
					}
				}
				.font(.callout)
				.accessibilityElement(children: .combine)

				Spacer(minLength: 12)
				toolButtons
			}

			if store.isToolInstalled, store.tool?.isOnPath != true, let tool = store.tool {
				pathAdvice(tool)
			}
		}
	}

	@ViewBuilder
	private var toolButtons: some View {
		if store.toolActivity != nil {
			ProgressView()
				.controlSize(.small)
				.accessibilityLabel(Text(localized: .appUI.outsideAgents.tool.working))
		} else {
			switch store.tool?.installation {
			case .notInstalled:
				Button(String.localized(.appUI.outsideAgents.tool.install)) {
					store.send(.ui(.installTool))
				}

			case .outdated:
				HStack {
					Button(String.localized(.appUI.outsideAgents.tool.uninstall)) {
						store.send(.ui(.uninstallTool))
					}
					Button(String.localized(.appUI.outsideAgents.tool.update)) {
						store.send(.ui(.installTool))
					}
				}

			case .current:
				Button(String.localized(.appUI.outsideAgents.tool.uninstall)) {
					store.send(.ui(.uninstallTool))
				}

			case .unavailable, .blocked, nil:
				EmptyView()
			}
		}
	}

	private var toolStatusText: String? {
		if store.toolFailed {
			return String.localized(.appUI.outsideAgents.tool.failed)
		}

		guard let tool = store.tool
		else { return nil }

		return switch tool.installation {
		case .unavailable: String.localized(.appUI.outsideAgents.tool.unavailable)
		case .notInstalled: String.localized(.appUI.outsideAgents.tool.notInstalled)
		case .current: String.localized(.appUI.outsideAgents.tool.installed(tool.location))
		case .outdated: String.localized(.appUI.outsideAgents.tool.outdated(tool.location))
		case .blocked: String.localized(.appUI.outsideAgents.tool.blocked(tool.location))
		}
	}

	private func pathAdvice(_ tool: CommandLineToolClient.Status) -> some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(
				localized: tool.isOnPath == false
				? .appUI.outsideAgents.path.missing(tool.pathAdvice.profile)
				: .appUI.outsideAgents.path.unknown(tool.pathAdvice.profile)
			)
			.font(.callout)
			.foregroundStyle(.secondary)
			.fixedSize(horizontal: false, vertical: true)

			OutsideAgentsSnippet(text: tool.pathAdvice.line) {
				store.send(.ui(.copy(tool.pathAdvice.line)))
			}
		}
	}

	// MARK: - MCP

	private var mcpSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Toggle(
				isOn: Binding(
					get: { store.mcp == .on || store.mcp == .starting },
					set: { store.send(.ui(.setMCPEnabled($0))) }
				)
			) {
				VStack(alignment: .leading, spacing: 2) {
					Text(localized: .appUI.outsideAgents.mcp.toggle)
						.font(.headline)
					Text(mcpStatusText)
						.font(.callout)
						.foregroundStyle(store.mcp == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
				}
			}
			.toggleStyle(.switch)

			VStack(alignment: .leading, spacing: 4) {
				Text(localized: .appUI.outsideAgents.permissions.title)
					.font(.callout.weight(.semibold))
				ForEach(Self.permissions, id: \.self) { permission in
					Label {
						Text(permission)
							.fixedSize(horizontal: false, vertical: true)
					} icon: {
						Image(systemName: "checkmark.shield")
							.foregroundStyle(.secondary)
							.accessibilityHidden(true)
					}
					.font(.callout)
				}
			}
			.accessibilityElement(children: .combine)
		}
	}

	private static var permissions: [String] {
		[
			String.localized(.appUI.outsideAgents.permissions.scope),
			String.localized(.appUI.outsideAgents.permissions.read),
			String.localized(.appUI.outsideAgents.permissions.change),
			String.localized(.appUI.outsideAgents.permissions.destructive),
		]
	}

	private var mcpStatusText: String {
		switch store.mcp {
		case .off: String.localized(.appUI.outsideAgents.mcp.off)
		case .starting: String.localized(.appUI.outsideAgents.mcp.starting)
		case .on: String.localized(.appUI.outsideAgents.mcp.on)
		case .failed: String.localized(.appUI.outsideAgents.mcp.failed)
		}
	}

	// MARK: - Agent apps

	private var agentsSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(localized: .appUI.outsideAgents.agents.title)
				.font(.headline)
				.accessibilityAddTraits(.isHeader)

			switch store.addBlocker {
			case .needsTool:
				Text(localized: .appUI.outsideAgents.agents.needsTool)
					.font(.callout)
					.foregroundStyle(.secondary)

			case .needsMCP:
				Text(localized: .appUI.outsideAgents.agents.needsSwitch)
					.font(.callout)
					.foregroundStyle(.secondary)

			case nil:
				EmptyView()
			}

			if let apps = store.apps {
				ForEach(apps) { app in
					OutsideAgentsAppRow(
						app: app,
						status: status(of: app),
						canAdd: store.addBlocker == nil && store.adding == nil,
						add: { store.send(.ui(.review(app.agent))) },
						copySetup: { store.send(.ui(.copy(app.snippet))) }
					)
				}
			} else {
				Text(localized: .appUI.outsideAgents.agents.checking)
					.font(.callout)
					.foregroundStyle(.secondary)
			}
		}
	}

	private func status(of app: AgentApp) -> String {
		if store.adding == app.agent {
			return String.localized(.appUI.outsideAgents.agent.adding)
		}

		if store.failedAgent == app.agent {
			return String.localized(.appUI.outsideAgents.agent.failed)
		}

		if app.isConfigured {
			return String.localized(.appUI.outsideAgents.agent.added)
		}

		return app.isInstalled
		? String.localized(.appUI.outsideAgents.agent.found)
		: String.localized(.appUI.outsideAgents.agent.notFound)
	}
}

// MARK: - Rows

private struct OutsideAgentsAppRow: View {
	internal let app: AgentApp
	internal let status: String
	internal let canAdd: Bool
	internal let add: () -> Void
	internal let copySetup: () -> Void

	internal var body: some View {
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text(verbatim: app.agent.title)
				Text(status)
					.font(.callout)
					.foregroundStyle(.secondary)
			}
			.accessibilityElement(children: .combine)

			Spacer(minLength: 12)

			Button(String.localized(.appUI.outsideAgents.agent.copySetup), action: copySetup)
				.accessibilityLabel(Text(localized: .appUI.outsideAgents.agent.copySetupLabel(app.agent.title)))
				.help(app.snippet)

			if app.isInstalled, app.change != nil {
				Button(
					app.isConfigured
					? String.localized(.appUI.outsideAgents.agent.addAgain)
					: String.localized(.appUI.outsideAgents.agent.add),
					action: add
				)
				.disabled(!canAdd)
				.accessibilityLabel(Text(localized: .appUI.outsideAgents.agent.addLabel(app.agent.title)))
			}
		}
		.opacity(app.isInstalled ? 1 : 0.7)
	}
}

/// A line of monospaced text a person can select or copy.
private struct OutsideAgentsSnippet: View {
	internal let text: String
	internal let copy: () -> Void

	internal var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Text(verbatim: text)
				.font(.callout.monospaced())
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.fixedSize(horizontal: false, vertical: true)

			Button(String.localized(.appUI.outsideAgents.copy)) {
				copy()
				AccessibilityNotification.Announcement(String.localized(.appUI.outsideAgents.copied)).post()
			}
		}
		.padding(8)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
	}
}

/// The exact file and change, shown before anything is written.
private struct OutsideAgentsReview: View {
	internal let app: AgentApp
	internal let change: AgentApp.Change
	internal let add: () -> Void
	internal let cancel: () -> Void

	internal var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(localized: .appUI.outsideAgents.review.title(app.agent.title))
				.font(.title3.weight(.semibold))
				.accessibilityAddTraits(.isHeader)

			switch change {
			case let .command(line, file):
				Text(localized: .appUI.outsideAgents.review.command(file))
				changeText(line)

			case let .file(path, entry):
				Text(localized: .appUI.outsideAgents.review.file(path))
				changeText(entry)
			}

			Text(localized: .appUI.outsideAgents.review.kept)
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)

			HStack {
				Spacer()
				Button(String.localized(.appUI.outsideAgents.review.cancel), action: cancel)
					.keyboardShortcut(.cancelAction)
				Button(String.localized(.appUI.outsideAgents.review.add), action: add)
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(20)
		.frame(width: 520)
	}

	private func changeText(_ text: String) -> some View {
		ScrollView {
			Text(verbatim: text)
				.font(.callout.monospaced())
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(8)
		}
		.frame(maxHeight: 180)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
	}
}
