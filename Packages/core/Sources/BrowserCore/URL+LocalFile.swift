import Foundation

extension URL {
	/// DEV-987. A local file page's address as people read it: its path, with the home folder
	/// as `~` (`~/Developer/report/index.html`). Nil for anything but a `file:` URL on this Mac.
	public var localFileDisplayPath: String? {
		guard URLRouter.isLocalFile(self) else { return nil }

		return (path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
	}
}
