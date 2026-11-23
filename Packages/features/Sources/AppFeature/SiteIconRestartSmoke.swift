#if DEBUG
import BrowserCore
import BrowserSiteIconClient
import Darwin
import Foundation

@MainActor
internal enum SiteIconRestartSmoke {
	internal static func run(
		client: BrowserSiteIconClient,
		organization: BrowserOrganization,
		root: URL,
		profileDirectory: URL,
		baseURL: URL,
		iconOrigin: SiteIconSmoke.IconOrigin,
		prepareProfile: @MainActor (Profile.ID) async throws -> Void
	) async throws {
		try SiteIconSmokeFixture.validate(root: root, profile: profileDirectory, baseURL: baseURL)
		let manifest = try SiteIconRestartManifest.read(from: root)
		try manifest.validate(organization: organization, baseURL: baseURL)
		let profiles = Set(organization.profiles.map(\.id))
		let primary = Profile.ID(rawValue: manifest.primaryProfile)
		let secondary = Profile.ID(rawValue: manifest.secondaryProfile)
		client.configureProfiles([primary, secondary])
		defer { client.configureProfiles(profiles) }

		// Profiles load on demand (DEV-880), and an unloaded profile's icons come from Arx's
		// stored copies, not Chromium's database. The point here is the database, so both
		// profiles load first, as they do when one of their pages opens (DEV-965).
		try await prepareProfile(primary)
		try await prepareProfile(secondary)

		// No page is created or navigated in this process. Both reads use the
		// preconstructed application client and the databases from the first run.
		try await verify(
			client.icons(.init(profileID: primary, pageURL: manifest.savedURL)),
			color: [0, 0, 255]
		)
		try await verify(
			client.icons(.init(profileID: secondary, pageURL: manifest.savedURL)),
			color: [0, 255, 0]
		)

		// Fetched for a saved page that never loaded, then kept in the profile database.
		try await verify(
			client.icons(.init(profileID: primary, pageURL: iconOrigin.declaredPage)),
			color: [255, 255, 0]
		)
		print("ARX_SITE_ICONS_RESTART_SUCCESS")
		fflush(stdout)
	}

	internal static func verify(
		_ stream: AsyncStream<Data?>,
		color: [UInt8],
		timeout: Duration = .seconds(10)
	) async throws {
		try Task.checkCancellation()
		try await withThrowingTaskGroup(of: Void.self) { group in
			group.addTask {
				try Task.checkCancellation()
				for await data in stream {
					try Task.checkCancellation()
					if await SiteIconSmoke.matches(data, color: color) {
						return
					}
				}
				try Task.checkCancellation()
				throw SiteIconSmoke.Failure.missingDatabaseIcon
			}
			group.addTask {
				try await Task.sleep(for: timeout)
				throw SiteIconSmoke.Failure.timedOut("restart database read")
			}
			defer { group.cancelAll() }
			_ = try await group.next()
		}
	}
}

internal struct SiteIconRestartManifest: Codable, Equatable {
	internal static let filename: String = ".arx-site-icons-restart.json"
	internal let version: Int
	internal let primaryProfile: UUID
	internal let secondaryProfile: UUID
	internal let legacyProfile: UUID
	internal let savedURL: URL

	internal init(
		version: Int = 1,
		primaryProfile: UUID,
		secondaryProfile: UUID,
		legacyProfile: UUID,
		savedURL: URL
	) {
		self.version = version
		self.primaryProfile = primaryProfile
		self.secondaryProfile = secondaryProfile
		self.legacyProfile = legacyProfile
		self.savedURL = savedURL
	}

	internal func validate(
		organization: BrowserOrganization,
		baseURL: URL
	) throws {
		let legacy = organization.legacyProfileID ?? organization.profiles.first?.id
		let expectedURL = baseURL.deletingLastPathComponent().appendingPathComponent("site-icons/page.html")
		guard
			version == 1,
			primaryProfile != secondaryProfile,
			organization.profiles.contains(where: { $0.id.rawValue == primaryProfile }),
			!organization.profiles.contains(where: { $0.id.rawValue == secondaryProfile }),
			legacy?.rawValue == legacyProfile,
			savedURL == expectedURL
		else { throw SiteIconSmoke.Failure.invalidFixture }
	}

	internal func write(to root: URL) throws {
		let data = try JSONEncoder().encode(self)
		guard data.count <= 4096
		else { throw SiteIconSmoke.Failure.invalidFixture }
		let descriptor = open(root.appendingPathComponent(Self.filename).path, O_WRONLY | O_NOFOLLOW)
		guard descriptor >= 0
		else { throw SiteIconSmoke.Failure.invalidFixture }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		guard Self.valid(descriptor, empty: true)
		else { throw SiteIconSmoke.Failure.invalidFixture }
		try handle.write(contentsOf: data)
		try handle.close()
	}

	internal static func read(from root: URL) throws -> Self {
		let descriptor = open(root.appendingPathComponent(filename).path, O_RDONLY | O_NOFOLLOW)
		guard descriptor >= 0
		else { throw SiteIconSmoke.Failure.invalidFixture }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		guard valid(descriptor, empty: false)
		else { throw SiteIconSmoke.Failure.invalidFixture }
		guard let data = try handle.read(upToCount: 4097), data.count <= 4096
		else { throw SiteIconSmoke.Failure.invalidFixture }
		try handle.close()
		return try JSONDecoder().decode(Self.self, from: data)
	}

	private static func valid(
		_ descriptor: Int32,
		empty: Bool
	) -> Bool {
		var info = stat()
		guard
			fstat(descriptor, &info) == 0,
			info.st_uid == getuid(),
			info.st_mode & S_IFMT == S_IFREG,
			info.st_mode & 0o777 == 0o600
		else { return false }
		return empty ? info.st_size == 0 : (1...4096).contains(info.st_size)
	}
}
#endif
