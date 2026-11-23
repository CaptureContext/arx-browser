import BrowserCore
import BrowserEngineClient
import CustomDump
import Foundation
import Testing
import _ComposableArchitecture
import _TestSupport

@testable import TaskManagerFeature

@Suite(.dependencies, .timeLimit(.minutes(1)))
@MainActor
internal struct TaskManagerFeatureTests {
	private let start: Date = .init(timeIntervalSince1970: 1_000)

	@Test
	internal func samplesOnlyWhileTheWindowIsOpen() async throws {
		let clock = TestClock()
		let samples = LockIsolated(0)
		let table = table(at: start, browserCPU: 1, rendererCPU: 2)
		let store = TestStore(initialState: TaskManagerFeature.State()) {
			TaskManagerFeature()
		} withDependencies: {
			$0.continuousClock = clock
			$0.browserEngine.processTable = {
				samples.withValue { $0 += 1 }
				return table
			}
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.present))
		await store.receive(\.event.sampled)
		#expect(store.state.isPresented)
		expectNoDifference(store.state.rows.map(\.id), [1, 2])
		await clock.advance(by: .seconds(1))
		await store.receive(\.event.sampled)
		expectNoDifference(samples.value, 2)

		await store.send(.ui(.dismissed))
		await clock.advance(by: .seconds(5))
		expectNoDifference(samples.value, 2)
		#expect(store.state.rows.isEmpty)
	}

	@Test
	internal func cpuIsTheChangeInCPUTimeOverTheInterval() {
		let first = table(at: start, browserCPU: 1, rendererCPU: 2)
		let second = table(at: start.addingTimeInterval(2), browserCPU: 2, rendererCPU: 2.5)

		expectNoDifference(TaskManagerFeature.rows(first, previous: nil).map(\.cpu), [nil, nil])
		expectNoDifference(TaskManagerFeature.rows(second, previous: first).map(\.cpu), [50, 25])
	}

	@Test
	internal func arxComesFirstThenTheHeaviest() {
		let rows = TaskManagerFeature.rows(table(at: start, browserCPU: 1, rendererCPU: 2), previous: nil)
		expectNoDifference(TaskManagerFeature.sorted(rows.reversed(), by: .memory).map(\.id), [1, 2])
		expectNoDifference(TaskManagerFeature.sorted(rows, by: .pid).map(\.id), [1, 2])
	}

	@Test
	internal func onlyRenderersEnd() async {
		let ended = LockIsolated<[Int32]>([])
		var state = TaskManagerFeature.State(isPresented: true)
		state.rows = .init(uniqueElements: TaskManagerFeature.rows(table(at: start, browserCPU: 1, rendererCPU: 2), previous: nil))
		let store = TestStore(initialState: state) {
			TaskManagerFeature()
		} withDependencies: {
			$0.browserEngine.endProcess = { pid in
				ended.withValue { $0.append(pid) }
				return true
			}
			$0.browserEngine.processTable = { nil }
		}
		store.exhaustivity = .off(showSkippedAssertions: false)

		await store.send(.ui(.endProcess(1)))
		await store.send(.ui(.endProcess(2)))
		await store.receive(\.event.sampled)
		expectNoDifference(ended.value, [2])

		// An engine that can't list its processes says so instead of showing an empty table.
		#expect(!store.state.isAvailable)
	}

	@Test
	internal func helpersAreClassifiedByTheirTypeSwitch() {
		expectNoDifference(BrowserProcessSampler.kind(["Arx Helper", "--type=renderer"]), .renderer)
		expectNoDifference(BrowserProcessSampler.kind(["--type=gpu-process"]), .gpu)
		expectNoDifference(
			BrowserProcessSampler.kind(["--type=utility", "--utility-sub-type=network.mojom.NetworkService"]),
			.utility("NetworkService")
		)
		expectNoDifference(BrowserProcessSampler.kind(["--type=zygote"]), .other("zygote"))
	}

	@Test
	internal func samplingReadsThisProcess() throws {
		let table = BrowserProcessSampler.sample(owners: [:])
		let own = try #require(table.processes.first)
		expectNoDifference(own.pid, getpid())
		expectNoDifference(own.kind, .browser)
		#expect(own.memory > 0)
		#expect(own.cpuTime > 0)
	}

	private func table(
		at date: Date,
		browserCPU: TimeInterval,
		rendererCPU: TimeInterval
	) -> BrowserProcessTable {
		.init(
			processes: [
				.init(pid: 1, kind: .browser, memory: 100, cpuTime: browserCPU),
				.init(pid: 2, kind: .renderer, owners: [.tab(.init(rawValue: UUID(1)))], memory: 500, cpuTime: rendererCPU),
			],
			sampledAt: date
		)
	}
}
