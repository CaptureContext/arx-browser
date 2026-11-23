#if DEBUG
import BrowserCore
import ChromiumBrowserEngine
import Foundation
import _ComposableArchitecture

/// Exercises real navigation through app-owned ordinary, private and Little Arx hosts.
/// Since DEV-728 a Little Arx page reaches its profile's history and, once closed, the
/// Tab Archive; the smoke deletes that archive entry again so later phases see the same
/// workspace.
internal enum ProfileHistorySmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		engine: ChromiumBrowserEngine,
		baseURL: URL
	) async throws {
		guard let original = store.main.viewer.item.tab else { throw Failure.missingSource }
		let paneID = store.main.viewer.activePaneID
		let ordinary = baseURL.appending(queryItems: [.init(name: "arx_history_smoke", value: "ordinary")])
		let privateURL = baseURL.appending(queryItems: [.init(name: "arx_history_smoke", value: "private")])
		let temporary = baseURL.appending(queryItems: [.init(name: "arx_history_smoke", value: "temporary")])
		store.send(.main(.viewer(.command(.navigate(ordinary), in: paneID, tabID: original.id))))
		try await wait("Ordinary navigation did not reach persistent history") {
			loaded(engine, id: original.id, url: ordinary)
			&& store.history.snapshots[original.profileID]?.entries.contains(where: { $0.url == ordinary }) == true
			&& store.history.failures[original.profileID] == nil
		}

		store.send(.ui(.newPrivateWindow))
		try await wait("Private window did not open") { store.windows.contains(where: \.isPrivate) }
		guard let window = store.windows.first(where: \.isPrivate)
		else { throw Failure.missingSource }
		store.send(.windows(.element(id: window.id, action: .commandBar(.ui(.queryChanged(privateURL.absoluteString))))))
		store.send(.windows(.element(id: window.id, action: .commandBar(.ui(.selected("destination"))))))
		try await wait("Private navigation did not finish") {
			guard let item = store.windows[id: window.id]?.viewer.item, let tab = item.tab
			else { return false }
			return loaded(engine, id: tab.id, url: privateURL) && item.navigation.url == privateURL && !item.navigation.isLoading
		}
		store.send(.ui(.requestClosePrivateWindow(window.id)))
		try await wait("Private window did not close") { store.windows[id: window.id] == nil }

		store.send(.ui(.openLittleArx(store.main.sidebar.spaceID, temporary)))
		guard let little = store.littleWindows.first else { throw Failure.missingSource }
		try await wait("Temporary navigation did not finish") {
			guard let item = store.littleWindows[id: little.id]?.viewer else { return false }
			return loaded(engine, id: little.tab.id, url: temporary) && item.navigation.url == temporary && !item.navigation.isLoading
		}
		try await wait("Little Arx navigation did not reach persistent history") {
			store.history.snapshots[little.tab.profileID]?.entries.contains(where: { $0.url == temporary }) == true
			&& store.history.failures[little.tab.profileID] == nil
		}
		let archived = Set(store.workspace.archive.map(\.id))
		store.send(.littleWindows(.element(id: little.id, action: .ui(.close))))
		try await wait("Temporary window did not close") { store.littleWindows[id: little.id] == nil }
		try await wait("Closed Little Arx page did not reach the Tab Archive") {
			store.workspace.archive.contains { !archived.contains($0.id) && $0.tab.restoration.url == temporary }
		}
		guard let entry = store.workspace.archive.first(where: { !archived.contains($0.id) })
		else { throw Failure.missingSource }

		store.send(.main(.ui(.openArchive)))
		store.send(.main(.archive(.delegate(.delete([entry.id])))))
		store.send(.main(.archive(.ui(.dismissed))))
		try await wait("Little Arx archive entry was not removed") {
			!store.workspace.archive.contains { $0.id == entry.id } && !store.main.archive.isPresented
		}

		// Restoring the ordinary page also waits for a successful, later persisted write.
		store.send(.main(.viewer(.command(.navigate(baseURL), in: paneID, tabID: original.id))))
		try await wait("Ordinary history did not settle") {
			loaded(engine, id: original.id, url: baseURL)
			&& store.main.viewer.item.navigation.url == baseURL && !store.main.viewer.item.navigation.isLoading
			&& store.history.snapshots[original.profileID]?.entries.first?.url == baseURL
			&& store.history.failures[original.profileID] == nil
		}
		let forbidden = [privateURL, baseURL.appending(queryItems: [.init(name: "peek", value: "temporary")])]
		guard store.history.snapshots.values.allSatisfy({ snapshot in
			!snapshot.entries.contains { forbidden.contains($0.url) }
		}) else { throw Failure.privateHistory }
		print("ARX_PROFILE_HISTORY_SMOKE_SUCCESS")
	}

	@MainActor
	private static func loaded(
		_ engine: ChromiumBrowserEngine,
		id: BrowserCore.Tab.ID,
		url: URL
	) -> Bool {
		guard let navigation = engine.client.snapshot(id)?.navigation else { return false }
		return navigation.url == url && !navigation.isLoading && navigation.errorCode == nil
	}

	@MainActor
	private static func wait(
		_ failure: String,
		until ready: () -> Bool
	) async throws {
		for _ in 0..<100 {
			if ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(failure)
	}

	private enum Failure: Error {
		case missingSource
		case privateHistory
		case timedOut(String)
	}
}
#endif
