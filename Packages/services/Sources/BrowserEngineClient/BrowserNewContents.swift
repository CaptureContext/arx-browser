import BrowserCore
import Foundation

/// A browser-created session offer. It carries no new navigation command.
/// Private offers may be published only into ephemeral private organizations.
public struct BrowserNewContents: Equatable, Sendable {
	public enum Disposition: Equatable, Sendable {
		case foregroundTab
		case backgroundTab
		case window
		case popup
	}

	public let sourceTabID: BrowserCore.Tab.ID
	public let sourceSessionRevision: UInt64
	public let sourceDocumentRevision: UInt64
	public let tab: BrowserCore.Tab
	public let disposition: Disposition
	public let isPrivate: Bool

	public init(
		sourceTabID: BrowserCore.Tab.ID,
		sourceSessionRevision: UInt64,
		sourceDocumentRevision: UInt64,
		tab: BrowserCore.Tab,
		disposition: Disposition,
		isPrivate: Bool = false
	) {
		self.sourceTabID = sourceTabID
		self.sourceSessionRevision = sourceSessionRevision
		self.sourceDocumentRevision = sourceDocumentRevision
		self.tab = tab
		self.disposition = disposition
		self.isPrivate = isPrivate
	}
}
