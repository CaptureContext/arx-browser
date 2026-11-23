import BrowserCore
import Foundation

/// An `arx://` link a web page opened, waiting for the person to confirm it (DEV-929). Links
/// from other apps, Shortcuts and AppleScript don't ask.
public struct ArxLinkConfirmation: Equatable, Identifiable, Sendable {
	public var id: UUID
	public var command: ArxURLCommand

	/// The page's origin, empty when unknown.
	public var source: String
	public var windowID: UUID

	/// The page and frame that opened it, checked again when the person answers.
	public var sourceTabID: BrowserCore.Tab.ID
	public var sourceDocumentRevision: UInt64
	public var sourceToken: UInt64

	public init(
		id: UUID,
		command: ArxURLCommand,
		source: String,
		windowID: UUID,
		sourceTabID: BrowserCore.Tab.ID,
		sourceDocumentRevision: UInt64,
		sourceToken: UInt64
	) {
		self.id = id
		self.command = command
		self.source = source
		self.windowID = windowID
		self.sourceTabID = sourceTabID
		self.sourceDocumentRevision = sourceDocumentRevision
		self.sourceToken = sourceToken
	}
}
