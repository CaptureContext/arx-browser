import Foundation

/// The HLS playlist a page hands its media element for FairPlay (DEV-1144). The helper plays
/// only a playlist whose every resource is https and whose keys are https or `skd://`, so a
/// page can't point the player at local files or other schemes.
public enum FairPlayPlaylist {
	/// Whether the helper may play `playlist`.
	public static func isAcceptable(_ playlist: String) -> Bool {
		guard
			playlist.utf8.count <= FairPlayLimits.maximumPlaylistLength,
			playlist.hasPrefix("#EXTM3U")
		else { return false }

		for raw in playlist.split(whereSeparator: \.isNewline) {
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.isEmpty { continue }
			guard line.hasPrefix("#") else {
				guard line.lowercased().hasPrefix("https://") else { return false }
				continue
			}
			for uri in attributeURIs(in: line) {
				let lowercased = uri.lowercased()
				guard lowercased.hasPrefix("https://") || lowercased.hasPrefix("skd://")
				else { return false }
			}
		}
		return true
	}

	/// Whether `playlist` has a FairPlay key: an `skd://` key URI.
	public static func hasFairPlayKey(_ playlist: String) -> Bool {
		playlist.split(whereSeparator: \.isNewline).contains { line in
			line.hasPrefix("#EXT-X-KEY") && attributeURIs(in: String(line)).contains { $0.lowercased().hasPrefix("skd://") }
		}
	}

	/// Every `URI="…"` value of a tag line.
	private static func attributeURIs(in line: String) -> [String] {
		var uris: [String] = []
		var rest = Substring(line)
		while let start = rest.range(of: "URI=\"") {
			rest = rest[start.upperBound...]
			guard let end = rest.firstIndex(of: "\"") else { break }
			uris.append(String(rest[..<end]))
			rest = rest[rest.index(after: end)...]
		}
		return uris
	}
}

/// Splits a pipe's bytes into lines, newline-terminated, each at most
/// `FairPlayLimits.maximumLineBytes`. A longer line means the other side misbehaves.
public struct FairPlayLineBuffer: Sendable {
	private var pending: Data = Data()

	public init() {}

	public enum Failure: Error, Equatable {
		case lineTooLong
	}

	/// Appends `data` and returns every line it completes, without their newlines.
	public mutating func append(_ data: Data) throws(Failure) -> [Data] {
		pending.append(data)
		var lines: [Data] = []
		while let newline = pending.firstIndex(of: 0x0A) {
			lines.append(Data(pending[pending.startIndex..<newline]))
			pending.removeSubrange(pending.startIndex...newline)
		}
		guard pending.count <= FairPlayLimits.maximumLineBytes
		else { throw .lineTooLong }

		return lines
	}

	/// `message` followed by a newline.
	public static func line(_ message: Data) -> Data {
		message + Data([0x0A])
	}
}
