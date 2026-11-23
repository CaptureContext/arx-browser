import OSLog

/// Where FairPlay in Chromium tabs logs each step (DEV-1144), in the app and in its helper:
/// subsystem `dev.capturecontext.arx`, category `FairPlay`. In Console, filter on that category,
/// or run `log stream --level info --predicate 'category == "FairPlay"'`. Nothing logged names a
/// page, a track or a key.
public enum FairPlayLog {
	public static let logger: Logger = .init(subsystem: "dev.capturecontext.arx", category: "FairPlay")
}
