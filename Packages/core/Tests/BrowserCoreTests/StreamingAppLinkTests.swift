import BrowserCore
import Foundation
import Testing

internal struct StreamingAppLinkTests {
	@Test(arguments: [
		("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC", "spotify:track:4uLU6hMCjMI75M1A2tKUQC"),
		("https://open.spotify.com/intl-de/album/1A2b3C?si=abc", "spotify:album:1A2b3C"),
		("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M", "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"),
		("https://open.spotify.com/", "spotify:"),
		("https://open.spotify.com/search/jazz", "spotify:"),
		("https://open.spotify.com/track/not-an-id", "spotify:"),
	])
	internal func spotifyPagesOpenTheSameItemInTheApp(
		page: String,
		app: String
	) async throws {
		#expect(StreamingAppLink.url(for: URL(string: page)!) == URL(string: app))
	}

	@Test
	internal func otherSitesHaveNoApp() async throws {
		#expect(StreamingAppLink.url(for: URL(string: "https://www.netflix.com/watch/1")!) == nil)
		#expect(StreamingAppLink.url(for: URL(string: "https://www.spotify.com/")!) == nil)
		#expect(StreamingAppLink.url(for: URL(string: "http://open.spotify.com/track/1")!) == nil)
	}
}
