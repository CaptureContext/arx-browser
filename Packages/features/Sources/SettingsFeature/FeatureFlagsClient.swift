import AppKit
import BrowserCore
import Foundation
import _ComposableArchitecture

/// Reads, saves and applies Arx's `ARX_*` feature flags for Settings › Advanced › Feature Flags
/// (DEV-1115): the environment first, then user defaults, through BrowserCore's `FeatureFlag`.
public struct FeatureFlagsClient: Sendable {
	/// The flag's value and what set it.
	public var state: @Sendable (_ flag: FeatureFlag) -> FeatureFlagState

	/// Saves the flag to user defaults.
	public var set: @Sendable (_ flag: FeatureFlag, _ isOn: Bool) -> Void

	/// Opens Arx again once this process has exited. AppFeature calls it when a quit Relaunch
	/// asked for goes ahead.
	public var reopenAfterQuit: @Sendable () -> Void

	public init(
		state: @escaping @Sendable (_ flag: FeatureFlag) -> FeatureFlagState,
		set: @escaping @Sendable (_ flag: FeatureFlag, _ isOn: Bool) -> Void,
		reopenAfterQuit: @escaping @Sendable () -> Void
	) {
		self.state = state
		self.set = set
		self.reopenAfterQuit = reopenAfterQuit
	}
}

extension FeatureFlagsClient: DependencyKey {
	public static let liveValue: Self = .init(
		state: { $0.state() },
		set: { flag, isOn in flag.set(isOn) },
		reopenAfterQuit: {
			// A detached shell waits for this process to exit, then opens Arx again.
			let process: Process = .init()
			process.executableURL = URL(filePath: "/bin/sh")
			process.arguments = [
				"-c",
				#"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open "$2""#,
				"sh",
				String(ProcessInfo.processInfo.processIdentifier),
				Bundle.main.bundleURL.path(percentEncoded: false),
			]
			process.standardInput = FileHandle.nullDevice
			process.standardOutput = FileHandle.nullDevice
			process.standardError = FileHandle.nullDevice
			try? process.run()
		}
	)

	public static let testValue: Self = .init(
		state: unimplemented("FeatureFlagsClient.state", placeholder: .init(isOn: false, source: .default)),
		set: unimplemented("FeatureFlagsClient.set"),
		reopenAfterQuit: unimplemented("FeatureFlagsClient.reopenAfterQuit")
	)

	/// Every flag at its default, and nothing saved.
	public static let previewValue: Self = .init(
		state: { .init(isOn: $0.isOnByDefault, source: .default) },
		set: { _, _ in },
		reopenAfterQuit: {}
	)
}

extension DependencyValues {
	public var featureFlags: FeatureFlagsClient {
		get { self[FeatureFlagsClient.self] }
		set { self[FeatureFlagsClient.self] = newValue }
	}
}
