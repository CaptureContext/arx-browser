#if DEBUG
import BrowserCore
import BrowserWorkspaceClient
import Darwin
import Foundation

/// Only this explicit fresh-root runner may exercise Settings against real CRX
/// packages. It changes no production admission or signature-verifier behavior.
internal struct ExtensionSettingsSmokeFixture: Sendable {
	internal static let argument: String = "--arx-extension-settings-smoke-root"

	/// Starts the app again on the profile the initial run left behind.
	internal static let relaunchArgument: String = "--arx-extension-settings-smoke-relaunch"
	internal static let completionName: String = "completion.json"
	internal static let relaunchCompletionName: String = "relaunch-completion.json"
	internal static let sentinel: String = "Arx extension Settings disposable fixture v1\n"
	internal static let packageNames: Set<String> = ["v1.crx", "v2.crx", "other-key.crx", "corrupt.crx"]
	internal static let unpackedFolder: String = "unpacked"
	internal static let invalidFolder: String = "unpacked-invalid"
	internal static let unreadableFolder: String = "unpacked-unreadable"
	internal static let missingFolder: String = "unpacked-missing"
	internal static let profileA: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
	internal static let profileB: Profile.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
	internal static let spaceA: Space.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!)
	internal static let spaceB: Space.ID = .init(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!)

	internal let root: URL
	internal let profile: URL
	internal let configuration: Configuration
	internal let phase: Phase

	internal init(
		root: URL,
		profile: URL,
		configuration: Configuration,
		phase: Phase = .initial
	) {
		self.root = root
		self.profile = profile
		self.configuration = configuration
		self.phase = phase
	}

	/// The initial run starts from an empty profile and leaves the unpacked
	/// folder loaded. The relaunch run reopens that same profile after the
	/// initial run exited cleanly and checks what Chromium restored.
	internal enum Phase: Sendable, Equatable {
		case initial
		case relaunch

		internal var completionName: String {
			switch self {
			case .initial: ExtensionSettingsSmokeFixture.completionName
			case .relaunch: ExtensionSettingsSmokeFixture.relaunchCompletionName
			}
		}
	}

	internal struct Configuration: Codable, Sendable {
		internal let version: Int
		internal let application: URL
		internal let baseURL: URL
		internal let extensionID: String
		internal let packages: [String: String]

		internal init(
			version: Int = 1,
			application: URL,
			baseURL: URL,
			extensionID: String,
			packages: [String: String]
		) {
			self.version = version
			self.application = application
			self.baseURL = baseURL
			self.extensionID = extensionID
			self.packages = packages
		}
	}

	internal enum Failure: String, Error {
		case invalidFixture, unavailable, timedOut, invalidInventory, invalidPrompt, staleInventory
		case unexpectedConsent, unexpectedProfile, worker, invalidPackageAccepted, cleanup
		case developerControls, unpackedError, unpackedLoad, unpackedReload, unpackedRelaunch
		case siteMenu, extensionsPill, extensionWindow
	}

	internal static func isRequested(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		environment["ARX_EXTENSION_SETTINGS_SMOKE_ROOT"] != nil || arguments.contains(argument)
	}

	internal static func load(
		environment: [String: String],
		arguments: [String],
		application: URL
	) throws -> Self? {
		guard isRequested(environment: environment, arguments: arguments) else { return nil }
		guard
			!RoutingSmokeFixture.isRequested(environment: environment, arguments: arguments),
			!ProfileRetirementSmoke.isRequested(environment: environment, arguments: arguments),
			!ExternalConsentFixture.isRequested(environment: environment, arguments: arguments),
			environment["ARX_MCP_SMOKE_ROOT"] == nil,
			environment["ARX_ENGINE_SMOKE_TITLE"] == nil,
			arguments.filter({ $0 == argument }).count == 1,
			arguments.filter({ $0 == relaunchArgument }).count <= 1,
			let index = arguments.firstIndex(of: argument),
			arguments.indices.contains(index + 1),
			let path = environment["ARX_EXTENSION_SETTINGS_SMOKE_ROOT"],
			path.hasPrefix("/"),
			arguments[index + 1] == path,
			let profilePath = environment["ARX_ENGINE_PROFILE"],
			profilePath.hasPrefix("/")
		else { throw Failure.invalidFixture }

		let phase: Phase = arguments.contains(relaunchArgument) ? .relaunch : .initial
		let root = URL(fileURLWithPath: path).standardizedFileURL
		let profile = URL(fileURLWithPath: profilePath).standardizedFileURL
		guard
			root.lastPathComponent.hasPrefix("app-extension-install-smoke-"),
			root.resolvingSymlinksInPath() == root,
			profile == root.appendingPathComponent("profile"),
			valid(root, kind: S_IFDIR, permissions: 0o700),
			valid(profile, kind: S_IFDIR, permissions: 0o700),
			try profileMatches(phase, root: root, profile: profile),
			try read(root.appendingPathComponent(".arx-extension-settings-smoke"), maximum: 128) == Data(sentinel.utf8)
		else { throw Failure.invalidFixture }

		let configuration = try JSONDecoder().decode(
			Configuration.self,
			from: read(root.appendingPathComponent("fixture.json"), maximum: 8192)
		)
		let parts = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)
		guard
			configuration.version == 1,
			configuration.application.isFileURL,
			sameFile(configuration.application, application),
			parts?.scheme == "http",
			parts?.host == "127.0.0.1",
			(1...65535).contains(parts?.port ?? 0),
			parts?.user == nil,
			parts?.password == nil,
			parts?.query == nil,
			parts?.fragment == nil,
			parts?.path == "/index.html",
			environment["ARX_ENGINE_URL"] == configuration.baseURL.absoluteString,
			configuration.extensionID.utf8.count == 32,
			configuration.extensionID.utf8.allSatisfy({ (97...112).contains($0) }),
			Set(configuration.packages.keys) == packageNames,
			configuration.packages.values.allSatisfy({ digest in
				digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
			}),
			packageNames.allSatisfy({ valid(root.appendingPathComponent($0), kind: S_IFREG, permissions: 0o600) }),
			valid(root.appendingPathComponent(unpackedFolder), kind: S_IFDIR, permissions: 0o700),
			valid(root.appendingPathComponent(invalidFolder), kind: S_IFDIR, permissions: 0o700),
			valid(root.appendingPathComponent(unreadableFolder), kind: S_IFDIR, permissions: 0),
			!FileManager.default.fileExists(atPath: root.appendingPathComponent(missingFolder).path)
		else { throw Failure.invalidFixture }

		return .init(root: root, profile: profile, configuration: configuration, phase: phase)
	}

	/// The initial run needs an empty profile. A relaunch needs the workspace
	/// the initial run saved and its clean exit record, and runs only once.
	private static func profileMatches(
		_ phase: Phase,
		root: URL,
		profile: URL
	) throws -> Bool {
		let contents = try FileManager.default.contentsOfDirectory(atPath: profile.path)
		let relaunchCompletion = root.appendingPathComponent(relaunchCompletionName)
		switch phase {
		case .initial:
			return contents.isEmpty

		case .relaunch:
			var record = stat()
			return contents.contains("arx-workspace.json")
			&& valid(profile.appendingPathComponent("arx-workspace.json"), kind: S_IFREG)
			&& valid(root.appendingPathComponent(completionName), kind: S_IFREG, permissions: 0o600)
			&& lstat(relaunchCompletion.path, &record) != 0
		}
	}

	internal func seedWorkspace() throws {
		// A relaunch keeps the workspace the initial run saved.
		guard phase == .initial else { return }

		let organization = BrowserOrganization(
			profiles: [
				.init(id: Self.profileA, name: "Install A"),
				.init(id: Self.profileB, name: "Install B"),
			],
			legacyProfileID: Self.profileA,
			spaces: [
				.init(id: Self.spaceA, profileID: Self.profileA, name: "Install A"),
				.init(id: Self.spaceB, profileID: Self.profileB, name: "Install B"),
			],
			tabs: []
		)
		try BrowserWorkspaceClient(file: profile.appendingPathComponent("arx-workspace.json"))
			.save(organization, preferences: .init())
	}

	internal func recordCleanExit() throws {
		let destination = root.appendingPathComponent(phase.completionName)
		let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard descriptor >= 0 else { throw Failure.cleanup }

		let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		try file.write(contentsOf: Data("{\"status\":\"cleanExit\"}\n".utf8))
		try file.close()
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
		&& firstInfo.st_mode & S_IFMT == S_IFDIR
		&& secondInfo.st_mode & S_IFMT == S_IFDIR
	}

	private static func valid(
		_ url: URL,
		kind: mode_t,
		permissions: mode_t? = nil
	) -> Bool {
		var value = stat()
		return lstat(url.path, &value) == 0
		&& value.st_uid == getuid()
		&& value.st_mode & S_IFMT == kind
		&& (permissions.map { value.st_mode & 0o777 == $0 } ?? true)
	}

	private static func read(
		_ url: URL,
		maximum: Int
	) throws -> Data {
		let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { throw Failure.invalidFixture }

		let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		var value = stat()
		guard
			fstat(descriptor, &value) == 0,
			value.st_uid == getuid(),
			value.st_mode & S_IFMT == S_IFREG,
			value.st_mode & 0o777 == 0o600,
			value.st_size > 0,
			value.st_size <= maximum,
			let data = try file.read(upToCount: maximum + 1),
			data.count <= maximum
		else { throw Failure.invalidFixture }

		try file.close()
		return data
	}
}
#endif
