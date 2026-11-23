import Foundation

/// A non-invasive view of an existing renderer session. Revision changes conservatively on navigation updates.
public struct BrowserSessionSnapshot: Equatable, Sendable {
	public var navigation: BrowserNavigation

	/// Native owner identity, never exported as MCP authority.
	public var nativePageID: UInt64?
	public var nativeProfileID: Profile.ID?
	public var revision: UInt64

	/// Read synchronously from the renderer owner; nil means document-bound reads are unavailable.
	public var documentRevision: UInt64?

	/// Live native host visibility; detached or unavailable hosts fail closed.
	public var isVisibleForCapture: Bool

	public init(
		navigation: BrowserNavigation,
		revision: UInt64,
		documentRevision: UInt64? = nil,
		isVisibleForCapture: Bool = false,
		nativePageID: UInt64? = nil,
		nativeProfileID: Profile.ID? = nil
	) {
		self.nativeProfileID = nativeProfileID
		self.nativePageID = nativePageID
		self.navigation = navigation
		self.revision = revision
		self.documentRevision = documentRevision
		self.isVisibleForCapture = isVisibleForCapture
	}
}
