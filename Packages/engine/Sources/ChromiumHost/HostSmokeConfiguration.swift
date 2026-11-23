import Darwin
import Foundation

/// A mock Keychain is allowed only for the runner's fresh, local fixture directory.
internal struct HostSmokeConfiguration {
	internal static let argument: String = "--disposable-smoke-root"
	internal static let marker: String = "Arx disposable engine smoke\n"
	internal let profileDirectory: URL

	internal init(profileDirectory: URL) {
		self.profileDirectory = profileDirectory
	}

	internal static func resolve(
		arguments: [String],
		environment: [String: String],
		workDirectory: URL
	) throws -> Self? {
		if arguments.count == 1, environment["ARX_ENGINE_SMOKE_TITLE"] == nil { return nil }
		guard
			arguments.count == 3,
			arguments[1] == argument,
			arguments[2].hasPrefix("/")
		else { throw Failure.invalidFixture }
		let root = URL(filePath: arguments[2]).standardizedFileURL
		let files = FileManager.default
		guard
			root == root.resolvingSymlinksInPath(),
			root.deletingLastPathComponent() == workDirectory.resolvingSymlinksInPath().standardizedFileURL,
			root.lastPathComponent.hasPrefix("smoke-"),
			root.lastPathComponent.count <= 64
		else { throw Failure.invalidFixture }
		let attributes = try files.attributesOfItem(atPath: root.path)
		guard
			attributes[.type] as? FileAttributeType == .typeDirectory,
			(attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
			(attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
			Set(try files.contentsOfDirectory(atPath: root.path)) == ["index.html", ".arx-engine-smoke"]
		else { throw Failure.invalidFixture }
		let marker = try fixtureFile(root.appending(path: ".arx-engine-smoke"), maximumBytes: 128)
		let page = try fixtureFile(root.appending(path: "index.html"), maximumBytes: 4096)
		guard
			String(data: marker, encoding: .utf8) == Self.marker,
			String(data: page, encoding: .utf8)?.contains("<title>Arx engine smoke</title>") == true
		else { throw Failure.invalidFixture }
		let profile = root.appending(path: "profile")
		guard
			environment["ARX_ENGINE_PROFILE"] == profile.path,
			environment["ARX_ENGINE_SMOKE_TITLE"] == "Arx engine smoke",
			let rawURL = environment["ARX_ENGINE_URL"],
			let url = URLComponents(string: rawURL),
			url.scheme == "http",
			url.host == "127.0.0.1",
			url.path == "/index.html",
			let port = url.port,
			(1...65535).contains(port),
			url.user == nil,
			url.password == nil,
			url.query == nil,
			url.fragment == nil
		else { throw Failure.invalidFixture }
		return .init(profileDirectory: profile)
	}

	private static func fixtureFile(
		_ url: URL,
		maximumBytes: Int
	) throws -> Data {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		guard
			attributes[.type] as? FileAttributeType == .typeRegular,
			let size = attributes[.size] as? NSNumber,
			size.intValue <= maximumBytes
		else { throw Failure.invalidFixture }
		return try Data(contentsOf: url)
	}

	internal enum Failure: Error {
		case invalidFixture
	}
}
