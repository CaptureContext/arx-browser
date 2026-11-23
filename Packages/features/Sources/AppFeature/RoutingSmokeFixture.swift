#if DEBUG
import BrowserCore
import BrowserWorkspaceClient
import Darwin
import Foundation

/// Only the external-launch runner can opt into this disposable startup path.
internal struct RoutingSmokeFixture: Sendable {
	internal static let sentinel: String = "Arx external routing fixture v1\n"
	internal static let argument: String = "--arx-routing-smoke-root"
	internal let root: URL
	internal let profile: URL
	internal let configuration: Configuration

	internal init(
		root: URL,
		profile: URL,
		configuration: Configuration
	) {
		self.root = root
		self.profile = profile
		self.configuration = configuration
	}

	internal struct Configuration: Codable, Sendable {
		internal let version: Int
		internal let application: URL
		internal let mode: RoutingWindowMode
		internal let urls: [URL]

		internal init(
			version: Int = 1,
			application: URL,
			mode: RoutingWindowMode,
			urls: [URL]
		) {
			self.version = version
			self.application = application
			self.mode = mode
			self.urls = urls
		}
	}

	internal enum Failure: String, Error {
		case invalidFixture, unexpectedReceipt, unexpectedCommit, incorrectDestination
		case missingSession, timedOut, persistedTemporaryPage, unexpectedHistory, resultExists
	}

	internal static func isRequested(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		environment["ARX_ROUTING_SMOKE_ROOT"] != nil || arguments.contains(argument)
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
			let path = environment["ARX_ROUTING_SMOKE_ROOT"],
			arguments[index + 1] == path,
			let profilePath = environment["ARX_ENGINE_PROFILE"],
			path.hasPrefix("/"), profilePath.hasPrefix("/")
		else { throw Failure.invalidFixture }

		let root = URL(fileURLWithPath: path).standardizedFileURL
		let profile = URL(fileURLWithPath: profilePath).standardizedFileURL
		guard
			root.lastPathComponent.hasPrefix("routing-smoke-"),
			root.resolvingSymlinksInPath() == root,
			profile == root.appendingPathComponent("profile"),
			validFile(root, kind: S_IFDIR, permissions: 0o700),
			validFile(profile, kind: S_IFDIR, permissions: 0o700),
			try FileManager.default.contentsOfDirectory(atPath: profile.path).isEmpty,
			try read(root.appendingPathComponent(".arx-routing-smoke"), maximumBytes: 128) == Data(sentinel.utf8)
		else { throw Failure.invalidFixture }

		let data = try read(root.appendingPathComponent("fixture.json"), maximumBytes: 8192)
		let configuration = try JSONDecoder().decode(Configuration.self, from: data)
		guard
			configuration.version == 1,
			configuration.application.isFileURL,
			sameFile(configuration.application, application),
			configuration.urls.count == 4,
			let first = configuration.urls.first,
			let port = first.port,
			(1...65535).contains(port),
			configuration.urls == expectedURLs(port: port)
		else { throw Failure.invalidFixture }

		return .init(root: root, profile: profile, configuration: configuration)
	}

	internal static func expectedURLs(port: Int) -> [URL] {
		let base = "http://127.0.0.1:\(port)"
		let first = URL(string: base + "/routing/a/1?value=%E6%9D%B1%E4%BA%AC%2Fcaf%C3%A9%2B100%25#first")!
		return [
			first,
			URL(string: base + "/routing/b/2?value=two%20words%26more#second")!,
			first,
			URL(string: base + "/routing/b/4?value=%3F%21%3D#last")!,
		]
	}

	internal var organization: BrowserOrganization {
		.init(
			profiles: [
				.init(id: Self.profileA, name: "Routing A"),
				.init(id: Self.profileB, name: "Routing B"),
			],
			legacyProfileID: Self.profileA,
			spaces: [
				.init(id: Self.spaceA, profileID: Self.profileA, name: "Destination A"),
				.init(id: Self.spaceB, profileID: Self.profileB, name: "Destination B"),
			],
			tabs: []
		)
	}

	internal var preferences: BrowserPreferences {
		var preferences = BrowserPreferences()
		preferences.routing = .init(rules: [
			.init(
				id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
				name: "External B", host: "127.0.0.1", scheme: "http",
				port: configuration.urls[0].port, pathPrefix: "/routing/b/",
				destination: .init(scope: .space(Self.spaceB), mode: configuration.mode)
			),
		], fallback: .init(scope: .space(Self.spaceA), mode: configuration.mode))
		return preferences
	}

	internal func seedWorkspace() throws {
		let workspace = BrowserWorkspaceClient(file: profile.appendingPathComponent("arx-workspace.json"))
		try workspace.save(organization, preferences: preferences)
	}

	/// Published only after Chromium returns normally, not when page assertions finish.
	internal func recordCleanExit() throws {
		let value: [String: Any] = [
			"status": "cleanExit",
			"pid": ProcessInfo.processInfo.processIdentifier,
			"application": configuration.application.resolvingSymlinksInPath().path,
			"profile": profile.path,
			"mode": configuration.mode.rawValue,
		]
		let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
		let destination = root.appendingPathComponent("completion.json")
		let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw Failure.resultExists }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		try handle.write(contentsOf: data)
		try handle.close()
	}

	internal func target(at index: Int) -> RoutingTarget {
		let isA = index == 0 || index == 2
		return .init(
			profileID: isA ? Self.profileA : Self.profileB,
			spaceID: isA ? Self.spaceA : Self.spaceB,
			mode: configuration.mode
		)
	}

	internal static let profileA: Profile.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
	)
	internal static let profileB: Profile.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
	)
	internal static let spaceA: Space.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
	)
	internal static let spaceB: Space.ID = .init(
		rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
	)

	private static func read(
		_ url: URL,
		maximumBytes: Int
	) throws -> Data {
		let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
		guard descriptor >= 0 else { throw Failure.invalidFixture }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var information = stat()
		guard
			fstat(descriptor, &information) == 0,
			information.st_uid == getuid(),
			information.st_mode & S_IFMT == S_IFREG,
			information.st_mode & 0o777 == 0o600,
			(1...maximumBytes).contains(Int(information.st_size)),
			let data = try handle.read(upToCount: maximumBytes + 1),
			data.count <= maximumBytes
		else { throw Failure.invalidFixture }
		try handle.close()
		return data
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

	private static func validFile(
		_ url: URL,
		kind: mode_t,
		permissions: mode_t
	) -> Bool {
		var information = stat()
		return lstat(url.path, &information) == 0
		&& information.st_uid == getuid()
		&& information.st_mode & S_IFMT == kind
		&& information.st_mode & 0o777 == permissions
	}
}
#endif
