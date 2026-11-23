import SwiftUI

/// The address bar's reading mode button (DEV-1028): shown while the page looks like it has an
/// article, or shows it in reading mode, and filled while it does.
public struct ReadingModeIndicator {
	public let isReading: Bool
	public let toggle: @MainActor () -> Void

	public init(
		isReading: Bool,
		toggle: @escaping @MainActor () -> Void
	) {
		self.isReading = isReading
		self.toggle = toggle
	}

	internal var symbol: String {
		isReading ? "doc.plaintext.fill" : "doc.plaintext"
	}

	internal var title: String {
		isReading ? String.localized(.appUI.reader.close) : String.localized(.appUI.reader.show)
	}
}

extension EnvironmentValues {
	/// The page's reading mode, for the address bar that describes it; nil hides the button.
	@Entry
	public var readingModeIndicator: ReadingModeIndicator? = nil

	/// The URL bar keeps its page button's room, empty, while the next page settles, so the
	/// address and the buttons beside it don't move (DEV-1254).
	@Entry
	public var urlBarReservesPageButton: Bool = false
}
