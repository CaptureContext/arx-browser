import BrowserCore
import BrowserHistoryClient
import Foundation
import Testing
import _TestSupport

@Suite
internal struct BrowserHistoryTests {
	@Test
	internal func profileRestartPreservesExactURLAndRevisitIdentity() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let first = Profile.ID(rawValue: UUID(1))
		let second = Profile.ID(rawValue: UUID(2))
		let url = URL(string: "https://capturecontext.dev/a%2Fb?q=first&q=second#fragment")!
		let original = try await store.record(first, url: url, title: "First title", date: Date(timeIntervalSince1970: 10))
		let updated = try await store.record(first, url: url, title: "New title", date: Date(timeIntervalSince1970: 20))
		#expect(updated.snapshot.entries.count == 1)
		#expect(updated.snapshot.entries[0].id == original.snapshot.entries[0].id)
		#expect(updated.snapshot.entries[0].title == "New title")
		let other = try await store.record(second, url: url, title: "Other profile", date: Date(timeIntervalSince1970: 30))
		#expect(other.snapshot.entries[0].id != original.snapshot.entries[0].id)
		// Revisits within the write interval are coalesced until the next write or flush.
		await store.flush()
		let restored = try await BrowserHistoryStore(directory: directory).load(first)
		#expect(restored.snapshot.entries == updated.snapshot.entries)
		#expect(restored.snapshot.entries[0].url.absoluteString == url.absoluteString)
		_ = try await store.clear(first)
		#expect(try await BrowserHistoryStore(directory: directory).load(first).snapshot.entries.isEmpty)
		#expect(try await BrowserHistoryStore(directory: directory).load(second).snapshot == other.snapshot)
	}

	@Test
	internal func clearingSinceKeepsOlderEntriesAndWritesAtOnce() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let profile = Profile.ID(rawValue: UUID(1))
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/old")!, title: "Old", date: Date(timeIntervalSince1970: 10))
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/new")!, title: "New", date: Date(timeIntervalSince1970: 100))

		let cleared = try await store.clear(profile, since: Date(timeIntervalSince1970: 50))
		#expect(cleared.failure == nil)
		#expect(cleared.snapshot.entries.map(\.title) == ["Old"])
		let restored = try await BrowserHistoryStore(directory: directory).load(profile)
		#expect(restored.snapshot.entries.map(\.title) == ["Old"])
	}

	@Test
	internal func removingEntriesOrASiteDropsOnlyThoseAndWritesAtOnce() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let profile = Profile.ID(rawValue: UUID(1))
		_ = try await store.record(profile, url: URL(string: "https://capturecontext.dev/a")!, title: "A", date: Date(timeIntervalSince1970: 10))
		_ = try await store.record(profile, url: URL(string: "https://www.example.com/b")!, title: "B", date: Date(timeIntervalSince1970: 20))
		let recorded = try await store.record(
			profile,
			url: URL(string: "https://Example.com/c")!,
			title: "C",
			date: Date(timeIntervalSince1970: 30)
		)
		let a = try #require(recorded.snapshot.entries.first { $0.title == "A" })

		let removed = try await store.remove(profile, .entries([a.id]), before: Date(timeIntervalSince1970: 100))
		#expect(removed.failure == nil)
		#expect(removed.snapshot.entries.map(\.title) == ["C", "B"])

		// A site's removal ignores case and `www.`.
		let site = try await store.remove(profile, .site("example.com"), before: Date(timeIntervalSince1970: 100))
		#expect(site.snapshot.entries.isEmpty)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot.entries.isEmpty)
	}

	@Test
	internal func aVisitFromBeforeARemovalThatArrivesLateDoesNotBringThePageBack() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let profile = Profile.ID(rawValue: UUID(1))
		let url = URL(string: "https://capturecontext.dev/a")!
		let recorded = try await store.record(profile, url: url, title: "A", date: Date(timeIntervalSince1970: 10))
		let entry = try #require(recorded.snapshot.entries.first)
		_ = try await store.remove(profile, .entries([entry.id]), before: Date(timeIntervalSince1970: 100))

		// A record made at 50, before the removal, lands after it.
		let late = try await store.record(profile, url: url, title: "A", date: Date(timeIntervalSince1970: 50))
		#expect(late.snapshot.entries.isEmpty)
		// A visit after the removal is recorded as usual.
		let revisit = try await store.record(profile, url: url, title: "A", date: Date(timeIntervalSince1970: 150))
		#expect(revisit.snapshot.entries.map(\.url) == [url])

		// The revisit at 150 came after this removal was asked for at 120, so it stays.
		let kept = try await store.remove(profile, .site("www.capturecontext.dev"), before: Date(timeIntervalSince1970: 120))
		#expect(kept.snapshot.entries.map(\.url) == [url])
		let site = try await store.record(
			profile,
			url: URL(string: "https://capturecontext.dev/b")!,
			title: "B",
			date: Date(timeIntervalSince1970: 60)
		)

		// A late visit to the site from before that removal isn't recorded.
		#expect(site.snapshot.entries.map(\.url) == [url])
	}

	@Test
	internal func importedHistoryMergesByURLKeepsTheNewestVisitAndWritesAtOnce() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let profile = Profile.ID(rawValue: UUID(1))
		let shared = URL(string: "https://capturecontext.dev/shared")!
		_ = try await store.record(profile, url: shared, title: "Here", date: Date(timeIntervalSince1970: 20))

		let merged = try await store.merge(
			profile,
			entries: [
				.init(id: UUID(1), url: shared, title: "Older there", lastVisited: Date(timeIntervalSince1970: 10)),
				.init(id: UUID(2), url: URL(string: "https://capturecontext.dev/new")!, title: "New ✨", lastVisited: Date(timeIntervalSince1970: 30)),
			]
		)
		let again = try await store.merge(
			profile,
			entries: [.init(id: UUID(3), url: shared, title: "Newer there", lastVisited: Date(timeIntervalSince1970: 40))]
		)

		#expect(merged.failure == nil)
		#expect(merged.snapshot.entries.map(\.title) == ["New ✨", "Here"])
		#expect(again.snapshot.entries.map(\.title) == ["Newer there", "New ✨"])
		#expect(again.snapshot.isValid)
		// Written at once, without waiting for the coalescing window or a flush.
		let restored = try await BrowserHistoryStore(directory: directory).load(profile)
		#expect(restored.snapshot.entries == again.snapshot.entries)
	}

	/// DEV-1015: visit and typed counts, imported or recorded, are written and read back.
	@Test
	internal func visitAndTypedCountsArePersisted() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let profile = Profile.ID(rawValue: UUID(1))
		let url = URL(string: "https://news.ycombinator.com/")!

		_ = try await store.merge(
			profile,
			entries: [.init(id: UUID(9), url: url, title: "HN", lastVisited: Date(timeIntervalSince1970: 10), visitCount: 40, typedCount: 12)]
		)
		_ = try await store.record(profile, .init(url: url, title: "HN", date: Date(timeIntervalSince1970: 20), isTyped: true))
		_ = try await store.record(profile, .init(url: url, title: "Hacker News", date: Date(timeIntervalSince1970: 21), isNew: false))
		await store.flush()

		let restored = try await BrowserHistoryStore(directory: directory).load(profile)
		let entry = try #require(restored.snapshot.entries.first)
		#expect(entry.visitCount == 41)
		#expect(entry.typedCount == 13)
		#expect(entry.title == "Hacker News")
	}

	@Test
	internal func burstOfRecordsWritesOnceThenFlushes() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let profile = Profile.ID(rawValue: UUID(1))
		let writes = LockIsolated(0)
		let store = BrowserHistoryStore(directory: directory) { data, file in
			writes.withValue { $0 += 1 }
			try data.write(to: file, options: .atomic)
		}
		for index in 0..<10 {
			_ = try await store.record(
				profile,
				url: URL(string: "https://capturecontext.dev/\(index)")!,
				title: "",
				date: Date(timeIntervalSince1970: Double(index))
			)
		}
		#expect(writes.value == 1)

		await store.flush()
		#expect(writes.value == 2)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot.entries.count == 10)
	}

	@Test
	internal func rejectsUnsupportedURLsAndBoundsRecentDistinctEntries() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let profile = Profile.ID(rawValue: UUID(1))
		let unsupportedURLs = [
			"file:///tmp/example",
			"about:blank",
			"https://user:password@capturecontext.dev",
			"https://user@capturecontext.dev",
		]
		for text in unsupportedURLs {
			let result = try await store.record(profile, url: URL(string: text)!, title: "", date: .now)
			#expect(result.snapshot.entries.isEmpty)
		}
		var snapshot = BrowsingHistorySnapshot(
			profileID: profile,
			entries: (0..<BrowsingHistorySnapshot.limit).map {
				.init(
					id: UUID(),
					url: URL(string: "https://capturecontext.dev/\($0)")!,
					title: "",
					lastVisited: Date(timeIntervalSince1970: Double($0))
				)
			}
		)
		snapshot.record(
			url: URL(string: "https://capturecontext.dev/new")!,
			title: "New",
			at: Date(timeIntervalSince1970: 3_000),
			id: UUID()
		)
		#expect(snapshot.entries.count == BrowsingHistorySnapshot.limit)
		#expect(snapshot.entries.first?.url.path == "/new")
		#expect(snapshot.entries.contains(where: { $0.url.path == "/0" }) == false)
		#expect(snapshot.isValid)
		let combiningTitle = "e" + String(repeating: "\u{301}", count: 20_000)
		let bounded = BrowsingHistoryEntry(
			id: UUID(),
			url: URL(string: "https://capturecontext.dev")!,
			title: combiningTitle,
			lastVisited: .now
		)
		#expect(bounded.title.utf8.count <= 4_096)
		#expect(!bounded.title.unicodeScalars.contains("\u{FFFD}"))
		let persisted = try await store.record(profile, url: bounded.url, title: combiningTitle, date: .now)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot == persisted.snapshot)
	}

	@Test
	internal func encodedBudgetTrimsOldestEntriesBeforeWritingAndRestarts() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let profile = Profile.ID(rawValue: UUID(1))
		let encoder = JSONEncoder()
		encoder.outputFormatting = .withoutEscapingSlashes
		let title = String(repeating: "\u{1}", count: 4_096)
		let base = "https://capturecontext.dev/" + String(repeating: "a", count: 32_700)
		func entry(_ index: Int) -> BrowsingHistoryEntry {
			.init(
				id: UUID(),
				url: URL(string: base + String(format: "/%04d", index))!,
				title: title,
				lastVisited: Date(timeIntervalSince1970: 100)
			)
		}

		let entryBytes = try encoder.encode(entry(0)).count + 1
		let count = (80_000_000 - 1_000) / entryBytes
		let snapshot = BrowsingHistorySnapshot(profileID: profile, entries: (0..<count).map(entry))
		#expect(count < BrowsingHistorySnapshot.limit)
		let data = try encoder.encode(HistoryDocument(snapshot: snapshot))
		#expect(data.count <= 80_000_000)
		#expect(data.count + entryBytes > 80_000_000)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent(profile.rawValue.uuidString).appendingPathExtension("json")
		try data.write(to: file, options: .atomic)
		let next = entry(count)
		let outcome = try await BrowserHistoryStore(directory: directory).record(
			profile,
			url: next.url,
			title: next.title,
			date: Date(timeIntervalSince1970: 200)
		)
		#expect(outcome.failure == nil)
		#expect(outcome.snapshot.entries.count < count + 1)
		#expect(outcome.snapshot.entries.first?.url == next.url)
		#expect(try Data(contentsOf: file).count <= 80_000_000)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot == outcome.snapshot)
	}

	@Test
	internal func cancelledRecordDoesNotRepopulateClearedHistory() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let profile = Profile.ID(rawValue: UUID(1))
		let store = BrowserHistoryStore(directory: directory)
		_ = try await store.clear(profile)
		let task = Task {
			withUnsafeCurrentTask { $0?.cancel() }
			return try await store.record(profile, url: URL(string: "https://old.example")!, title: "Old", date: .now)
		}
		await #expect(throws: CancellationError.self) { try await task.value }
		#expect(try await store.load(profile).snapshot.entries.isEmpty)
	}

	@Test
	internal func failedWriteKeepsPreviousDiskAndLatestMemoryForRetry() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let profile = Profile.ID(rawValue: UUID(1))
		let original = try await BrowserHistoryStore(directory: directory).record(
			profile,
			url: URL(string: "https://first.example")!,
			title: "First",
			date: .now
		)
		let writer = FailingWriter()
		let store = BrowserHistoryStore(directory: directory, writer: writer.write)
		let failure = try await store.record(profile, url: URL(string: "https://next.example")!, title: "Next", date: .now)
		#expect(failure.failure == .writeFailed)
		#expect(failure.snapshot.entries.count == 2)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot == original.snapshot)
		writer.enable()
		let retried = try await store.retry(profile)
		#expect(retried.failure == nil)
		#expect(retried.snapshot.revision > failure.snapshot.revision)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot == retried.snapshot)
	}

	@Test(arguments: ["corrupt", "future", "foreign", "external", "oversized"])
	internal func preservesUnreadableOrExternallyChangedHistoryUntilExplicitClear(_ kind: String) async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let profile = Profile.ID(rawValue: UUID(1))
		let store = BrowserHistoryStore(directory: directory)
		_ = try await store.record(profile, url: URL(string: "https://first.example")!, title: "First", date: .now)
		let file = directory.appendingPathComponent(profile.rawValue.uuidString).appendingPathExtension("json")
		var data = try Data(contentsOf: file)
		if kind == "oversized" {
			data = Data(repeating: 0, count: 80_000_001)

		} else if kind == "corrupt" || kind == "external" {
			data = Data("damaged".utf8)

		} else {
			var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
			if kind == "future" {
				object["version"] = 99
			} else {
				var snapshot = try #require(object["snapshot"] as? [String: Any])
				snapshot["profileID"] = UUID(2).uuidString
				object["snapshot"] = snapshot
			}
			data = try JSONSerialization.data(withJSONObject: object)
		}
		try data.write(to: file, options: .atomic)
		if kind == "external" {
			#expect(try await store.retry(profile).failure == .changedOnDisk)
		} else {
			await #expect(throws: (any Error).self) {
				try await BrowserHistoryStore(directory: directory).record(
					profile,
					url: URL(string: "https://next.example")!,
					title: "",
					date: .now
				)
			}
		}
		#expect(try Data(contentsOf: file) == data)
		#expect(try await store.clear(profile).failure == nil)
		#expect(try await BrowserHistoryStore(directory: directory).load(profile).snapshot.entries.isEmpty)
	}

	@Test
	internal func removedProfileRejectsLateRecordsAndLeavesOtherProfilesAlone() async throws {
		let directory = temporaryDirectory()
		defer { try? FileManager.default.removeItem(at: directory) }
		let store = BrowserHistoryStore(directory: directory)
		let first = Profile.ID(rawValue: UUID(1))
		let second = Profile.ID(rawValue: UUID(2))
		let url = URL(string: "https://capturecontext.dev")!
		_ = try await store.record(first, url: url, title: "", date: .now)
		let retained = try await store.record(second, url: url, title: "Other", date: .now)
		try await store.remove(first)
		await #expect(throws: (any Error).self) { try await store.record(first, url: url, title: "Late", date: .now) }
		#expect(try await BrowserHistoryStore(directory: directory).load(first).snapshot.entries.isEmpty)
		#expect(try await store.load(second) == retained)
	}

	private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("arx-history-\(UUID())") }
}

private final class FailingWriter: @unchecked Sendable {
	private let lock: NSLock = .init()
	private var canWrite: Bool = false
	internal func enable() { lock.withLock { canWrite = true } }
	internal func write(
		_ data: Data,
		to file: URL
	) throws {
		guard lock.withLock({ canWrite }) else { throw CocoaError(.fileWriteUnknown) }
		try data.write(to: file, options: .atomic)
	}
}

private struct HistoryDocument: Codable {
	internal var version: Int = 1
	internal var snapshot: BrowsingHistorySnapshot
}
