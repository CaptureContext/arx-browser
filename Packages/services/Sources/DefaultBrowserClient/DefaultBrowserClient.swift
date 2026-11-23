import Foundation
import _Dependencies

/// Reads whether Arx opens web links from other apps, and asks macOS to make it the default.
///
/// The closures are the operating-system operations; `status()` and `makeDefault()` hold
/// the decisions, so tests drive every result with doubles.
public struct DefaultBrowserClient: Sendable {
	/// Whether this run may read or change the default browser at all.
	public var isAvailable: @MainActor @Sendable () -> Bool

	/// Whether Arx opens links with this scheme.
	public var isDefault: @MainActor @Sendable (Scheme) -> Bool

	/// The name of the app that opens `http` links now, when it can be read.
	public var currentBrowserName: @MainActor @Sendable () -> String?

	/// The bundle identifier of the app that opens `http` links now, when it can be read.
	public var currentBrowserIdentifier: @MainActor @Sendable () -> String?

	/// Asks macOS to open links with this scheme in Arx. macOS shows its own confirmation;
	/// a declined confirmation may throw or simply leave the default unchanged.
	public var requestDefault: @MainActor @Sendable (Scheme) async throws -> Void

	public init(
		isAvailable: @escaping @MainActor @Sendable () -> Bool,
		isDefault: @escaping @MainActor @Sendable (Scheme) -> Bool,
		currentBrowserName: @escaping @MainActor @Sendable () -> String?,
		requestDefault: @escaping @MainActor @Sendable (Scheme) async throws -> Void,
		currentBrowserIdentifier: @escaping @MainActor @Sendable () -> String? = { nil }
	) {
		self.isAvailable = isAvailable
		self.isDefault = isDefault
		self.currentBrowserName = currentBrowserName
		self.currentBrowserIdentifier = currentBrowserIdentifier
		self.requestDefault = requestDefault
	}
}

// MARK: - Types

extension DefaultBrowserClient {
	/// The link schemes a default browser handles.
	public enum Scheme: String, CaseIterable, Equatable, Sendable {
		case http
		case https
	}

	public enum Status: Equatable, Sendable {
		/// Arx opens both `http` and `https` links.
		case isDefault

		/// Another app opens links, named when macOS reports it.
		case otherBrowser(String?)

		/// This run can't read or change the default, such as a test, smoke or headless run.
		case unavailable
	}

	public enum Outcome: Equatable, Sendable {
		/// The person confirmed macOS's prompt and Arx is now the default.
		case accepted

		/// The person declined macOS's prompt, or the change didn't take.
		case declined

		/// Arx was already the default, so nothing was asked.
		case alreadyDefault

		/// This run can't change the default.
		case unavailable
	}

	/// A client that never touches the system, for automated runs.
	public static var unavailable: Self {
		.init(
			isAvailable: { false },
			isDefault: { _ in false },
			currentBrowserName: { nil },
			requestDefault: { _ in }
		)
	}

	/// Whether this launch may read or change the default browser.
	///
	/// Automated runs never do: test runs (XCTest keys), smoke fixtures (which always set
	/// `ARX_ENGINE_PROFILE` or pass `--arx-…` options), headless runs, and runs with
	/// `ARX_SKIP_DEFAULT_BROWSER`.
	public static func isEnabled(
		environment: [String: String],
		arguments: [String]
	) -> Bool {
		let automationKeys: [String] = [
			"ARX_SKIP_DEFAULT_BROWSER",
			"ARX_ENGINE_PROFILE",
			"XCTestConfigurationFilePath",
			"XCTestBundlePath",
			"XCTestSessionIdentifier",
		]
		guard automationKeys.allSatisfy({ environment[$0] == nil })
		else { return false }

		return !arguments.dropFirst().contains { argument in
			argument == "--headless" || argument.hasPrefix("--arx-")
		}
	}
}

// MARK: - Decisions

extension DefaultBrowserClient {
	/// Whether Arx opens web links now.
	@MainActor
	public func status() -> Status {
		guard isAvailable()
		else { return .unavailable }

		guard !Scheme.allCases.allSatisfy(isDefault)
		else { return .isDefault }

		return .otherBrowser(currentBrowserName())
	}

	/// Asks macOS to make Arx the default browser and reports what the person chose.
	///
	/// Setting `http` usually changes `https` too, so `https` is only asked for when it
	/// still isn't Arx's. A declined `http` prompt stops there instead of asking twice.
	@MainActor
	public func makeDefault() async -> Outcome {
		switch status() {
		case .unavailable:
			return .unavailable

		case .isDefault:
			return .alreadyDefault

		case .otherBrowser:
			break
		}

		for scheme in Scheme.allCases where !isDefault(scheme) {
			do {
				try await requestDefault(scheme)
			} catch {
				break
			}

			guard isDefault(scheme)
			else { break }
		}

		return Scheme.allCases.allSatisfy(isDefault) ? .accepted : .declined
	}
}

// MARK: - Dependency

extension DefaultBrowserClient: DependencyKey {
	public static var liveValue: Self { .live }

	/// Tests must supply their own client, so an unexpected call fails the test.
	public static var testValue: Self {
		.init(
			isAvailable: unimplemented("DefaultBrowserClient.isAvailable", placeholder: false),
			isDefault: unimplemented("DefaultBrowserClient.isDefault", placeholder: false),
			currentBrowserName: unimplemented("DefaultBrowserClient.currentBrowserName", placeholder: nil),
			requestDefault: unimplemented("DefaultBrowserClient.requestDefault"),
			currentBrowserIdentifier: unimplemented("DefaultBrowserClient.currentBrowserIdentifier", placeholder: nil)
		)
	}

	/// Previews show Safari as the default and never change anything.
	public static var previewValue: Self {
		.init(
			isAvailable: { true },
			isDefault: { _ in false },
			currentBrowserName: { "Safari" },
			requestDefault: { _ in },
			currentBrowserIdentifier: { "com.apple.Safari" }
		)
	}
}

extension DependencyValues {
	public var defaultBrowser: DefaultBrowserClient {
		get { self[DefaultBrowserClient.self] }
		set { self[DefaultBrowserClient.self] = newValue }
	}
}
