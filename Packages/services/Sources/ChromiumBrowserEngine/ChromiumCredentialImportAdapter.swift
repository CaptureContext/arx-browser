import BrowserEngineClient
import ChromiumEngine
import Foundation

/// Maps the migration assistant's credential records to ABI46 and back (DEV-830).
/// Calls go in chunks no larger than native takes in one call.
internal enum ChromiumCredentialImportAdapter {
	internal static let passwordChunk: Int = 10_000
	internal static let cookieChunk: Int = 20_000

	/// Seconds between 1601-01-01 and 1970-01-01, both UTC.
	private static let windowsEpochOffset: Double = 11_644_473_600

	/// A date as Chromium stores it: microseconds since 1601-01-01 UTC.
	internal static func chromiumTime(_ date: Date) -> Int64 {
		let microseconds = ((date.timeIntervalSince1970 + windowsEpochOffset) * 1_000_000).rounded()
		guard microseconds.isFinite, microseconds > 0 else { return 0 }
		guard microseconds < Double(Int64.max) else { return .max }

		return Int64(microseconds)
	}

	internal static func password(_ record: BrowserImportedPassword) -> ChromiumImportedPassword {
		.init(
			url: record.url,
			signonRealm: record.signonRealm,
			username: record.username,
			password: record.password
		)
	}

	internal static func cookie(_ record: BrowserImportedCookie) -> ChromiumImportedCookie {
		.init(
			domain: record.domain,
			name: record.name,
			value: record.value,
			path: record.path,
			topFrameSiteKey: record.topFrameSiteKey,
			creationUTC: chromiumTime(record.created),
			expiresUTC: chromiumTime(record.expires),
			lastAccessUTC: chromiumTime(record.lastAccessed),
			isSecure: record.isSecure,
			isHTTPOnly: record.isHTTPOnly,
			hasCrossSiteAncestor: record.hasCrossSiteAncestor,
			sameSite: clamped(record.sameSite),
			priority: clamped(record.priority),
			sourceScheme: clamped(record.sourceScheme),
			sourcePort: clamped(record.sourcePort)
		)
	}

	internal static func passwordKey(_ key: ChromiumPasswordKey) -> BrowserPasswordKey {
		.init(signonRealm: key.signonRealm, username: key.username, dateCreated: key.dateCreated)
	}

	internal static func passwordKey(_ key: BrowserPasswordKey) -> ChromiumPasswordKey {
		.init(signonRealm: key.signonRealm, username: key.username, dateCreated: key.dateCreated)
	}

	internal static func cookieKey(_ key: ChromiumCookieKey) -> BrowserCookieKey {
		.init(
			domain: key.domain,
			name: key.name,
			path: key.path,
			topFrameSiteKey: key.topFrameSiteKey,
			hasCrossSiteAncestor: key.hasCrossSiteAncestor,
			sourceScheme: Int(key.sourceScheme),
			sourcePort: Int(key.sourcePort)
		)
	}

	internal static func cookieKey(_ key: BrowserCookieKey) -> ChromiumCookieKey {
		.init(
			domain: key.domain,
			name: key.name,
			path: key.path,
			topFrameSiteKey: key.topFrameSiteKey,
			hasCrossSiteAncestor: key.topFrameSiteKey.isEmpty ? false : key.hasCrossSiteAncestor,
			sourceScheme: clamped(key.sourceScheme),
			sourcePort: clamped(key.sourcePort)
		)
	}

	internal static func failure(_ error: any Error) -> BrowserCredentialImportFailure {
		guard let error = error as? ChromiumCredentialImportFailure else { return .failed }

		return switch error {
		case .unavailable: .unavailable
		case .invalid: .invalid
		case .busy: .busy
		case .failed: .failed
		}
	}

	/// Out-of-range values become one native rejects, never a silently different one.
	private static func clamped(_ value: Int) -> Int32 {
		Int32(clamping: value)
	}

