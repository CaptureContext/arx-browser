import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserExtensionsClient
import Foundation
import TaskManagerFeature
import _ComposableArchitecture

/// Window ▸ Task Manager (DEV-898): composes the feature and names what each process runs.
@Reducer
internal struct AppTaskManager {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.browserExtensions)
	private var extensions

	internal var body: some ReducerOf<Self> {
		Scope(state: \.taskManager, action: \.taskManager) {
			TaskManagerFeature()
		}

		// Extension names for the rows, read once as the window opens.
		Pullback(\.taskManager.ui.present) { state in
			let profiles = state.workspace.profiles.map(\.id)
			return .run { [extensions] send in
				guard await MainActor.run(body: { extensions.availability() }) else { return }

				var names: [String: String] = [:]
				for profile in profiles {
					guard let inventory = try? await extensions.inspect(profile) else { continue }
					for item in inventory.extensions { names[item.id] = item.name }
				}
				await send(.taskManager(.event(.extensionNames(names))))
			}
		}
	}
}

extension AppFeature.State {
	/// The Task Manager's name for a process: Arx, the GPU process, a utility, or the tabs and
	/// extensions in a renderer.
	public func taskManagerTitle(for process: BrowserProcess) -> String {
		switch process.kind {
		case .browser:
			return String.localized(.appUI.taskManager.browser)
		case .gpu:
			return String.localized(.appUI.taskManager.gpu)
		case let .utility(name):
			return name.map { String.localized(.appUI.taskManager.utility($0)) }
			?? String.localized(.appUI.taskManager.utilityUnnamed)
		case let .other(type):
			return String.localized(.appUI.taskManager.helper(type))
		case .renderer:
			let names = process.owners.map(taskManagerTitle)
			return names.isEmpty
			? String.localized(.appUI.taskManager.spareRenderer)
			: names.formatted(.list(type: .and))
		}
	}

	private func taskManagerTitle(for owner: BrowserProcess.Owner) -> String {
		switch owner {
		case let .tab(id):
			let tab = workspace.tabs[id: id]
			?? windows.lazy.compactMap { $0.sidebar.organization.tabs[id: id] }.first
			?? littleWindows.first(where: { $0.tab.id == id })?.tab
			return String.localized(.appUI.taskManager.tab(tab?.displayTitle ?? ""))
		case .privateTab:
			// A private tab's title stays in its window.
			return String.localized(.appUI.taskManager.privateTab)
		case let .extensionID(id):
			return String.localized(.appUI.taskManager.extension(taskManager.extensionNames[id] ?? id))
		}
	}
}
