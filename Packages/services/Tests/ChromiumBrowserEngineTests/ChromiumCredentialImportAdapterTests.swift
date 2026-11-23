import BrowserCore
import BrowserEngineClient
import ChromiumBridge
import Foundation
import Testing

@testable import ChromiumBrowserEngine
@testable import ChromiumEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCredentialImportAdapterTests {
	@Test
	internal func anABI45EngineOffersNoCredentialImport() async {
		let engine = ChromiumBrowserEngine(
			runtime: ChromiumRuntime(api: ArxEngineAPI()),
			profileID: .init(rawValue: UUID())
		)
		let client = engine.client
		#expect(!client.credentialImportIsAvailable())
		await #expect(throws: BrowserCredentialImportFailure.unavailable) {
			try await client.importPasswordRecords(.init(rawValue: UUID()), [])
		}
		await #expect(throws: BrowserCredentialImportFailure.unavailable) {
			try await client.undoCredentialImport(.init(rawValue: UUID()), [], [])
		}
	}

	@Test
	internal func datesBecomeChromiumMicrosecondsSince1601() {
		typealias Adapter = ChromiumCredentialImportAdapter
		#expect(Adapter.chromiumTime(Date(timeIntervalSince1970: 0)) == 11_644_473_600_000_000)
		#expect(Adapter.chromiumTime(Date(timeIntervalSince1970: 1.5)) == 11_644_473_601_500_000)
		#expect(Adapter.chromiumTime(.distantPast) == 0)
		#expect(Adapter.chromiumTime(Date(timeIntervalSince1970: .infinity)) == 0)
	}

	@Test
	internal func cookiesKeepTheirIdentityAndKeysNormalizeTheAncestorBit() {
		typealias Adapter = ChromiumCredentialImportAdapter
		let cookie = Adapter.cookie(.init(
			domain: ".a.test",
			name: "id",
			value: "throwaway",
			path: "/",
			created: Date(timeIntervalSince1970: 0),
			expires: Date(timeIntervalSince1970: 10),
			lastAccessed: Date(timeIntervalSince1970: 5),
			isSecure: true,
			isHTTPOnly: false,
			sameSite: 2,
			priority: 1,
			sourceScheme: 2,
			sourcePort: 70_000,
			topFrameSiteKey: "https://top.test",
			hasCrossSiteAncestor: true
		))
		#expect(cookie.expiresUTC == 11_644_473_610_000_000)
		#expect(cookie.sameSite == 2 && cookie.sourceScheme == 2)
		// Out of range stays out of range, so native rejects it rather than set another port.
		#expect(cookie.sourcePort == 70_000)
		#expect(cookie.hasCrossSiteAncestor && cookie.topFrameSiteKey == "https://top.test")

		let unpartitioned = Adapter.cookieKey(BrowserCookieKey(domain: "a.test", name: "id", path: "/", hasCrossSiteAncestor: true))
		#expect(!unpartitioned.hasCrossSiteAncestor)
		let partitioned: BrowserCookieKey = .init(
			domain: "a.test",
			name: "id",
			path: "/",
			topFrameSiteKey: "https://top.test",
			hasCrossSiteAncestor: true,
			sourceScheme: 2,
			sourcePort: 443
		)
		#expect(Adapter.cookieKey(Adapter.cookieKey(partitioned)) == partitioned)
	}

	@Test
	internal func callsSplitIntoChunksNativeTakes() {
		let chunks = ChromiumCredentialImportAdapter.chunks(Array(0..<5), of: 2)
		#expect(chunks.map(Array.init) == [[0, 1], [2, 3], [4]])
		#expect(ChromiumCredentialImportAdapter.chunks([Int](), of: 2).isEmpty)
	}

	@Test
	internal func failuresMap() {
		typealias Adapter = ChromiumCredentialImportAdapter
		#expect(Adapter.failure(ChromiumCredentialImportFailure.unavailable) == .unavailable)
		#expect(Adapter.failure(ChromiumCredentialImportFailure.invalid(reason: "keys")) == .invalid)
		#expect(Adapter.failure(ChromiumCredentialImportFailure.busy) == .busy)
		#expect(Adapter.failure(ChromiumCredentialImportFailure.failed(reason: nil)) == .failed)
		#expect(Adapter.failure(CancellationError()) == .failed)
	}
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
internal struct ChromiumCredentialImportChunkTests {
	private struct Failure: Error {}

