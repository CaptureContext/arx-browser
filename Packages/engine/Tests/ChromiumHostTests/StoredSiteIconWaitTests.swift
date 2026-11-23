import CoreGraphics
import CustomDump
import Foundation
import ImageIO
import Synchronization
import Testing

@testable import ChromiumEngine
@testable import ChromiumHost

@MainActor
internal struct StoredSiteIconWaitTests {
	private static let pageURL: URL = URL(string: "http://127.0.0.1:1234/back-forward-cache/a")!
	private static let iconURL: URL = URL(string: "http://127.0.0.1:1234/back-forward-cache/icon.png")!
	private static let stored: Store.Answer = .icon(width: 16, height: 16, iconURL: iconURL)

	@Test
	internal func readsUntilTheStoreHoldsTheIcon() async throws {
		let clock = ManualClock()
		let store = Store([.missing, .missing, Self.stored])

		try await wait().wait(clock: clock, read: store.read, context: { "unused" })

		expectNoDifference(store.reads, 3)
		expectNoDifference(clock.elapsed, .milliseconds(200))
	}

	@Test
	internal func returnsAtOnceWhenTheIconIsAlreadyStored() async throws {
		let clock = ManualClock()
		let store = Store([Self.stored])

		try await wait().wait(clock: clock, read: store.read, context: { "unused" })

		expectNoDifference(store.reads, 1)
		expectNoDifference(clock.elapsed, .zero)
	}

	@Test
	internal func keepsReadingPastAnotherFaviconOrAnEmptyBitmap() async throws {
		let other = URL(string: "http://127.0.0.1:1234/favicon.ico")!
		let store = Store([
			.icon(width: 16, height: 16, iconURL: other),
			.icon(width: 16, height: 16, iconURL: nil),
			.icon(width: 0, height: 16, iconURL: Self.iconURL),
			Self.stored,
		])

		try await wait().wait(clock: ManualClock(), read: store.read, context: { "unused" })

		expectNoDifference(store.reads, 4)
	}

	@Test
	internal func failedReadsCountAsMisses() async throws {
		let store = Store([
			.failure(ChromiumSiteIconFailure.busy),
			.failure(ChromiumSiteIconFailure.timeout),
			Self.stored,
		])

		try await wait().wait(clock: ManualClock(), read: store.read, context: { "unused" })

		expectNoDifference(store.reads, 3)
	}

	@Test
	internal func timesOutWithThePageTheIconAndTheLastRead() async throws {
		let clock = ManualClock()
		let store = Store([.missing])
		var contexts = 0

		let error = await #expect(throws: StoredSiteIconWait.TimedOut.self) {
			try await wait(timeout: .seconds(1)).wait(clock: clock, read: store.read) {
				contexts += 1
				return "changes=2,reported=none"
			}
		}

		// A read at 0, every 100 ms, and the last one at the deadline.
		expectNoDifference(error, .init(
			pageURL: Self.pageURL,
			iconURL: Self.iconURL,
			reads: 11,
			store: .missing,
			context: "changes=2,reported=none"
		))
		expectNoDifference(clock.elapsed, .seconds(1))
		expectNoDifference(contexts, 1)
		expectNoDifference(
			error.map(String.init(describing:)),
			"timed-out wait=stored-icon last=page=http://127.0.0.1:1234/back-forward-cache/a,"
			+ "icon=http://127.0.0.1:1234/back-forward-cache/icon.png,store=missing,reads=11,"
			+ "changes=2,reported=none"
		)
	}

	@Test
	internal func aTimeOutNamesTheLastFailureOrTheWrongIcon() async throws {
		let other = URL(string: "http://127.0.0.1:1234/favicon.ico")!
		let cases: [(Store.Answer, String)] = [
			(.failure(ChromiumSiteIconFailure.unavailable), "error(unavailable)"),
			(.icon(width: 16, height: 16, iconURL: other), "icon(16x16,http://127.0.0.1:1234/favicon.ico)"),
			(.icon(width: 16, height: 16, iconURL: nil), "icon(16x16,unknown)"),
		]
		for (answer, described) in cases {
			let store = Store([answer])
			let error = await #expect(throws: StoredSiteIconWait.TimedOut.self) {
				try await wait(timeout: .milliseconds(300)).wait(clock: ManualClock(), read: store.read) { "" }
			}

			expectNoDifference(error.map { "\($0.store)" }, described)

			// An empty context adds nothing to the line.
			#expect(error.map { "\($0)" }?.hasSuffix(",store=\(described),reads=4") == true)
		}
	}

	@Test
	internal func cancellationStopsTheWait() async throws {
		let clock = ManualClock()
		let store = Store([.failure(CancellationError())])

		await #expect(throws: CancellationError.self) {
			try await wait().wait(clock: clock, read: store.read, context: { "unused" })
		}

		expectNoDifference(store.reads, 1)
		expectNoDifference(clock.elapsed, .zero)
	}

	@Test
	internal func readsAStoredIconOrItsAbsence() async throws {
		expectNoDifference(StoredSiteIconWait.Read(nil), .missing)
		let icon = try ChromiumSiteIcon(png: Self.png(width: 2, height: 3), width: 2, height: 3, iconURL: Self.iconURL)
		expectNoDifference(StoredSiteIconWait.Read(icon), .icon(width: 2, height: 3, iconURL: Self.iconURL))
	}

	private func wait(timeout: Duration = .seconds(5)) -> StoredSiteIconWait {
		StoredSiteIconWait(
			pageURL: Self.pageURL,
			iconURL: Self.iconURL,
			timeout: timeout,
			interval: .milliseconds(100)
		)
	}

	private static func png(
		width: Int,
		height: Int
	) throws -> Data {
		let context = try #require(CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		let image = try #require(context.makeImage())
		let data = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, nil)
		#expect(CGImageDestinationFinalize(destination))
		return data as Data
	}
}

/// Answers each read in turn and repeats its last answer.
@MainActor
private final class Store {
	internal enum Answer {
		case read(StoredSiteIconWait.Read)
		case failure(any Error)

		internal static var missing: Self { .read(.missing) }

		internal static func icon(
			width: Int,
			height: Int,
			iconURL: URL?
		) -> Self {
			.read(.icon(width: width, height: height, iconURL: iconURL))
		}
	}

	private let answers: [Answer]
	internal private(set) var reads: Int = 0

	internal init(_ answers: [Answer]) {
		self.answers = answers
	}

	internal func read() async throws -> StoredSiteIconWait.Read {
		let answer = answers[min(reads, answers.count - 1)]
		reads += 1
		switch answer {
		case let .read(read): return read
		case let .failure(error): throw error
		}
	}
}

/// A clock whose sleeps return at once, moving it to their deadline.
private final class ManualClock: Clock {
	internal typealias Instant = ContinuousClock.Instant

	private let start: Instant = ContinuousClock.now
	private let current: Mutex<Instant>

	internal init() {
		self.current = Mutex(start)
	}

	internal var now: Instant { current.withLock { $0 } }
	internal var minimumResolution: Duration { .zero }
	internal var elapsed: Duration { start.duration(to: now) }

	internal func sleep(
		until deadline: Instant,
		tolerance: Duration?
	) async throws {
		try Task.checkCancellation()
		current.withLock { $0 = max($0, deadline) }
	}
}
