import AppKit
import Foundation
import _Dependencies

/// Whether Arx may read the data macOS protects with Full Disk Access, such as Safari's
/// (DEV-840), and the way to System Settings to allow it.
///
/// There's no API that asks; a protected file either opens or doesn't. Granting it happens
/// in System Settings, so features check again when Arx becomes active.
public struct FullDiskAccessClient: Sendable {
	/// Whether a protected file opens now.
	public var isGranted: @Sendable () async -> Bool

	/// Opens System Settings › Privacy & Security › Full Disk Access.
	public var openSettings: @Sendable () async -> Void

	public init(
		isGranted: @escaping @Sendable () async -> Bool = { false },
		openSettings: @escaping @Sendable () async -> Void = {}
	) {
		self.isGranted = isGranted
		self.openSettings = openSettings
	}
}

extension FullDiskAccessClient {
	/// The pane in System Settings that lists apps with Full Disk Access.
	public static let settingsURL: URL = URL(
		string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
	)!

	/// Checks by opening a file and closing it at once, without reading it.
	public static func checking(
		_ file: URL,
		open: @escaping @Sendable (URL) async -> Void = { _ in }
	) -> Self {
		.init(
			isGranted: {
				guard let handle = try? FileHandle(forReadingFrom: file) else { return false }

				try? handle.close()
				return true
			},
			openSettings: { await open(settingsURL) }
		)
	}

	/// A client whose answer the test sets.
	public static func constant(_ isGranted: Bool) -> Self {
		.init(isGranted: { isGranted })
	}
}

/// Where a source that needs Full Disk Access stands.
public enum FullDiskAccessStatus: Equatable, Sendable {
	/// Not checked yet, or being checked.
	case unknown
	case denied
	case granted
}

extension FullDiskAccessClient: DependencyKey {
	public static var liveValue: Self {
		checking(
			SafariData.Location(home: FileManager.default.homeDirectoryForCurrentUser).bookmarks,
			open: { url in
				await MainActor.run { _ = NSWorkspace.shared.open(url) }
			}
		)
	}

	public static var testValue: Self { .init() }
	public static var previewValue: Self { .constant(true) }
}

extension DependencyValues {
	public var fullDiskAccess: FullDiskAccessClient {
		get { self[FullDiskAccessClient.self] }
		set { self[FullDiskAccessClient.self] = newValue }
	}
}
