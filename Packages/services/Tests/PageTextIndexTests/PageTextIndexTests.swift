import BrowserCore
import Foundation
import Testing

@testable import PageTextIndexClient

/// DEV-1068: a profile's page text is kept bounded, searched by the start of its words with the
/// passage that matched, and goes with the history it belongs to.
internal struct PageTextIndexTests {
	private let profileID: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
	private let other: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

	@Test
	internal func aWordFromThePageFindsItWithThePassage() async throws {
		let (index, _) = try Self.index()
		await index.save(profileID, Self.page("https://news.example/mill", "The mill", "Built in 1724, the old watermill turned the river's fall into flour for the whole valley."), 0)
		await index.save(profileID, Self.page("https://news.example/bridge", "The bridge", "The stone bridge came later, after the railway."), 0)

		let hits = await index.search(profileID, "waterm flour", 10)
		#expect(hits.map(\.url.absoluteString) == ["https://news.example/mill"])
		let passage = try #require(hits.first?.passage)
		#expect(passage.contains("watermill"))
		#expect(passage.contains("flour"))

		// Accents don't matter, and another profile has its own pages.
		await index.save(profileID, Self.page("https://news.example/cafe", "Café", "A café on the square."), 0)
		#expect(await index.search(profileID, "cafe", 10).map(\.url.absoluteString) == ["https://news.example/cafe"])
		#expect(await index.search(other, "flour", 10).isEmpty)
		// Words only: quotes, brackets and stars in the query can't break it.
		#expect(await index.search(profileID, "\"flour\" (valley) *", 10).map(\.url.absoluteString) == ["https://news.example/mill"])
		#expect(await index.search(profileID, "  ", 10).isEmpty)
	}

	@Test
	internal func aPageVisitedAgainKeepsOnlyItsNewText() async throws {
		let (index, _) = try Self.index()
		await index.save(profileID, Self.page("https://news.example/live", "Live", "Morning: fog over the harbour."), 0)
		await index.save(profileID, Self.page("https://news.example/live", "Live", "Evening: storm warnings."), 0)
		#expect(await index.search(profileID, "harbour", 10).isEmpty)
		#expect(await index.search(profileID, "storm", 10).count == 1)
	}

	@Test
	internal func eachPageKeepsAtMostItsFirstCharacters() {
		let long = String(repeating: "word ", count: 10_000)
		#expect(PageTextStore.bounded(long).count == PageTextIndexClient.maximumCharacters)
		#expect(PageTextStore.matchExpression("old  water-mill?") == "\"old\"* \"water\"* \"mill\"*")
	}

	@Test
	internal func theOldestPagesGoPastTheLimit() async throws {
		let (index, _) = try Self.index()
		let limit = PageTextIndexClient.maximumPages
		for number in 0...limit {
			await index.save(profileID, Self.page(
				"https://pages.example/\(number)",
				"Page \(number)",
				"marker\(number) text",
				visited: Date(timeIntervalSince1970: TimeInterval(number))
			), 0)
		}
		#expect(await index.search(profileID, "marker0", 10).isEmpty)
		#expect(await index.search(profileID, "marker1", 1).first?.url.absoluteString == "https://pages.example/1")
		#expect(await index.search(profileID, "marker\(limit)", 10).count == 1)
	}

	/// Clear History deletes the file; a range or Delete from History removes those pages, and
	/// their words aren't left anywhere in the file.
	@Test
	internal func clearingHistoryClearsTheIndex() async throws {
		let (index, directory) = try Self.index()
		await index.save(profileID, Self.page("https://a.example/", "A", "zanzibarword alpha", visited: Date(timeIntervalSince1970: 100)), 0)
		await index.save(profileID, Self.page("https://b.example/", "B", "quokkaword beta", visited: Date(timeIntervalSince1970: 200)), 0)
		await index.save(profileID, Self.page("https://c.example/", "C", "pangolinword gamma", visited: Date(timeIntervalSince1970: 300)), 0)

		await index.clearSince(profileID, Date(timeIntervalSince1970: 250), 1)
		#expect(await index.search(profileID, "pangolinword", 10).isEmpty)
		await index.retain(profileID, [URL(string: "https://a.example/")!], 2)
		#expect(await index.search(profileID, "quokkaword", 10).isEmpty)
		#expect(await index.search(profileID, "zanzibarword", 10).count == 1)
		let file = directory.appending(path: profileID.rawValue.uuidString + ".text.sqlite")
		let bytes = try Data(contentsOf: file)
		#expect(bytes.range(of: Data("quokkaword".utf8)) == nil)
		#expect(bytes.range(of: Data("pangolinword".utf8)) == nil)

		await index.clear(profileID, 3)
		#expect(!FileManager.default.fileExists(atPath: file.path))
		#expect(await index.search(profileID, "zanzibarword", 10).isEmpty)
		#expect(await index.size(profileID) == nil)
	}

