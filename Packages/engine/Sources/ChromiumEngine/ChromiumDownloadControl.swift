import ChromiumBridge

/// What a transfer can do now (DEV-892), from `ArxEngineDownloadControl`.
public struct ChromiumDownloadControl: OptionSet, Equatable, Sendable {
	public let rawValue: UInt32

	public init(rawValue: UInt32) {
		self.rawValue = rawValue
	}

	public static let paused: Self = .init(rawValue: UInt32(ARX_DOWNLOAD_CONTROL_PAUSED))
	public static let canResume: Self = .init(rawValue: UInt32(ARX_DOWNLOAD_CONTROL_CAN_RESUME))
	public static let canPause: Self = .init(rawValue: UInt32(ARX_DOWNLOAD_CONTROL_CAN_PAUSE))
}
