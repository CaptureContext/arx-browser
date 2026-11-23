import BrowserCore
import Foundation

/// The Netscape bookmarks file every major browser reads and writes.
///
/// It only knows folders and links, so an export turns profiles and spaces into
/// folders and leaves regular tabs out, and `MigrationExportSummary` says so.
public enum BookmarksHTML {
	internal static let marker: String = "NETSCAPE-Bookmark-file"

	// MARK: - Export

	public static func export(
		_ organization: BrowserOrganization
	) -> (html: String, summary: MigrationExportSummary) {
		let tabs = Dictionary(uniqueKeysWithValues: organization.tabs.map { ($0.id, $0) })
		let folders = Dictionary(uniqueKeysWithValues: organization.folders.map { ($0.id, $0) })
		var summary: MigrationExportSummary = .init(
			profiles: 0,
			spaces: 0,
			folders: 0,
			tabs: 0,
			omittedRegularTabs: 0
		)
		var lines = [
			"<!DOCTYPE NETSCAPE-Bookmark-file-1>",
			"<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->",
			"<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">",
			"<TITLE>Bookmarks</TITLE>",
			"<H1>Bookmarks</H1>",
			"<DL><p>",
		]

		func link(
			_ id: BrowserCore.Tab.ID,
			depth: Int
		) {
			guard let tab = tabs[id] else { return }

			summary.tabs += 1
			let title = tab.customTitle ?? tab.savedDestination?.title ?? tab.restoration.title
			let href = escape(tab.reopeningURL.absoluteString)
			lines.append(indent(depth) + "<DT><A HREF=\"\(href)\">\(escape(title))</A>")
		}

		func open(
			_ name: String,
			depth: Int
		) {
			lines.append(indent(depth) + "<DT><H3>\(escape(name))</H3>")
			lines.append(indent(depth) + "<DL><p>")
		}

		func close(depth: Int) {
			lines.append(indent(depth) + "</DL><p>")
		}

		func write(
			_ items: [SavedItem],
			depth: Int
		) {
			for item in items {
				switch item {
				case let .tab(id):
					link(id, depth: depth)

				case let .folder(id):
					guard let folder = folders[id] else { continue }

					summary.folders += 1
					open(folder.name, depth: depth)
					write(folder.children, depth: depth + 1)
					close(depth: depth)
				}
			}
		}

		for profile in organization.profiles {
			summary.profiles += 1
			open(profile.name, depth: 1)
			if !profile.favorites.isEmpty {
				// The folder's name inside the exported file, which another browser shows; services have
				// no string catalog, so it stays English (DEV-1291).
				open("Favorites", depth: 2)
				for favorite in profile.favorites { link(favorite, depth: 3) }
				close(depth: 2)
			}
			for space in organization.spaces where space.profileID == profile.id {
				summary.spaces += 1
				summary.omittedRegularTabs += space.unpinnedTabs.count
				open(space.name, depth: 2)
				write(space.savedItems, depth: 3)
				close(depth: 2)
			}
			close(depth: 1)
		}
		lines.append("</DL><p>")
		return (lines.joined(separator: "\n") + "\n", summary)
	}

	private static func indent(_ depth: Int) -> String {
		String(repeating: "    ", count: depth)
	}

	private static func escape(_ text: String) -> String {
		text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
	}

	// MARK: - Import

	/// Reads the structure only: scripts and other markup in the file are never
	/// interpreted. A link's identity is its folder, URL and occurrence, so importing
	/// the same or a newer file again adds only what's new, and repeats stay.
	internal static func snapshot(
		html: String,
		space: MigrationSourceSpace
	) throws -> MigrationSnapshot {
		guard html.range(of: marker, options: .caseInsensitive) != nil
		else { throw MigrationFailure.invalidFile }

		var reader = Reader(space: space)
		reader.read(html)
		let snapshotID = MigrationBrowserSources.snapshotID(reader.records)
		return .init(id: snapshotID, records: reader.records)
	}

	private struct Reader {
		private var levels: [Level]
		private var pendingFolder: MigrationSourceFolder?
		private var occurrences: [String: Int]
		internal let space: MigrationSourceSpace
		internal var records: [MigrationRecord]

		internal init(space: MigrationSourceSpace) {
			self.levels = [.init(folders: [])]
			self.pendingFolder = nil
			self.occurrences = [:]
			self.space = space
			self.records = []
		}

		private struct Level {
			internal var folders: [MigrationSourceFolder]
			internal var isEmpty: Bool
			internal var folderNames: [String: Int]

