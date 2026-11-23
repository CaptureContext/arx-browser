import Foundation

/// Files the user picks: an Arx transfer archive or a bookmarks HTML file. The file is
/// only read, and is read again before committing so a changed file is reviewed again.
public enum MigrationFileSources {
	public static func adapter(for url: URL) throws -> MigrationSourceAdapter {
		let data = try read(url)
		if data.prefix(4096).range(of: Data(BookmarksHTML.marker.utf8)) != nil {
			return bookmarks(url)
		}
		let archive = try ArxTransferArchive.decode(data)
		return .init(
			source: .init(
				id: archiveSourceID,
				kind: .arxArchive,
				name: url.deletingPathExtension().lastPathComponent,
				version: archive.appVersion,
				categories: archive.importableCategories,
				preservesOrganization: true
			),
			snapshot: {
				try ArxTransferArchive.decode(try read(url)).snapshot
			}
		)
	}

	/// The same for every archive, so a newer export from the same browser adds to what
	/// an older one brought rather than repeating it.
	internal static let archiveSourceID: MigrationSource.ID = .init(rawValue: "arx-archive")

	private static func bookmarks(_ url: URL) -> MigrationSourceAdapter {
		let name = url.deletingPathExtension().lastPathComponent
		let profile = MigrationSourceProfile(id: "bookmarks-html", name: name)
		let space = MigrationSourceSpace(
			id: profile.id + MigrationBrowserSources.spaceSeparator + name,
			name: name,
			profile: profile
		)
		return .init(
			source: .init(
				id: .init(rawValue: "bookmarks-html:" + name),
				kind: .externalBrowser,
				name: name,
				categories: [.bookmarks],
				offersLayouts: true
			),
			snapshot: {
				let html = String(decoding: try read(url), as: UTF8.self)
				return try BookmarksHTML.snapshot(html: html, space: space)
			}
		)
	}

	private static func read(_ url: URL) throws -> Data {
		let size: Int
		do {
			size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
		} catch {
			throw MigrationFailure.unreadableSource(error.localizedDescription)
		}
		guard size <= ArxTransferArchive.maximumSize
		else { throw MigrationFailure.fileTooLarge }

		do {
			return try Data(contentsOf: url)
		} catch {
			throw MigrationFailure.unreadableSource(error.localizedDescription)
		}
	}
}
