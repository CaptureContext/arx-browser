import BrowserCore
import Dependencies
import Foundation

/// What's already on this Mac that says when this Arx was first installed (DEV-1323): the creation
/// dates of the edition's data folder and its Chromium profile folder. AppFeature reads it once,
/// at the first launch without a recorded ``BrowserPreferences/installedAt``.
public struct InstallDateEvidence: Sendable {
	/// The creation dates of the folders that exist, in no particular order.
	public var creationDates: @Sendable () -> [Date]

	public init(creationDates: @escaping @Sendable () -> [Date]) {
		self.creationDates = creationDates
	}
}

extension InstallDateEvidence: DependencyKey {
	public static var liveValue: Self {
		.init {
			InstallDate.creationDates(of: InstallDate.evidenceFolders(edition: .current, home: .homeDirectory))
		}
	}

	/// Tests say what's on the Mac, so an unexpected read fails the test.
	public static var testValue: Self {
		.init(creationDates: unimplemented("InstallDateEvidence.creationDates", placeholder: []))
	}

	public static var previewValue: Self {
		.init { [] }
	}
}

extension DependencyValues {
	public var installDateEvidence: InstallDateEvidence {
		get { self[InstallDateEvidence.self] }
		set { self[InstallDateEvidence.self] = newValue }
	}
}