	/// A page read before a clear, range or prune isn't saved after it, however late it arrives;
	/// one read since is.
	@Test
	internal func aPageReadBeforeAClearIsNeverSavedAfterIt() async throws {
		let (index, _) = try Self.index()
		await index.clear(profileID, 1)
		await index.save(profileID, Self.page("https://a.example/", "A", "zanzibarword"), 0)
		#expect(await index.search(profileID, "zanzibarword", 10).isEmpty)
		await index.save(profileID, Self.page("https://a.example/", "A", "zanzibarword"), 1)
		#expect(await index.search(profileID, "zanzibarword", 10).count == 1)

		await index.retain(profileID, [], 2)
		await index.save(profileID, Self.page("https://b.example/", "B", "quokkaword"), 1)
		#expect(await index.search(profileID, "quokkaword", 10).isEmpty)
		// A prune from before arrives late: the page saved since keeps its words.
		await index.retain(profileID, [URL(string: "https://a.example/")!, URL(string: "https://b.example/")!], 4)
		await index.save(profileID, Self.page("https://b.example/", "B", "quokkaword"), 4)
		await index.retain(profileID, [URL(string: "https://a.example/")!], 3)
		await index.clear(profileID, 3)
		#expect(await index.search(profileID, "quokkaword", 10).count == 1)
		// Another profile's clears are its own.
		await index.save(other, Self.page("https://b.example/", "B", "quokkaword"), 0)
		#expect(await index.search(other, "quokkaword", 10).count == 1)
	}

	/// DEV-1098: removals run in their own tasks, so one can arrive after a newer one that doesn't
	/// cover it, such as a narrower range. Each still takes the pages read before it, and none read
	/// since; Clear History in order still deletes the file.
	@Test
	internal func aRemovalThatArrivesLateStillTakesItsPages() async throws {
		let (index, directory) = try Self.index()
		await index.save(profileID, Self.page("https://a.example/", "A", "alphaword", visited: Date(timeIntervalSince1970: 50)), 0)
		await index.save(profileID, Self.page("https://b.example/", "B", "betaword", visited: Date(timeIntervalSince1970: 150)), 0)
		await index.save(profileID, Self.page("https://c.example/", "C", "gammaword", visited: Date(timeIntervalSince1970: 250)), 0)

		// Clear since 200 (generation 2) runs before clear since 100 (generation 1).
		await index.clearSince(profileID, Date(timeIntervalSince1970: 200), 2)
		#expect(await index.search(profileID, "gammaword", 10).isEmpty)
		#expect(await index.search(profileID, "betaword", 10).count == 1)
		await index.clearSince(profileID, Date(timeIntervalSince1970: 100), 1)
		#expect(await index.search(profileID, "betaword", 10).isEmpty)
		#expect(await index.search(profileID, "alphaword", 10).count == 1)
		let file = directory.appending(path: profileID.rawValue.uuidString + ".text.sqlite")
		#expect(try Data(contentsOf: file).range(of: Data("betaword".utf8)) == nil)

		// A page read after both stays through them, however late they arrive.
		await index.save(profileID, Self.page("https://d.example/", "D", "deltaword", visited: Date(timeIntervalSince1970: 160)), 2)
		await index.clearSince(profileID, Date(timeIntervalSince1970: 100), 1)
		#expect(await index.search(profileID, "deltaword", 10).count == 1)

		// A late Clear History takes every page read before it, but not one read since.
		await index.save(profileID, Self.page("https://e.example/", "E", "epsilonword", visited: Date(timeIntervalSince1970: 300)), 3)
		await index.clearSince(profileID, Date(timeIntervalSince1970: 10_000), 4)
		await index.clear(profileID, 3)
		#expect(await index.search(profileID, "alphaword", 10).isEmpty)
		#expect(await index.search(profileID, "deltaword", 10).isEmpty)
		#expect(await index.search(profileID, "epsilonword", 10).count == 1)
		let bytes = try Data(contentsOf: file)
		#expect(bytes.range(of: Data("alphaword".utf8)) == nil)
		#expect(bytes.range(of: Data("deltaword".utf8)) == nil)

		// In order, Clear History deletes the file.
		await index.clear(profileID, 5)
		#expect(!FileManager.default.fileExists(atPath: file.path))
		#expect(await index.size(profileID) == nil)
	}

