import ChromiumBootstrap

extension ChromiumRuntime {

	/// Registers the pinned delegating zone only during verified safe startup.
	/// Failure writes a native diagnostic; callers must stop before creating UI.
	public static func prepareHostAllocator() -> Bool {
		ArxPrepareAllocatorAndReportFailure()
	}

	/// Call as the first Debug entry operation, before Foundation configuration.
	/// The C probe reports only when explicitly requested by the smoke runner.
	public static func reportBootstrapEntryForSmoke() {
		ArxReportBootstrapEntryForSmoke()
	}
}
