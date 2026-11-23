import AppUI
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// The Task Manager window's content (DEV-898). The app names each process's tabs and
/// extensions through `title`, since only it knows their titles.
public struct TaskManagerView: View {
	@Bindable
	private var store: StoreOf<TaskManagerFeature>

	private let title: (BrowserProcess) -> String

	public init(
		store: StoreOf<TaskManagerFeature>,
		title: @escaping (BrowserProcess) -> String
	) {
		self.store = store
		self.title = title
	}

	public var body: some View {
		VStack(spacing: 0) {
			if store.isAvailable {
				table
			} else {
				ContentUnavailableView(
					String.localized(.appUI.taskManager.title),
					systemImage: "gauge.with.dots.needle.50percent",
					description: Text(localized: .appUI.taskManager.unavailable)
				)
			}
			Divider()
			footer
		}
		.frame(minWidth: 560, minHeight: 320)
	}

	private var table: some View {
		Table(
			Array(store.rows),
			selection: Binding(
				get: { store.selection },
				set: { store.send(.ui(.select($0))) }
			)
		) {
			TableColumn(String.localized(.appUI.taskManager.task)) { row in
				Label(title(row.process), systemImage: symbol(row.process))
					.lineLimit(1)
					.help(title(row.process))
			}
			.width(min: 220, ideal: 320)
			TableColumn(String.localized(.appUI.taskManager.memory)) { row in
				Text(Int64(clamping: row.process.memory), format: .byteCount(style: .memory))
					.monospacedDigit()
			}
			.width(min: 80, ideal: 100)
			TableColumn(String.localized(.appUI.taskManager.cpu)) { row in
				Text(row.cpu.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–")
					.monospacedDigit()
			}
			.width(min: 50, ideal: 60)
			TableColumn(String.localized(.appUI.taskManager.processID)) { row in
				Text(verbatim: String(row.process.pid))
					.monospacedDigit()
			}
			.width(min: 60, ideal: 70)
		}
		.accessibilityIdentifier("task-manager-table")
	}

	private var footer: some View {
		HStack {
			Picker(
				String.localized(.appUI.taskManager.sort),
				selection: Binding(get: { store.sort }, set: { store.send(.ui(.sort($0))) })
			) {
				Text(localized: .appUI.taskManager.memory).tag(TaskManagerFeature.Sort.memory)

				// Formatted: its "%%" is a percent sign only once `String.localized` formats it, and a
				// resource without arguments isn't formatted.
				Text(verbatim: String.localized(.appUI.taskManager.cpu)).tag(TaskManagerFeature.Sort.cpu)
				Text(localized: .appUI.taskManager.processID).tag(TaskManagerFeature.Sort.pid)
			}
			.pickerStyle(.segmented)
			.fixedSize()
			Spacer()
			Button(String.localized(.appUI.taskManager.endProcess)) {
				if let selection = store.selection { store.send(.ui(.endProcess(selection))) }
			}
			.disabled(store.selectedRow?.process.canEnd != true)
			.help(String.localized(.appUI.taskManager.endProcessHelp))
			.accessibilityIdentifier("task-manager-end-process")
		}
		.padding(10)
	}

	private func symbol(_ process: BrowserProcess) -> String {
		switch process.kind {
		case .browser: "macwindow"
		case .gpu: "cpu"
		case .utility: "gearshape.2"
		case .other: "gearshape"
		case .renderer:
			switch process.owners.first {
			case .extensionID: "puzzlepiece.extension"
			case .privateTab: "eyeglasses"
			case .tab: "globe"
			case nil: "doc"
			}
		}
	}
}
