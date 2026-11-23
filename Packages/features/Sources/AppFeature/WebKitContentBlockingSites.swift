import BrowserCore
import BrowserEngineClient
import Foundation

/// Each profile's content blocking exceptions for WebKit pages (DEV-877), read from the same
/// site settings Chromium pages' uBlock Origin follows and read again whenever they change.
@MainActor
internal final class WebKitContentBlockingSites {
	private let client: BrowserEngineClient
	private var settings: [Profile.ID: SiteSettings] = [:]
	private var reading: Set<Profile.ID> = []
	private var changes: Task<Void, Never>?

	/// A profile's exceptions arrived or changed: open pages apply them again.
	internal var onChange: @MainActor () -> Void = {}

	internal init(client: BrowserEngineClient) {
		self.client = client
	}

	deinit {
		changes?.cancel()
	}

	internal func start() {
		guard changes == nil else { return }
		let stream = client.siteSettingsChanges()
		changes = Task { [weak self] in
			for await profile in stream {
				guard let self, self.settings[profile] != nil else { continue }
				self.read(profile)
			}
		}
	}

	/// Whether content blocking applies to `url` in `profile`. Until a profile's exceptions are
	/// read it blocks, and reads them.
	internal func blocksContent(
		_ profile: Profile.ID,
		_ url: URL
	) -> Bool {
		guard
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			let scheme = components.scheme,
			let host = components.encodedHost,
			let origin = SiteSettings.origin("\(scheme)://\(host)\(components.port.map { ":\($0)" } ?? "")")
		else { return true }

		guard let profileSettings = settings[profile] else {
			read(profile)
			return true
		}
		return profileSettings.blocksContent(on: origin)
	}

	private func read(_ profile: Profile.ID) {
		guard reading.insert(profile).inserted else { return }
		Task { [weak self, client] in

			// A profile without site settings (a private one) has no exceptions.
			let listing = (try? await client.siteSettings(profile)) ?? SiteSettings()
			guard let self else { return }
			self.reading.remove(profile)
			guard listing != self.settings[profile] else { return }
			self.settings[profile] = listing
			self.onChange()
		}
	}
}