	/// What a chunked import kept, and the input rows none of `parts` covers.
	internal struct Chunked<Element, Partial> {
		internal var parts: [Partial]

		/// Rows of the failed chunk, the chunks after it and the chunks rolled back:
		/// none of them is stored. Callers count them as skipped or rejected.
		internal var omitted: [Element]
	}

	/// Runs `call` for each chunk in order. A call that throws wrote nothing
	/// (native replies OK, with unconfirmed keys, for any failure after a write
	/// began). Then each chunk already written is rolled back on its own. When
	/// every rollback succeeds the error is rethrown: nothing persisted. A chunk
	/// whose rollback fails is kept as a partial result, so its keys reach the
	/// caller's undo record, and every other row is listed as omitted, so the
	/// caller's counts still cover the whole input.
	@MainActor
	internal static func inChunks<Element, Partial>(
		_ elements: [Element],
		of size: Int,
		_ call: @MainActor (ArraySlice<Element>) async throws -> Partial,
		rollback: @MainActor (Partial) async -> Bool
	) async throws -> Chunked<Element, Partial> {
		var done: [(chunk: ArraySlice<Element>, partial: Partial)] = []
		for chunk in chunks(elements, of: size) {
			do {
				done.append((chunk, try await call(chunk)))
			} catch {
				var kept: [Partial] = []
				var omitted: [Element] = []
				for (written, partial) in done {
					if await rollback(partial) {
						omitted += written
					} else {
						kept.append(partial)
					}
				}
				guard !kept.isEmpty else { throw error }

				omitted += elements[chunk.startIndex...]
				return .init(parts: kept, omitted: omitted)
			}
		}
		return .init(parts: done.map(\.partial), omitted: [])
	}

	/// Native refuses a keys argument over 16 MiB (`kMaximumKeysBytes`); batches
	/// stay well under it, whatever the keys' lengths.
	internal static let keyBatchBytes: Int = 12 * 1024 * 1024

	/// Splits keys into batches native takes: at most `count` keys and `bytes` of
	/// encoded JSON each, measured with the encoder the engine uses. A key is
	/// never split, and one alone always fits: the engine refuses fields over
	/// `ChromiumCredentialImport.maximumFieldBytes` before import.
	internal static func keyBatches<Key: Encodable>(
		_ keys: [Key],
		count: Int,
		bytes: Int = keyBatchBytes
	) -> [[Key]] {
		let encoder = JSONEncoder()
		var batches: [[Key]] = []
		var current: [Key] = []
		var size = 2
		for key in keys {
			let keySize = ((try? encoder.encode(key).count) ?? bytes) + 1
			if !current.isEmpty, current.count == count || size + keySize > bytes {
				batches.append(current)
				current = []
				size = 2
			}
			current.append(key)
			size += keySize
		}
		if !current.isEmpty { batches.append(current) }
		return batches
	}

	/// The key native reports for a cookie it never saw.
	internal static func cookieKey(_ record: BrowserImportedCookie) -> BrowserCookieKey {
		.init(
			domain: record.domain,
			name: record.name,
			path: record.path,
			topFrameSiteKey: record.topFrameSiteKey,
			hasCrossSiteAncestor: record.topFrameSiteKey.isEmpty ? false : record.hasCrossSiteAncestor,
			sourceScheme: record.sourceScheme,
			sourcePort: record.sourcePort
		)
	}

	/// Runs one chunk's undo; false when it failed, so the chunk's keys are kept.
	@MainActor
	internal static func rollBack(_ undo: @MainActor () async throws -> Int) async -> Bool {
		do {
			_ = try await undo()
			return true
		} catch {
			return false
		}
	}

	internal static func chunks<Element>(
		_ elements: [Element],
		of size: Int
	) -> [ArraySlice<Element>] {
		stride(from: 0, to: elements.count, by: size).map {
			elements[$0..<min($0 + size, elements.count)]
		}
	}
}
