import AppUI
import BrowserCore
import ChatFeature
import OnboardingFeature
import SettingsFeature
import SwiftUI
import _ComposableArchitecture

internal struct AppSettingsView: View {
	internal let store: StoreOf<AppFeature>

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	internal var body: some View {
		SettingsView(
			store: store.scope(state: \.settings, action: \.settings),
			organization: store.workspace,
			shortcuts: BrowserCommand.settingsShortcuts(bindings: store.settings.keyboardShortcuts),
			openAutomation: { store.send(.automation(.ui(.present(true)))) },
			exportArchive: { store.send(.ui(.exportBrowserData(.archive))) },
			exportBookmarks: { store.send(.ui(.exportBrowserData(.bookmarks))) },
			browserDataExport: .init(
				includesHistory: store.browserDataExport.includesHistory,
				includesArchivedTabs: store.browserDataExport.includesArchivedTabs,
				progress: store.browserDataExport.progress?.fractionCompleted,
				setIncludesHistory: { store.send(.browserDataExport(.includesHistoryChanged($0))) },
				setIncludesArchivedTabs: { store.send(.browserDataExport(.includesArchivedTabsChanged($0))) },
				cancel: { store.send(.browserDataExport(.cancelTapped)) }
			),
			importData: { store.send(.ui(.openImport)) },
			agentSignInSites: store.automationPreferences.agentSignInSites,
			removeAgentSignInSite: { store.send(.automation(.ui(.removeAgentSignInSite($0)))) },
			onboardingSteps: OnboardingFlow.steps,
			openOnboarding: { step in
				if let step {
					store.send(.ui(.openOnboardingStep(step)))
				} else {
					store.send(.ui(.openOnboarding))
				}
			},
			assistant: AnyView(
				ChatSettingsView(
					stores: store.workspace.profiles.compactMap { profile in
						store.scope(state: \.chats[id: profile.id], action: \.chats[id: profile.id])
					},
					profiles: Array(store.workspace.profiles)
				)
				.onAppear { store.send(.chat(.settingsAppeared)) }
			),
			routingContext: .init(currentSpaceID: store.state.incomingSpaceID(), recentSpaceIDs: store.recentSpaceIDs)
		)
		.onChange(of: store.workspace.profiles, initial: true) { _, profiles in
			store.send(.settings(.configureExtensions(Array(profiles))))
		}
		.onDisappear { store.send(.settings(.extensions(.ui(.dismiss)))) }
		.sheet(
			isPresented: Binding(
				get: { store.automation.isPresented },
				set: { store.send(.automation(.ui(.present($0)))) }
			)
		) {
			AutomationSettingsView(store: store)
		}

		// Send Feedback asked from Settings stays on its window (DEV-1308).
		.modifier(SendFeedbackSheetPresentation(store: store, host: .settings))
		.overlay(alignment: .bottom) { WorkspaceRecoveryView(store: store) }
	}
}

extension BrowserCommand {
	/// Settings › Shortcuts lists every command, so each one can be rebound there (DEV-1014).
	internal static func settingsShortcuts(bindings: [ShortcutBinding]) -> [SettingsShortcut] {
		allCases.map { $0.settingsShortcut(bindings: bindings) }
	}

	internal func settingsShortcut(bindings: [ShortcutBinding]) -> SettingsShortcut {
		// Every shortcut the command has, the menu's first (DEV-920).
		let shortcuts = bindings.shortcuts(for: self)
		return .init(
			id: rawValue,
			title: title,
			keys: shortcuts.isEmpty
			? String.localized(.appUI.settings.shortcutNone)
			: shortcuts.map(\.display).joined(separator: ", "),
			searchTerms: shortcuts.map(\.searchTerms).joined(separator: " ")
		)
	}
}
