import SwiftUI

/// The warning on a profile or space another Mac removed from iCloud (DEV-1336): it stays until this
/// Mac removes it too or someone keeps it, or until "sync deletions after" removes it here.
public struct DeletionMarkBadge: View {
	public init() {}

	public var body: some View {
		Image(systemName: "exclamationmark.triangle.fill")
			.symbolRenderingMode(.multicolor)
			.font(.system(size: 9, weight: .semibold))
			.accessibilityLabel(String.localized(.appUI.management.markedForDeletionLabel))
	}
}

/// The hint beside a profile or space another Mac removed from iCloud (DEV-1336).
public enum DeletionMarkText {
	/// - Parameters:
	///   - deviceName: the Mac that removed it from iCloud, `nil` when it has no name.
	///   - deletesAt: when "sync deletions after" removes it here, `nil` when it stays until the
	///     person removes it.
	public static func hint(
		deviceName: String?,
		deletesAt: Date?
	) -> String {
		guard let deletesAt else {
			if let deviceName {
				return String.localized(.appUI.management.markedStaysBy(deviceName))
			}
			return String.localized(.appUI.management.markedStays)
		}

		let date: String = deletesAt.formatted(date: .abbreviated, time: .omitted)
		if let deviceName {
			return String.localized(.appUI.management.markedForDeletionBy(deviceName, date))
		}
		return String.localized(.appUI.management.markedForDeletion(date))
	}
}
