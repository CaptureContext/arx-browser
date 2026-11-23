import BrowserCore
import Foundation
import _Dependencies

/// Carries out a page's link for another app (DEV-857): runs the person's script, opens the
/// app macOS assigns, or copies the link.
///
/// Reducers reach it as `@Dependency(\.appLinks)`, so tests drive every outcome with doubles.
public struct AppLinkClient: Sendable {
	/// Runs `/bin/zsh -c <script> arx-link <link>` and waits for it, at most ``AppLinkScript/timeout``.
	public var runScript: @Sendable (AppLinkScript) async -> AppLinkScriptOutcome

	/// Opens the link in `application`, or in the app macOS assigns to its scheme when nil.
	/// A chosen app that's gone is reported, never swapped for another (DEV-862).
	public var openApp: @MainActor @Sendable (URL, AppLinkApplication?) async -> AppLinkOpenOutcome

	/// Puts the link on the general pasteboard.
	public var copyLink: @MainActor @Sendable (String) -> Void

	/// The display name of the app that opens `url`, when macOS knows one.
	public var appName: @MainActor @Sendable (URL) -> String?

	/// Where the app that opens `url` is, when macOS knows one: the prompt shows its icon.
	public var appPath: @MainActor @Sendable (URL) -> String?

	/// The apps macOS registers for a scheme, for a sample link `scheme://`, default first.
	public var applicationsForScheme: @MainActor @Sendable (String) -> [AppLinkApplicationChoice]

	/// Installed apps that register URL schemes, by name: declared in `CFBundleURLTypes` or
	/// registered with Launch Services while they ran (DEV-1259).
	public var installedApplications: @Sendable () async -> [AppLinkApplicationChoice]

	/// Choose…: an open panel for one `.app` anywhere on disk. Nil when cancelled or unreadable.
	public var chooseApplication: @MainActor @Sendable () async -> AppLinkApplicationChoice?

	/// The app with a bookmark, made now if it has none, so it's found again after a move.
	public var bookmarked: @MainActor @Sendable (AppLinkApplication) -> AppLinkApplication

	public init(
		runScript: @escaping @Sendable (AppLinkScript) async -> AppLinkScriptOutcome,
		openApp: @escaping @MainActor @Sendable (URL, AppLinkApplication?) async -> AppLinkOpenOutcome,
		copyLink: @escaping @MainActor @Sendable (String) -> Void,
		appName: @escaping @MainActor @Sendable (URL) -> String? = { _ in nil },
		appPath: @escaping @MainActor @Sendable (URL) -> String? = { _ in nil },
		applicationsForScheme: @escaping @MainActor @Sendable (String) -> [AppLinkApplicationChoice] = { _ in [] },
		installedApplications: @escaping @Sendable () async -> [AppLinkApplicationChoice] = { [] },
		chooseApplication: @escaping @MainActor @Sendable () async -> AppLinkApplicationChoice? = { nil },
		bookmarked: @escaping @MainActor @Sendable (AppLinkApplication) -> AppLinkApplication = { $0 }
	) {
		self.runScript = runScript
		self.openApp = openApp
		self.copyLink = copyLink
		self.appName = appName
		self.appPath = appPath
		self.applicationsForScheme = applicationsForScheme
		self.installedApplications = installedApplications
		self.chooseApplication = chooseApplication
		self.bookmarked = bookmarked
	}
}

/// An app the picker offers, with the schemes it declares.
public struct AppLinkApplicationChoice: Equatable, Sendable {
	public var application: AppLinkApplication

	/// From `CFBundleURLTypes`, lowercased, without web schemes, in the app's order.
	public var schemes: [String]

	public init(
		application: AppLinkApplication,
		schemes: [String]
	) {
		self.application = application
		self.schemes = schemes
	}

	/// The schemes an app's `CFBundleURLTypes` declare that a handler may take, once each.
	public static func schemes(fromURLTypes types: Any?) -> [String] {
		guard let types = types as? [[String: Any]] else { return [] }
		var seen: Set<String> = []
		return types
			.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
			.map { $0.lowercased() }
			.filter { AppLinkHandler.schemeProblem($0) == nil && seen.insert($0).inserted }
	}
}

