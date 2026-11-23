import Foundation

/// The app that plays a streaming site's page when Arx can't (DEV-1000): a link that opens the
/// same item in the site's own Mac app. Only Spotify's player has one so far.
public enum StreamingAppLink {
	/// Items the Spotify app opens by `spotify:<kind>:<id>`.
	private static let spotifyKinds: Set<String> = [
		"album", "artist", "audiobook", "chapter", "episode", "playlist", "show", "track", "user",
	]

	/// The app link for `page`, or nil when no app plays its site. A Spotify page that isn't one
	/// item opens the app as it is.
	public static func url(for page: URL) -> URL? {
		guard
			page.scheme?.lowercased() == "https",
			let host = WebKitPagePreferences.host(of: page),
			WebKitPagePreferences.covers("open.spotify.com", host: host)
		else { return nil }

		// `/intl-de/track/<id>` is the same track as `/track/<id>`.
		let parts = page.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
		guard
			parts.count >= 2,
			spotifyKinds.contains(parts[0]),
			parts[1].allSatisfy({ $0.isLetter || $0.isNumber })
		else { return URL(string: "spotify:") }

		return URL(string: "spotify:\(parts[0]):\(parts[1])")
	}
}
