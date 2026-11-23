import BrowserCore
import Dependencies
import Foundation
import Sharing

/// The chrome appearance a space shows: its own override over its profile's, over the app-wide default.
///
/// Read-only on purpose. Writing a resolved value wouldn't say which layer to change: override edits
/// go through the organization's reducer actions, and the default through `.chromeAppearance`.
/// Spaces outside the organization, such as a private window's, resolve to the app-wide default.
public struct ResolvedAppearanceKey: SharedReaderKey {
	public struct ID: Hashable, Sendable {
		fileprivate let document: ObjectIdentifier
		fileprivate let spaceID: Space.ID
	}

	private let document: WorkspaceDocument
	private let spaceID: Space.ID

	public init(space spaceID: Space.ID) {
		@Dependency(\.workspaceDocument)
		var document

		self.document = document
		self.spaceID = spaceID
	}

	public var id: ID {
		.init(document: ObjectIdentifier(document), spaceID: spaceID)
	}

	public func load(
		context: LoadContext<ChromeAppearance>,
		continuation: LoadContinuation<ChromeAppearance>
	) {
		continuation.resume(returning: Self.resolve(document.snapshot, space: spaceID))
	}

	public func subscribe(
		context: LoadContext<ChromeAppearance>,
		subscriber: SharedSubscriber<ChromeAppearance>
	) -> SharedSubscription {
		let spaceID = spaceID
		let cancel = document.observe(origin: nil) { old, new in
			let value = Self.resolve(new, space: spaceID)

			// Most organization edits are tab edits; they leave the appearance alone.
			guard Self.resolve(old, space: spaceID) != value else { return }

			subscriber.yield(value)
		}
		return .init(cancel)
	}

	public static func resolve(
		_ snapshot: WorkspaceDocument.Snapshot,
		space spaceID: Space.ID
	) -> ChromeAppearance {
		let global = snapshot.preferences.chromeAppearance
		guard let organization = snapshot.organization else { return global }

		return organization.appearance(ofSpace: spaceID).applied(to: global)
	}
}

extension ResolvedAppearanceKey: CustomStringConvertible {
	public var description: String {
		".chromeAppearance(space: \(spaceID.rawValue))"
	}
}

extension SharedReaderKey where Self == ResolvedAppearanceKey.Default {
	/// The appearance `space` shows. Swap the key when the shown space changes.
	public static func chromeAppearance(space id: Space.ID) -> Self {
		Self[ResolvedAppearanceKey(space: id), default: BrowserPreferences().chromeAppearance]
	}
}