public enum AppLinkOpenOutcome: Equatable, Sendable {
	case opened

	/// Opened in the chosen app, found somewhere else: the app as it is now, with its new path
	/// and a fresh bookmark, for the handler to keep.
	case openedMoved(AppLinkApplication)

	/// No app opened it: none is registered for the scheme, or the launch failed.
	case didNotOpen

	/// The chosen app isn't where it was, and its bookmark doesn't find it either.
	case applicationMissing
}

/// One run of a handler's script.
public struct AppLinkScript: Equatable, Sendable {
	/// Thirty seconds, as decided for DEV-857.
	public static let defaultTimeout: Duration = .seconds(30)

	public var script: String

	/// Already validated: the script gets it as `$1` and `ARX_LINK`, never spliced into its text.
	public var link: String
	public var scheme: String
	public var profileID: String
	public var profileName: String

	/// The page's origin, never its full URL. Empty when unknown.
	public var sourceOrigin: String
	public var timeout: Duration

	public init(
		script: String,
		link: String,
		scheme: String,
		profileID: String,
		profileName: String,
		sourceOrigin: String,
		timeout: Duration = Self.defaultTimeout
	) {
		self.script = script
		self.link = link
		self.scheme = scheme
		self.profileID = profileID
		self.profileName = profileName
		self.sourceOrigin = sourceOrigin
		self.timeout = timeout
	}

	/// The arguments after `/bin/zsh`: the link is `$1`, `arx-link` is `$0`.
	public var arguments: [String] {
		["-c", script, "arx-link", link]
	}

	/// What the script finds in its environment on top of the inherited one.
	public var environment: [String: String] {
		[
			"ARX_LINK": link,
			"ARX_LINK_SCHEME": scheme,
			"ARX_PROFILE_ID": profileID,
			"ARX_PROFILE_NAME": profileName,
			"ARX_SOURCE_ORIGIN": sourceOrigin,
		]
	}
}

public enum AppLinkScriptOutcome: Equatable, Sendable {
	/// The script exited with 0.
	case succeeded(log: URL?)

	/// A non-zero exit, with the end of its standard error.
	case failed(status: Int32, message: String, log: URL?)

	/// It ran past its timeout and was stopped.
	case timedOut(log: URL?)

	/// It couldn't start.
	case unavailable(String)

	public var succeeded: Bool {
		if case .succeeded = self { return true }
		return false
	}

	public var log: URL? {
		switch self {
		case let .succeeded(log), let .timedOut(log): log
		case let .failed(_, _, log): log
		case .unavailable: nil
		}
	}
}

// MARK: - Dependency

extension AppLinkClient: DependencyKey {
	public static var liveValue: Self { .live }

	/// Tests must supply their own client, so an unexpected script or launch fails the test.
	public static var testValue: Self {
		.init(
			runScript: unimplemented("AppLinkClient.runScript", placeholder: .unavailable("test")),
			openApp: unimplemented("AppLinkClient.openApp", placeholder: .didNotOpen),
			copyLink: unimplemented("AppLinkClient.copyLink"),
			appName: unimplemented("AppLinkClient.appName", placeholder: nil),
			appPath: unimplemented("AppLinkClient.appPath", placeholder: nil),
			applicationsForScheme: unimplemented("AppLinkClient.applicationsForScheme", placeholder: []),
			installedApplications: unimplemented("AppLinkClient.installedApplications", placeholder: []),
			chooseApplication: unimplemented("AppLinkClient.chooseApplication", placeholder: nil),
			// Picking in tests keeps the app as given.
			bookmarked: { $0 }
		)
	}

	/// Previews run and open nothing.
	public static var previewValue: Self {
		.init(
			runScript: { _ in .succeeded(log: nil) },
			openApp: { _, _ in .opened },
			copyLink: { _ in },
			appName: { _ in "Claude" },
			appPath: { _ in nil },
			applicationsForScheme: { _ in [] },
			installedApplications: { [] },
			chooseApplication: { nil },
			bookmarked: { $0 }
		)
	}
}

extension DependencyValues {
	public var appLinks: AppLinkClient {
		get { self[AppLinkClient.self] }
		set { self[AppLinkClient.self] = newValue }
	}
}
