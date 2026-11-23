import AppKit
import Foundation
import _Dependencies

/// Other browsers on this Mac, for their own links (DEV-1193): whether Chrome or Arc is installed,
/// looked up when a link opens, and opening a `chrome://` or `arc://` link in it. Arx never asks
/// macOS to send it another browser's scheme.
public struct BrowserLinkClient: Sendable {
	/// Where the app with one of these bundle identifiers is, the first found.
	public var application: @MainActor @Sendable ([String]) -> URL?

	/// Opens `url` in the app at the second URL. False when it couldn't.
	public var open: @MainActor @Sendable (URL, URL) async -> Bool

	public init(
		application: @escaping @MainActor @Sendable ([String]) -> URL?,
		open: @escaping @MainActor @Sendable (URL, URL) async -> Bool
	) {
		self.application = application
		self.open = open
	}
}

extension BrowserLinkClient {
	/// Chrome's bundle identifiers, the release first.
	public static let chromeIdentifiers: [String] = [
		"com.google.Chrome",
		"com.google.Chrome.beta",
		"com.google.Chrome.dev",
		"com.google.Chrome.canary",
	]

	/// Arc's bundle identifier.
	public static let arcIdentifiers: [String] = ["company.thebrowser.Browser"]

	/// A client that finds no browser and changes nothing, for automated runs.
	public static var unavailable: Self {
		.init(
			application: { _ in nil },
			open: { _, _ in false }
		)
	}

	/// The operating-system implementation. Automated runs get ``unavailable``, as the default
	/// browser client's do, so a test or smoke never opens Chrome.
	public static var live: Self {
		guard
			DefaultBrowserClient.isEnabled(
				environment: ProcessInfo.processInfo.environment,
				arguments: CommandLine.arguments
			)
		else { return .unavailable }

		return .init(
			application: { identifiers in
				identifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
			},
			open: { url, application in
				let configuration: NSWorkspace.OpenConfiguration = .init()
				configuration.activates = true
				do {
					_ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: configuration)
					return true
				} catch {
					return false
				}
			}
		)
	}
}

extension BrowserLinkClient: DependencyKey {
	public static var liveValue: Self { .live }

	/// Tests must supply their own client, so an unexpected call fails the test.
	public static var testValue: Self {
		.init(
			application: unimplemented("BrowserLinkClient.application", placeholder: nil),
			open: unimplemented("BrowserLinkClient.open", placeholder: false)
		)
	}

	/// Previews find no other browser and change nothing.
	public static var previewValue: Self { .unavailable }
}

extension DependencyValues {
	public var browserLinks: BrowserLinkClient {
		get { self[BrowserLinkClient.self] }
		set { self[BrowserLinkClient.self] = newValue }
	}
}
