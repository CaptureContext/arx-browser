import BrowserCore
import ChromiumEngine
import Foundation

/// Answers the file chooser a page holds after an automation action. The user
/// approved every path in Arx before this runs; each one is checked again here.
internal enum ChromiumUploadAdapter {
	@MainActor
	internal static func answer(
		_ request: AutomationFormRequest,
		page: ChromiumPage,
		authorize: @MainActor () -> Bool,
		fileManager: FileManager = .default
	) -> AutomationFormResult {
		func rejected(_ failure: AutomationFailure) -> AutomationFormResult {
			.init(operationID: request.operationID, disposition: .notDispatched, failure: failure)
		}

		let paths = request.values ?? []
		guard let chooser = page.fileChooser() else { return rejected(.noFileChooser) }
		guard paths.count <= (chooser.allowsMultiple ? 32 : 1)
		else { return rejected(.invalidValue) }
		guard paths.allSatisfy({ isReadableFile($0, fileManager: fileManager) }) else {
			return rejected(.fileUnavailable)
		}
		guard authorize() else { return rejected(.denied) }

		do {
			try page.answerFileChooser(chooser, paths: paths)
		} catch .invalid {
			return rejected(.invalidValue)
		} catch .unavailable {
			return rejected(.unsupported)
		} catch {
			return rejected(.noFileChooser)
		}

		// The page now has the files (or the cancellation); its change and input
		// handlers run later and may do anything.
		return .init(operationID: request.operationID, disposition: .dispatched)
	}

	/// An existing, readable regular file; never a folder or a symbolic link.
	internal static func isReadableFile(
		_ path: String,
		fileManager: FileManager
	) -> Bool {
		guard
			AutomationFormRequest.isUploadPath(path),
			let attributes = try? fileManager.attributesOfItem(atPath: path),
			attributes[.type] as? FileAttributeType == .typeRegular
		else { return false }

		return fileManager.isReadableFile(atPath: path)
	}
}
