import AppUI
import SwiftUI

/// The sheet every custom Settings list adds and edits its items in (DEV-1001): a title, labeled
/// fields, a validation message, and Cancel (Esc) and Add or Save (↩), which stays dimmed until
/// the item is valid. An item being edited also offers Delete.
///
/// ```swift
/// SettingsListForm(
///     title: "Add Site",
///     primaryTitle: "Add",
///     isValid: draft.isValid,
///     message: draft.error.map(message),
///     onCancel: { send(.cancel) },
///     onSubmit: { send(.save) }
/// ) {
///     SettingsTextField("Site", text: site, prompt: "netflix.com")
/// }
/// ```
public struct SettingsListForm<Fields: View>: View {
	private let title: String
	private let primaryTitle: String
	private let isValid: Bool
	private let message: String?
	private let deleteTitle: String?
	private let onCancel: () -> Void
	private let onSubmit: () -> Void
	private let onDelete: (() -> Void)?
	private let fields: Fields

	/// - Parameters:
	///   - deleteTitle: With `onDelete`, the Delete button's title, shown for an item being edited.
	public init(
		title: String,
		primaryTitle: String,
		isValid: Bool,
		message: String? = nil,
		deleteTitle: String? = nil,
		onCancel: @escaping () -> Void,
		onSubmit: @escaping () -> Void,
		onDelete: (() -> Void)? = nil,
		@ViewBuilder fields: () -> Fields
	) {
		self.title = title
		self.primaryTitle = primaryTitle
		self.isValid = isValid
		self.message = message
		self.deleteTitle = deleteTitle
		self.onCancel = onCancel
		self.onSubmit = onSubmit
		self.onDelete = onDelete
		self.fields = fields()
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			Text(title)
				.font(.title2.bold())
				.accessibilityAddTraits(.isHeader)
			VStack(alignment: .leading, spacing: 10) {
				fields
			}
			if let message {
				Text(message)
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
					.fixedSize(horizontal: false, vertical: true)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				if let onDelete, let deleteTitle {
					ArxModalButton(deleteTitle, prominence: .destructive, key: nil, action: onDelete)
				}
				Spacer()
				ArxModalButton.cancel(action: onCancel)
				ArxModalButton(primaryTitle, action: onSubmit)
					.disabled(!isValid)
			}
		}
		.font(SettingsTypography.body)
		.padding(24)
		.frame(width: 520)
		.arxModalSheet()
		.settingsControls()
	}
}
