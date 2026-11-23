import Foundation

/// Runs teardown that can't throw out of a `defer`, such as releasing a page's content host or
/// removing a temporary folder. A failure is printed as `ARX_SMOKE_CLEANUP_FAILED` with the step
/// and the error, so it shows in the smoke's log without hiding the phase's own result (DEV-969).
internal func cleanUp(
	_ step: String,
	_ body: () throws -> Void
) {
	do {
		try body()
	} catch {
		FileHandle.standardError.write(Data("ARX_SMOKE_CLEANUP_FAILED \(step): \(error)\n".utf8))
	}
}
