import BrowserCore
import _ComposableArchitecture

/// Loads Helium's !bang list from the app bundle. Nothing is fetched.
public struct BangCatalogClient: Sendable {
	public var load: @Sendable () async throws -> BangCatalog

	public init(load: @escaping @Sendable () async throws -> BangCatalog) {
		self.load = load
	}
}

extension BangCatalogClient: DependencyKey {
	public static var liveValue: Self { .init(load: { try await BangCatalog.bundled() }) }
	public static var testValue: Self { .init(load: unimplemented("BangCatalogClient.load", placeholder: .empty)) }
}

extension DependencyValues {
	public var bangCatalog: BangCatalogClient {
		get { self[BangCatalogClient.self] }
		set { self[BangCatalogClient.self] = newValue }
	}
}

/// Reads the bundled list once and hands it to Settings and every command bar.
@Reducer
internal struct BundledBangs {
	internal typealias State = AppFeature.State
	internal typealias Action = AppFeature.Action

	@Dependency(\.bangCatalog)
	private var client

	private enum Cancellation: Hashable {
		case load
	}

	internal init() {}

	internal var body: some ReducerOf<Self> {
		Pullback(\.loadBangs) { state in
			guard state.settings.bangs.bangs.isEmpty else { return .none }

			return .run { [client] send in

				// Parsing and indexing run on the client's executor, not the main actor.
				let catalog = try await client.load()
				await send(.event(.bangsLoaded(catalog)))
			} catch: { error, _ in
				reportIssue(error)
			}
			.cancellable(id: Cancellation.load, cancelInFlight: true)
		}

		Pullback(\.event.bangsLoaded) { state, catalog in
			state.settings.bangs = catalog
			state.main.commandBar.bangs = catalog
			for id in state.windows.ids {
				state.windows[id: id]?.commandBar.bangs = catalog
			}
			for id in state.littleWindows.ids {
				state.littleWindows[id: id]?.commandBar.bangs = catalog
			}
			return .none
		}
	}
}