			internal init(
				folders: [MigrationSourceFolder],
				isEmpty: Bool = true,
				folderNames: [String: Int] = [:]
			) {
				self.folders = folders
				self.isEmpty = isEmpty
				self.folderNames = folderNames
			}
		}

		private static let maximumDepth: Int = 128

		private static let token: NSRegularExpression = {
			// The patterns are constant and known to compile.
			try! NSRegularExpression(
				pattern: #"<h3\b[^>]*>(.*?)</h3\s*>|<a\b([^>]*)>(.*?)</a\s*>|<(/?)dl\b[^>]*>"#,
				options: [.caseInsensitive, .dotMatchesLineSeparators]
			)
		}()

		private static let href: NSRegularExpression = {
			try! NSRegularExpression(
				pattern: #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
				options: [.caseInsensitive]
			)
		}()

		internal mutating func read(_ html: String) {
			let text = html as NSString
			let range = NSRange(location: 0, length: text.length)
			for match in Self.token.matches(in: html, range: range) {
				if match.range(at: 1).location != NSNotFound {
					beginFolder(Self.plainText(text.substring(with: match.range(at: 1))))
				} else if match.range(at: 2).location != NSNotFound {
					addLink(
						attributes: text.substring(with: match.range(at: 2)),
						title: Self.plainText(text.substring(with: match.range(at: 3)))
					)
				} else if text.substring(with: match.range(at: 4)).isEmpty {
					openList()
				} else {
					closeList()
				}
			}
		}

		private mutating func beginFolder(_ name: String) {
			let parent = levels[levels.count - 1]
			let count = parent.folderNames[name, default: 0]
			levels[levels.count - 1].folderNames[name] = count + 1
			levels[levels.count - 1].isEmpty = false
			let path = parent.folders.last?.id ?? ""
			pendingFolder = .init(id: "\(path)/\(name)#\(count)", name: name)
		}

		private mutating func openList() {
			// The file's outermost list has no folder of its own.
			guard let folder = pendingFolder else { return }

			pendingFolder = nil
			guard levels.count < Self.maximumDepth else { return }

			levels.append(.init(folders: levels[levels.count - 1].folders + [folder]))
		}

		private mutating func closeList() {
			guard levels.count > 1 else { return }

			let level = levels.removeLast()
			if level.isEmpty, let folder = level.folders.last {
				records.append(.init(
					sourceItemID: "folder:" + folder.id,
					kind: .folder,
					category: .bookmarks,
					folders: level.folders,
					space: space
				))
			}
		}

		private mutating func addLink(
			attributes: String,
			title: String
		) {
			let text = attributes as NSString
			let range: NSRange = .init(location: 0, length: text.length)
			guard let match = Self.href.firstMatch(in: attributes, range: range)
			else { return }

			let group = match.range(at: 1).location != NSNotFound ? 1 : 2
			let url = Self.decode(text.substring(with: match.range(at: group)))
			let folders = levels[levels.count - 1].folders
			levels[levels.count - 1].isEmpty = false
			let identity = (folders.last?.id ?? "") + "\u{1F}" + url
			let occurrence = occurrences[identity, default: 0]
			occurrences[identity] = occurrence + 1
			records.append(.init(
				sourceItemID: identity + "\u{1F}\(occurrence)",
				category: .bookmarks,
				title: title,
				url: url,
				folders: folders,
				space: space
			))
		}

		private static func plainText(_ html: String) -> String {
			decode(html.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression))
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		private static func decode(_ text: String) -> String {
			guard text.contains("&") else { return text }

			var result = ""
			var rest = Substring(text)
			while let start = rest.firstIndex(of: "&") {
				result += rest[..<start]
				rest = rest[start...]
				guard
					let end = rest.prefix(12).firstIndex(of: ";"),
					let decoded = entity(String(rest[rest.index(after: start)..<end]))
				else {
					result += "&"
					rest = rest.dropFirst()
					continue
				}
				result += decoded
				rest = rest[rest.index(after: end)...]
			}
			return result + rest
		}

		private static func entity(_ name: String) -> String? {
			switch name.lowercased() {
			case "amp": return "&"

			case "lt": return "<"

			case "gt": return ">"

			case "quot": return "\""

			case "apos": return "'"

			case "nbsp": return " "

			default:
				guard name.hasPrefix("#") else { return nil }

				let digits = name.dropFirst()
				let value = digits.lowercased().hasPrefix("x")
				? UInt32(digits.dropFirst(), radix: 16)
				: UInt32(digits)
				return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
			}
		}
	}
}
