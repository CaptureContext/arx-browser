import BrowserCore
import BrowserEngineClient
import Foundation
import _Dependencies

/// Reading mode's reader (DEV-1028): whether a page looks like it has an article, and the
/// article itself, read in the engine's developer world. Private pages, WebKit pages and pages
/// that aren't http(s) have neither: the engine runs no script there.
public struct PageReaderClient: Sendable {
	/// The `ARX_READING_MODE` feature flag.
	public var isEnabled: @Sendable () -> Bool
	public var isReadable: @MainActor @Sendable (Tab.ID) async -> Bool

	/// The page's article, or nil when it has none, or it changed page while it was read.
	public var article: @MainActor @Sendable (Tab.ID) async -> ReaderArticle?

	public init(
		isEnabled: @escaping @Sendable () -> Bool = { false },
		isReadable: @escaping @MainActor @Sendable (Tab.ID) async -> Bool = { _ in false },
		article: @escaping @MainActor @Sendable (Tab.ID) async -> ReaderArticle? = { _ in nil }
	) {
		self.isEnabled = isEnabled
		self.isReadable = isReadable
		self.article = article
	}
}

/// What the client does with the engine's `evaluateScript`, apart from the engine, so it can be
/// tested with any script runner.
public enum PageReader {
	/// The engine runs one script at a time in a tab: a busy tab is asked again after a moment.
	public static let busyRetries: Int = 3

	public static func isReadable(
		_ tabID: Tab.ID,
		evaluate: BrowserEngineClient.EvaluateScript,
		pause: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
	) async -> Bool {
		let outcome = await run(
			PageReaderScripts.probe,
			in: tabID,
			timeout: 2_000,
			evaluate: evaluate,
			pause: pause
		)
		guard case let .value(json) = outcome else { return false }

		return json == "true"
	}

	public static func article(
		_ tabID: Tab.ID,
		evaluate: BrowserEngineClient.EvaluateScript,
		pause: @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(250)) }
	) async -> ReaderArticle? {
		let outcome = await run(
			PageReaderScripts.extract,
			in: tabID,
			timeout: 10_000,
			evaluate: evaluate,
			pause: pause
		)
		guard
			case let .value(json) = outcome,
			let extraction = try? JSONDecoder().decode(PageReaderScripts.Extraction.self, from: Data(json.utf8)),
			let url = URL(string: extraction.url),
			url.scheme == "https" || url.scheme == "http",
			(0...PageReaderScripts.maximumArticleLength).contains(extraction.length)
		else { return nil }

		var html = extraction.chunk
		var offset = extraction.next
		while offset < extraction.length {
			let outcome = await run(
				PageReaderScripts.slice(from: offset),
				in: tabID,
				timeout: 2_000,
				evaluate: evaluate,
				pause: pause
			)
			guard
				case let .value(json) = outcome,
				let slice = try? JSONDecoder().decode(PageReaderScripts.Slice.self, from: Data(json.utf8)),
				slice.next > offset
			else { return nil }

			html += slice.chunk
			offset = slice.next
		}

		return .init(
			url: url,
			title: extraction.title,
			byline: extraction.byline,
			siteName: extraction.siteName,
			excerpt: extraction.excerpt,
			language: extraction.lang,
			isRightToLeft: extraction.dir?.lowercased() == "rtl",
			html: html
		)
	}

	/// Runs a script, asking again while the tab is busy with another one.
	private static func run(
		_ script: String,
		in tabID: Tab.ID,
		timeout: Int,
		evaluate: BrowserEngineClient.EvaluateScript,
		pause: @Sendable () async -> Void
	) async -> BrowserScriptOutcome? {
		for attempt in 0...busyRetries {
			do {
				return try await evaluate(tabID, script, PageReaderScripts.maximumResultBytes, timeout, { true })
			} catch .busy where attempt < busyRetries {
				await pause()
			} catch {
				return nil
			}
		}
		return nil
	}
}

extension PageReaderClient: DependencyKey {
	public static var liveValue: Self {
		.init(
			isEnabled: { ReadingMode.isOn },
			isReadable: { tabID in
				@Dependency(\.browserEngine)
				var engine

				return await PageReader.isReadable(tabID, evaluate: engine.evaluateScript)
			},
			article: { tabID in
				@Dependency(\.browserEngine)
				var engine

				return await PageReader.article(tabID, evaluate: engine.evaluateScript)
			}
		)
	}

	public static var testValue: Self { .init() }
}

extension DependencyValues {
	public var pageReader: PageReaderClient {
		get { self[PageReaderClient.self] }
		set { self[PageReaderClient.self] = newValue }
	}
}