	@Test
	internal func aFailedChunkRollsBackEachEarlierChunkOnItsOwn() async {
		var calls: [[Int]] = []
		var rolledBack: [[Int]] = []
		await #expect(throws: Failure.self) {
			_ = try await ChromiumCredentialImportAdapter.inChunks(Array(0..<5), of: 2) { chunk in
				calls.append(Array(chunk))
				if chunk.first == 4 { throw Failure() }
				return Array(chunk)
			} rollback: { chunk in
				rolledBack.append(chunk)
				return true
			}
		}
		#expect(calls == [[0, 1], [2, 3], [4]])
		// One undo per chunk, so none exceeds what native takes in one call.
		#expect(rolledBack == [[0, 1], [2, 3]])
	}

	@Test
	internal func aChunkWhoseRollbackFailsIsKeptAndEveryOtherRowIsOmitted() async throws {
		let result = try await ChromiumCredentialImportAdapter.inChunks(Array(0..<7), of: 2) { chunk in
			if chunk.first == 4 { throw Failure() }
			return Array(chunk)
		} rollback: { chunk in
			chunk != [2, 3]
		}
		#expect(result.parts == [[2, 3]])
		// Rolled back (0, 1), the failed chunk (4, 5) and the one never tried (6).
		#expect(result.omitted.sorted() == [0, 1, 4, 5, 6])
	}

	@Test
	internal func aFirstChunkFailureHasNothingToRollBack() async {
		var rolledBack = false
		await #expect(throws: Failure.self) {
			_ = try await ChromiumCredentialImportAdapter.inChunks([1], of: 2) { (_: ArraySlice<Int>) -> Int in
				throw Failure()
			} rollback: { _ in
				rolledBack = true
				return true
			}
		}
		#expect(!rolledBack)
	}

	@Test
	internal func successReturnsEveryChunkInOrder() async throws {
		let result = try await ChromiumCredentialImportAdapter.inChunks(Array(0..<3), of: 2) { Array($0) } rollback: { _ in true }
		#expect(result.parts == [[0, 1], [2]])
		#expect(result.omitted.isEmpty)
	}

	@Test
	internal func rollbackReportsAFailedUndo() async {
		#expect(await ChromiumCredentialImportAdapter.rollBack { 3 })
		#expect(await !ChromiumCredentialImportAdapter.rollBack { throw Failure() })
	}

	@Test
	internal func keyBatchesStayUnderTheByteLimitAsWellAsTheCount() throws {
		// 4,000 keys with 4,000-byte names and 1,024-byte paths: over 20 MB of JSON.
		let keys = (0..<4_000).map { index in
			ChromiumCookieKey(
				domain: "a.test",
				name: String(repeating: "n", count: 3_990) + String(index),
				path: "/" + String(repeating: "p", count: 1_023),
				topFrameSiteKey: "",
				hasCrossSiteAncestor: false,
				sourceScheme: 2,
				sourcePort: 443
			)
		}
		let batches = ChromiumCredentialImportAdapter.keyBatches(keys, count: 20_000)
		#expect(batches.count > 1)
		#expect(batches.flatMap { $0 } == keys)
		for batch in batches {
			let bytes = try JSONEncoder().encode(batch).count
			#expect(bytes < 16 * 1024 * 1024)
		}

		let small = ChromiumCredentialImportAdapter.keyBatches(Array(keys.prefix(5)), count: 2)
		#expect(small.map(\.count) == [2, 2, 1])
	}
}
