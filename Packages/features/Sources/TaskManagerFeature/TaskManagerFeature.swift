import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

/// Window ▸ Task Manager (DEV-898): every Arx process with its memory, CPU and process ID, the
/// tabs and extensions in each renderer, and End Process for a renderer.
///
/// It samples once a second while its window is open, and never otherwise.
@Reducer
public struct TaskManagerFeature {
	@ObservableState
	public struct State: Equatable {
		public var isPresented: Bool

		/// False with an engine built before the Task Manager.
		public var isAvailable: Bool
		public var rows: IdentifiedArrayOf<Row>
		public var selection: Int32?
		public var sort: Sort

		/// Asks the window to come forward when the command runs while it's open.
		public var focusRequest: Int

		/// Installed extensions' names by ID, read by the app when the window opens.
		public var extensionNames: [String: String]
		internal var previous: BrowserProcessTable?

		public init(
			isPresented: Bool = false,
			isAvailable: Bool = true,
			rows: IdentifiedArrayOf<Row> = [],
			selection: Int32? = nil,
			sort: Sort = .memory,
			focusRequest: Int = 0
		) {
			self.isPresented = isPresented
			self.isAvailable = isAvailable
			self.rows = rows
			self.selection = selection
			self.sort = sort
			self.focusRequest = focusRequest
			self.extensionNames = [:]
			self.previous = nil
		}

		public var selectedRow: Row? {
			selection.flatMap { rows[id: $0] }
		}
	}

	/// One process as the table shows it.
	public struct Row: Equatable, Identifiable, Sendable {
		public var id: Int32 { process.pid }
		public var process: BrowserProcess

		/// Percent of one core over the last second, or nil for the first sample.
		public var cpu: Double?

		public init(
			process: BrowserProcess,
			cpu: Double?
		) {
			self.process = process
			self.cpu = cpu
		}
	}

	public enum Sort: Equatable, Sendable {
		case memory
		case cpu
		case pid
	}

	@CasePathable
	public enum Action: Sendable {
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case present
			case dismissed
			case select(Int32?)
			case sort(Sort)
			case endProcess(Int32)
		}

		@CasePathable
		public enum Event: Sendable {
			case sampled(BrowserProcessTable?)
			case extensionNames([String: String])
		}

		@CasePathable
		public enum Delegate: Sendable {}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	@Dependency(\.browserEngine)
	private var engine

	@Dependency(\.continuousClock)
	private var clock

	private enum Cancellation: Hashable {
		case sampling
	}

	/// How often the open window samples.
	public static let interval: Duration = .seconds(1)

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.ui.present) { state in
			state.focusRequest += 1
			guard !state.isPresented else { return .none }

			state.isPresented = true
			state.previous = nil
			return .run { [engine, clock] send in
				while !Task.isCancelled {
					let table = await MainActor.run { engine.processTable() }
					await send(.event(.sampled(table)))
					try await clock.sleep(for: Self.interval)
				}
			}
			.cancellable(id: Cancellation.sampling, cancelInFlight: true)
		}

		Pullback(\.ui.dismissed) { state in
			state.isPresented = false
			state.rows = []
			state.selection = nil
			state.previous = nil
			return .cancel(id: Cancellation.sampling)
		}

		Pullback(\.ui.select) { state, pid in
			state.selection = pid
			return .none
		}

		Pullback(\.ui.sort) { state, sort in
			state.sort = sort
			state.rows = .init(uniqueElements: Self.sorted(Array(state.rows), by: sort))
			return .none
		}

		Pullback(\.ui.endProcess) { state, pid in
			guard state.rows[id: pid]?.process.canEnd == true else { return .none }

			return .run { [engine] send in
				_ = await MainActor.run { engine.endProcess(pid) }
				let table = await MainActor.run { engine.processTable() }
				await send(.event(.sampled(table)))
			}
		}

		Pullback(\.event.extensionNames) { state, names in
			state.extensionNames = names
			return .none
		}

		Pullback(\.event.sampled) { state, table in
			guard state.isPresented else { return .none }
			guard let table else {
				state.isAvailable = false
				state.rows = []
				return .none
			}

			state.isAvailable = true
			let rows = Self.rows(table, previous: state.previous)
			state.rows = .init(uniqueElements: Self.sorted(rows, by: state.sort))
			state.previous = table
			if let selection = state.selection, state.rows[id: selection] == nil { state.selection = nil }
			return .none
		}
	}

	/// The processes with their CPU over the time since `previous`, in percent of one core.
	internal static func rows(
		_ table: BrowserProcessTable,
		previous: BrowserProcessTable?
	) -> [Row] {
		let elapsed = previous.map { table.sampledAt.timeIntervalSince($0.sampledAt) } ?? 0
		let before = Dictionary(
			(previous?.processes ?? []).map { ($0.pid, $0.cpuTime) },
			uniquingKeysWith: { first, _ in first }
		)
		return table.processes.map { process in
			let cpu: Double? = elapsed > 0
			? before[process.pid].map { max(0, process.cpuTime - $0) / elapsed * 100 }
			: nil
			return .init(process: process, cpu: cpu)
		}
	}

	/// Arx itself first, then the heaviest.
	internal static func sorted(
		_ rows: [Row],
		by sort: Sort
	) -> [Row] {
		rows.sorted { lhs, rhs in
			if (lhs.process.kind == .browser) != (rhs.process.kind == .browser) {
				return lhs.process.kind == .browser
			}
			switch sort {
			case .memory:
				return lhs.process.memory != rhs.process.memory
				? lhs.process.memory > rhs.process.memory
				: lhs.process.pid < rhs.process.pid
			case .cpu:
				return (lhs.cpu ?? 0) != (rhs.cpu ?? 0)
				? (lhs.cpu ?? 0) > (rhs.cpu ?? 0)
				: lhs.process.pid < rhs.process.pid
			case .pid:
				return lhs.process.pid < rhs.process.pid
			}
		}
	}
}