	/// DEV-1098: reads of one page save in their own tasks too. One from before the text already
	/// saved, arriving after it, is dropped, so a clear between them never keeps the older words
	/// under the newer read.
	@Test
	internal func anOlderReadOfAPageNeverReplacesANewerOne() async throws {
		let (index, directory) = try Self.index()
		await index.save(profileID, Self.page("https://a.example/", "A", "newerword"), 1)
		await index.save(profileID, Self.page("https://a.example/", "A", "olderword"), 0)
		#expect(await index.search(profileID, "olderword", 10).isEmpty)

		await index.clear(profileID, 1)
		#expect(await index.search(profileID, "newerword", 10).count == 1)
		#expect(await index.search(profileID, "olderword", 10).isEmpty)
		let file = directory.appending(path: profileID.rawValue.uuidString + ".text.sqlite")
		#expect(try Data(contentsOf: file).range(of: Data("olderword".utf8)) == nil)

		// Read before and after a clear that arrives late, with nothing else to remove: the page
		// stays, its earlier words don't.
		await index.save(other, Self.page("https://b.example/", "B", "earlierword"), 0)
		await index.save(other, Self.page("https://b.example/", "B", "laterword"), 1)
		await index.clear(other, 1)
		#expect(await index.search(other, "laterword", 10).count == 1)
		#expect(await index.search(other, "earlierword", 10).isEmpty)
		let otherFile = directory.appending(path: other.rawValue.uuidString + ".text.sqlite")
		#expect(try Data(contentsOf: otherFile).range(of: Data("earlierword".utf8)) == nil)

		// The same for a prune, as Delete from History sends, that arrives late.
		let third: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
		await index.save(third, Self.page("https://c.example/", "C", "firstword"), 0)
		await index.save(third, Self.page("https://c.example/", "C", "secondword"), 1)
		await index.retain(third, [], 1)
		#expect(await index.search(third, "secondword", 10).count == 1)
		#expect(await index.search(third, "firstword", 10).isEmpty)
		let thirdFile = directory.appending(path: third.rawValue.uuidString + ".text.sqlite")
		#expect(try Data(contentsOf: thirdFile).range(of: Data("firstword".utf8)) == nil)
	}

	/// How much disk 1,000 pages take, each the full `maximumCharacters` of prose-like text from a
	/// 20,000-word vocabulary, common words common as in real text.
	@Test
	internal func thousandPagesStayWellUnderTheBudget() async throws {
		let (index, _) = try Self.index()
		var generator = SeededGenerator(seed: 1068)
		let vocabulary = (0..<20_000).map { Self.word($0) }
		for number in 0..<1_000 {
			var words: [String] = []
			var length = 0
			while length < PageTextIndexClient.maximumCharacters {
				// Zipf-like: low ranks far more often.
				let rank = Int(pow(Double.random(in: 0..<1, using: &generator), 3) * Double(vocabulary.count))
				let word = vocabulary[min(rank, vocabulary.count - 1)]
				words.append(word)
				length += word.count + 1
			}
			await index.save(profileID, Self.page("https://pages.example/\(number)", "Page \(number)", words.joined(separator: " ")), 0)
		}
		let size = try #require(await index.size(profileID))
		print("PAGE_TEXT_INDEX_BYTES_PER_1000_PAGES \(size)")
		#expect(size < 20 * 1_024 * 1_024)
	}

	// MARK: - Fixture

	private static func index() throws -> (PageTextIndexClient, URL) {
		let directory = FileManager.default.temporaryDirectory.appending(path: "page-text-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		return (.local(directory: directory), directory)
	}

	private static func page(
		_ url: String,
		_ title: String,
		_ text: String,
		visited: Date = Date(timeIntervalSince1970: 1_000)
	) -> PageText {
		.init(url: URL(string: url)!, title: title, text: text, visited: visited)
	}

	/// A pronounceable word for each number, 3 to 10 letters.
	private static func word(_ number: Int) -> String {
		let consonants = Array("bcdfghjklmnprstvwz")
		let vowels = Array("aeiou")
		var value = number + 7
		var word = ""
		repeat {
			word.append(consonants[value % consonants.count])
			value /= consonants.count
			word.append(vowels[value % vowels.count])
			value /= vowels.count
		} while value > 0
		return word + String(repeating: "n", count: number % 3)
	}
}

/// A small deterministic generator, so the size measured is the same every run.
private struct SeededGenerator: RandomNumberGenerator {
	private var state: UInt64

	init(seed: UInt64) {
		self.state = seed
	}

	mutating func next() -> UInt64 {
		state &+= 0x9E37_79B9_7F4A_7C15
		var value = state
		value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
		value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
		return value ^ (value >> 31)
	}
}
