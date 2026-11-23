import SwiftUI

/// The pill at the top of a page an MCP client is acting on: "Claude Code is controlling this
/// page · Stop" (DEV-899). After Stop it reads "… is stopped · Resume" until it fades.
///
/// It hides itself at `fadesAt`; nil keeps it up while the client is still acting.
public struct AgentPresencePill: View {
	private let clientName: String
	private let isStopped: Bool
	private let fadesAt: Date?
	private let onStop: () -> Void
	private let onResume: () -> Void

	@SwiftUI.State
	private var isFaded: Bool

	public init(
		clientName: String,
		isStopped: Bool,
		fadesAt: Date?,
		onStop: @escaping () -> Void,
		onResume: @escaping () -> Void
	) {
		self.clientName = clientName
		self.isStopped = isStopped
		self.fadesAt = fadesAt
		self.onStop = onStop
		self.onResume = onResume
		self._isFaded = .init(initialValue: fadesAt.map { $0 <= Date() } ?? false)
	}

	public var body: some View {
		ZStack(alignment: .top) {
			if !isFaded {
				pill
					.padding(.top, ArxToastMetrics.edgeInset)
					.transition(.opacity.combined(with: .move(edge: .top)))
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
		.animation(.easeOut(duration: 0.2), value: isFaded)
		.task(id: FadeKey(fadesAt: fadesAt, isStopped: isStopped)) {
			await fade(at: fadesAt) { isFaded = $0 }
		}
	}

	private var pill: some View {
		ArxToast(
			isStopped
			? String.localized(.appUI.automation.presenceStopped(clientName))
			: String.localized(.appUI.automation.presenceActing(clientName)),
			systemImage: isStopped ? "pause.circle" : "cursorarrow.rays"
		) {
			if isStopped {
				Button(action: onResume) {
					Text(localized: .appUI.automation.presenceResume).padding(.horizontal, 3)
				}
				.buttonStyle(.arxRaised(size: .small))
				.accessibilityIdentifier("agent-presence-resume")
			} else {
				Button(action: onStop) {
					Text(localized: .appUI.automation.presenceStop).padding(.horizontal, 3)
				}
				.buttonStyle(.arxRaised(size: .small))
				.help(String.localized(.appUI.automation.presenceStopHelp(clientName)))
				.accessibilityIdentifier("agent-presence-stop")
			}
		}
		.accessibilityIdentifier("agent-presence")
	}

	private struct FadeKey: Hashable {
		internal var fadesAt: Date?
		internal var isStopped: Bool
	}
}

/// The small badge on a sidebar row whose tab an MCP client is acting on (DEV-899).
public struct SidebarAgentBadge: View {
	private let agent: SidebarItem.Agent

	@SwiftUI.State
	private var isFaded: Bool

	public init(agent: SidebarItem.Agent) {
		self.agent = agent
		self._isFaded = .init(initialValue: agent.fadesAt.map { $0 <= Date() } ?? false)
	}

	public var body: some View {
		ZStack {
			if !isFaded {
				badge(
					symbol: "cursorarrow.rays",
					style: AnyShapeStyle(BrowserTheme.accent),
					label: String.localized(.appUI.automation.presenceBadge(agent.name))
				)
			} else if let opener = agent.openedBy {
				// Once nothing acts on it, a tab its client opened says so quietly (DEV-1022).
				badge(
					symbol: "sparkles",
					style: AnyShapeStyle(BrowserTheme.secondary),
					label: String.localized(.appUI.automation.openedByBadge(opener))
				)
			}
		}
		.animation(.easeOut(duration: 0.2), value: isFaded)
		.task(id: agent) {
			await fade(at: agent.fadesAt) { isFaded = $0 }
		}
	}
}

extension SidebarAgentBadge {
	private func badge(
		symbol: String,
		style: AnyShapeStyle,
		label: String
	) -> some View {
		Image(systemName: symbol)
			.font(.system(size: SidebarTabAudioMetrics.indicatorSymbolSize, weight: .semibold))
			.foregroundStyle(style)
			.frame(width: SidebarTabAudioMetrics.indicatorSize, height: SidebarTabAudioMetrics.indicatorSize)
			.transition(.opacity)
			.help(label)
			.accessibilityLabel(label)
			.accessibilityIdentifier("sidebar-agent-badge")
	}
}

/// Shows the indicator, then hides it at `date`. Nil keeps it shown.
@MainActor
private func fade(
	at date: Date?,
	_ setFaded: (Bool) -> Void
) async {
	guard let date else {
		setFaded(false)
		return
	}

	let delay = date.timeIntervalSinceNow
	guard delay > 0 else {
		setFaded(true)
		return
	}

	setFaded(false)
	try? await Task.sleep(for: .seconds(delay))
	guard !Task.isCancelled else { return }
	setFaded(true)
}
