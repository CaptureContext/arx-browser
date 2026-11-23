import Darwin
import Foundation
import os

/// The test folders, deleted when the test process ends rather than when their test does
/// (DEV-1214). A test can end while its sync still works in the background: the account retry, for
/// one, goes on to start the device directory's engine after the categories the test waited for.
/// Deleting the folder underneath that work made SQLite fail with "disk I/O error" on its next
/// commit, and the failure landed in whichever test ran then. Nothing here writes into another
/// test's folder, so keeping each one until the end changes no result.
enum TestFolders {
	private static let pending: OSAllocatedUnfairLock<[URL]> = .init(initialState: [])

	private static let removesAtExit: Void = {
		atexit {
			for folder in TestFolders.pending.withLock({ $0 }) {
				try? FileManager.default.removeItem(at: folder)
			}
		}
	}()

	/// Deletes `folder` once every test in this process has finished.
	static func removeAtExit(_ folder: URL) {
		_ = removesAtExit
		pending.withLock { $0.append(folder) }
	}
}
