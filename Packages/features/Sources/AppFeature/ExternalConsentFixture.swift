#if DEBUG
import Darwin
import Foundation

/// Read-only admission happens before mock Keychain, workspace initialization,
/// or the ordinary profile fallback. Native startup independently rechecks it.
internal struct ExternalConsentFixture: Sendable {
	internal static let argument: String = "--arx-external-consent-smoke-root"
	internal let root: URL
	internal let profile: URL

	internal init(
		root: URL,
		profile: URL
	) {
		self.root = root
		self.profile = profile
	}

	internal struct Configuration: Codable, Sendable {
		internal let version: Int
		internal let application: URL

		internal init(
			version: Int = 1,
			application: URL
		) {
			self.version = version
			self.application = application
		}
	}

	internal enum Failure: Error {
		case invalidFixture
	}

	internal static func isRequested(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"] != nil || arguments.contains(argument)
	}

	internal static func load(
		environment: [String: String],
		arguments: [String],
		application: URL
	) throws -> Self? {
		guard isRequested(environment: environment, arguments: arguments) else { return nil }
		guard
			arguments.filter({ $0 == argument }).count == 1,
			let index = arguments.firstIndex(of: argument),
			arguments.indices.contains(index + 1),
			let rootPath = environment["ARX_EXTERNAL_CONSENT_FIXTURE_ROOT"],
			arguments[index + 1] == rootPath,
			let profilePath = environment["ARX_ENGINE_PROFILE"],
			rootPath.hasPrefix("/"),
			profilePath.hasPrefix("/"),
			let executablePath = arguments.first,
			executablePath.hasPrefix("/"),
			application.isFileURL
		else { throw Failure.invalidFixture }

		let root = URL(fileURLWithPath: rootPath).standardizedFileURL
		let profile = URL(fileURLWithPath: profilePath).standardizedFileURL
		guard
			root.path == rootPath,
			profile.path == profilePath,
			root.lastPathComponent.hasPrefix("app-smoke-"),
			root.resolvingSymlinksInPath() == root,
			profile == root.appendingPathComponent("profile"),
			profile.resolvingSymlinksInPath() == profile,
			validDirectory(root),
			validDirectory(profile),
			sameFile(
				URL(fileURLWithPath: executablePath),
				application.appending(path: "Contents/MacOS/Arx")
			),
			!FileManager.default.fileExists(atPath: root.appending(path: "external-consent.receipt").path)
		else { throw Failure.invalidFixture }

		let token = try read(root.appending(path: ".arx-external-consent"), limit: 32)
		guard
			token.count == 32,
			token.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
		else { throw Failure.invalidFixture }

		let bytes = try read(root.appending(path: "external-consent-fixture.json"), limit: 4096)
		let configuration = try JSONDecoder().decode(Configuration.self, from: bytes)
		guard
			configuration.version == 1,
			configuration.application.isFileURL,
			sameFile(configuration.application, application)
		else { throw Failure.invalidFixture }

		return .init(root: root, profile: profile)
	}

	private static func validDirectory(_ url: URL) -> Bool {
		var info = stat()
		return lstat(url.path, &info) == 0
			&& info.st_uid == getuid()
			&& info.st_mode & S_IFMT == S_IFDIR
			&& info.st_mode & 0o777 == 0o700
	}

	private static func sameFile(
		_ first: URL,
		_ second: URL
	) -> Bool {
		var firstInfo = stat()
		var secondInfo = stat()
		return stat(first.path, &firstInfo) == 0
			&& stat(second.path, &secondInfo) == 0
			&& firstInfo.st_dev == secondInfo.st_dev
			&& firstInfo.st_ino == secondInfo.st_ino
	}

	private static func read(
		_ url: URL,
		limit: Int
	) throws -> Data {
		let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
		guard descriptor >= 0 else { throw Failure.invalidFixture }

		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var info = stat()
		guard
			fstat(descriptor, &info) == 0,
			info.st_uid == getuid(),
			info.st_mode & S_IFMT == S_IFREG,
			info.st_mode & 0o777 == 0o600,
			info.st_nlink == 1,
			(1...limit).contains(Int(info.st_size)),
			let bytes = try handle.read(upToCount: limit + 1),
			bytes.count <= limit
		else { throw Failure.invalidFixture }

		try handle.close()
		return bytes
	}
}
#endif
