public enum ChromiumError: Error, Equatable, Sendable {
	case allocatorBootstrapFailed(String)
	case frameworkMissing(String)
	case frameworkLoadFailed(String)
	case incompatibleBridge
	case invalidFileURL
	case invalidFixture
	case alreadyStarted
	case notRunning
	case pageCreationFailed
	case invalidURL
	case downloadNotActive
	case pageClosed
}
