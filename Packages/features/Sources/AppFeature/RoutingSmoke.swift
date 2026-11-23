#if DEBUG
import BrowserCore
import BrowserEngineClient
import BrowserWorkspaceClient
import Darwin
import Foundation
import _ComposableArchitecture

/// Observes real external events and production routing. It never injects routing actions.
@MainActor
internal final class RoutingSmoke {
	internal let fixture: RoutingSmokeFixture
	private var received: [URL] = []
	private var committed: [BrowserCore.Tab] = []
	private var failure: RoutingSmokeFixture.Failure?

	internal init(fixture: RoutingSmokeFixture) {
		self.fixture = fixture
	}

	internal func received(_ url: URL) {
		guard
			received.count < fixture.configuration.urls.count,
			fixture.configuration.urls[received.count] == url
		else {
			failure = .unexpectedReceipt
			return
		}
		received.append(url)
	}

	internal func observe(state: AppFeature.State) {
		let tabs = fixture.configuration.mode == .mainBrowser
		? Array(state.workspace.tabs)
		: state.littleWindows.map(\.tab)
		guard tabs.count >= committed.count else {
			failure = .unexpectedCommit
			return
		}
		for tab in tabs.dropFirst(committed.count) {
			guard committed.count < 4 else {
				failure = .unexpectedCommit
				return
			}
			committed(tab, target: fixture.target(at: committed.count), state: state)
		}
	}

	private func committed(
		_ tab: BrowserCore.Tab,
		target: RoutingTarget,
		state: AppFeature.State
	) {
		guard
			committed.count < fixture.configuration.urls.count,
			fixture.configuration.urls[committed.count] == tab.restoration.url,
			!committed.contains(where: { $0.id == tab.id }),
			tab.profileID == target.profileID
		else {
			failure = .unexpectedCommit
			return
		}

		let isPublished: Bool
		switch target.mode {
		case .mainBrowser:
			let space = state.workspace.spaces[id: target.spaceID]
			isPublished = space?.unpinnedTabs.contains(tab.id) == true

		case .littleArx:
			isPublished = state.littleWindows.contains {
				$0.tab.id == tab.id && $0.spaceID == target.spaceID
			}
		}
		guard isPublished else {
			failure = .incorrectDestination
			return
		}
		committed.append(tab)
	}

	internal func run(
		store: StoreOf<AppFeature>,
		engine: BrowserEngineClient
	) async throws {
		let clock = ContinuousClock()
		let deadline = clock.now.advanced(by: .seconds(45))
		while clock.now < deadline {
			try Task.checkCancellation()
			observe(state: store.state)
			if let failure { throw failure }
			guard
				received.count == 4,
				committed.count == 4,
				store.routingInbox.requests.isEmpty
			else {
				try await Task.sleep(for: .milliseconds(50))
				continue
			}
			guard committed.enumerated().allSatisfy({ index, tab in
				matches(engine.snapshot(tab.id)?.navigation, at: index)
			}) else {
				try await Task.sleep(for: .milliseconds(50))
				continue
			}

			try validate(state: store.state)

			// Let queued production navigation/history effects settle; never record a synthetic visit.
			try await Task.sleep(for: .milliseconds(250))
			try validate(state: store.state)
			try writeResult(status: "passed")
			return
		}
		throw RoutingSmokeFixture.Failure.timedOut
	}

	internal func matches(
		_ navigation: BrowserNavigation?,
		at index: Int
	) -> Bool {
		guard let navigation else { return false }
		let identity = index == 0 || index == 2 ? "a" : "b"
		let expected = fixture.configuration.urls[index]
		guard
			!navigation.isLoading,
			navigation.errorCode == nil,
			navigation.url == expected,
			navigation.title == "Arx routing|\(identity)|\(expected.absoluteString)"
		else { return false }

		return navigation.history.contains { $0.isCurrent && $0.url == expected }
	}

	internal func validate(state: AppFeature.State) throws {
		if let failure { throw failure }
		guard
			received == fixture.configuration.urls,
			committed.map(\.restoration.url) == fixture.configuration.urls,
			Set(committed.map(\.id)).count == 4,
			state.routingInbox.requests.isEmpty
		else { throw RoutingSmokeFixture.Failure.unexpectedCommit }

		switch fixture.configuration.mode {
		case .mainBrowser:
			guard
				state.workspace.tabs.map(\.id) == committed.map(\.id),
				state.workspace.spaces[0].unpinnedTabs == [committed[0].id, committed[2].id],
				state.workspace.spaces[1].unpinnedTabs == [committed[1].id, committed[3].id],
				state.main.sidebar.selectedTab?.id == committed[3].id,
				state.main.viewer.item.tab?.id == committed[3].id,
				state.littleWindows.isEmpty
			else { throw RoutingSmokeFixture.Failure.incorrectDestination }

		case .littleArx:
			let expectedSpaces = (0..<4).map { fixture.target(at: $0).spaceID }
			guard
				state.workspace == fixture.organization,
				state.littleWindows.map(\.tab.id) == committed.map(\.id),
				state.littleWindows.map(\.spaceID) == expectedSpaces
			else { throw RoutingSmokeFixture.Failure.persistedTemporaryPage }

			// Little Arx pages reach their profile's history (DEV-728), but nothing else may.
			let routed = Set(fixture.configuration.urls)
			guard
				state.history.snapshots.values.allSatisfy({ $0.entries.allSatisfy { routed.contains($0.url) } }),
				state.history.queuedVisits.values.allSatisfy({ $0.allSatisfy { routed.contains($0.url) } })
			else { throw RoutingSmokeFixture.Failure.unexpectedHistory }
		}
	}

	internal func writeResult(status: String) throws {
		let result: [String: Any] = [
			"status": status,
			"pid": ProcessInfo.processInfo.processIdentifier,
			"application": Bundle.main.bundleURL.resolvingSymlinksInPath().path,
			"profile": fixture.profile.path,
			"mode": fixture.configuration.mode.rawValue,
			"received": received.map(\.absoluteString),
			"committed": committed.map(\.restoration.url.absoluteString),
			"tabIDs": committed.map { $0.id.rawValue.uuidString },
		]
		let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
		guard data.count <= 8192 else { throw RoutingSmokeFixture.Failure.invalidFixture }
		let path = fixture.root.appendingPathComponent("result.json")
		let descriptor = open(path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw RoutingSmokeFixture.Failure.resultExists }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		try handle.write(contentsOf: data)
		try handle.close()
	}
}
#endif
