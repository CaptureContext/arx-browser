import AppKit
import Foundation

extension DefaultBrowserClient {
	/// The operating-system implementation, through Launch Services and `NSWorkspace`.
	///
	/// Automated runs get ``unavailable`` instead, so they never read or change the default.
	public static var live: Self {
		guard
			isEnabled(
				environment: ProcessInfo.processInfo.environment,
				arguments: CommandLine.arguments
			)
		else { return .unavailable }

		return .init(
			isAvailable: { Bundle.main.bundleIdentifier != nil },
			isDefault: { scheme in Live.isArx(Live.handler(for: scheme)) },
			currentBrowserName: { Live.handler(for: .http).map(Live.displayName) },
			requestDefault: { scheme in
				try await NSWorkspace.shared.setDefaultApplication(
					at: Bundle.main.bundleURL,
					toOpenURLsWithScheme: scheme.rawValue
				)
			},
			currentBrowserIdentifier: { Live.handler(for: .http).flatMap { Bundle(url: $0)?.bundleIdentifier } }
		)
	}
}

private enum Live {
	/// The app that opens links with this scheme now.
	@MainActor
	internal static func handler(for scheme: DefaultBrowserClient.Scheme) -> URL? {
		var components: URLComponents = .init()
		components.scheme = scheme.rawValue
		components.host = "example.com"
		guard let url = components.url
		else { return nil }

		return NSWorkspace.shared.urlForApplication(toOpen: url)
	}

	/// Compares bundle identifiers, so another copy of Arx in a different folder still counts.
	internal static func isArx(_ application: URL?) -> Bool {
		guard
			let application,
			let identifier = Bundle.main.bundleIdentifier
		else { return false }

		return Bundle(url: application)?.bundleIdentifier == identifier
	}

	internal static func displayName(_ application: URL) -> String {
		let name: String = FileManager.default.displayName(atPath: application.path(percentEncoded: false))
		guard name.hasSuffix(".app")
		else { return name }

		return String(name.dropLast(4))
	}
}
