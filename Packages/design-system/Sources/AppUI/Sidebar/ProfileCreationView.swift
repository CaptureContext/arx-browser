import SwiftUI

/// Introduces profiles and names a new one, from Settings or the sidebar.
public struct ProfileCreationView: View {
	private let error: String?
	private let isBusy: Bool
	private let onCancel: () -> Void
	private let onCreate: () -> Void

	@Binding
	private var name: String

	@FocusState
	private var nameFocused: Bool

	public init(
		name: Binding<String>,
		error: String? = nil,
		isBusy: Bool = false,
		onCancel: @escaping () -> Void,
		onCreate: @escaping () -> Void
	) {
		self._name = name
		self.error = error
		self.isBusy = isBusy
		self.onCancel = onCancel
		self.onCreate = onCreate
	}

	private var canCreate: Bool {
		!isBusy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	public var body: some View {
		// The Close bar every Settings sheet uses (DEV-772): × (Escape) cancels, and Create
		// stays under the field.
		VStack(alignment: .leading, spacing: 0) {
			ArxHeaderBar(.close(onCancel), title: String.localized(.appUI.profile.create))
			form
				.padding(.horizontal, 36)
				.padding(.top, 8)
				.padding(.bottom, 36)
		}
		.foregroundStyle(BrowserTheme.text)
		.frame(width: 450)
		.arxModalSheet()
		.onAppear { nameFocused = true }
	}

	private var form: some View {
		VStack(alignment: .leading, spacing: 0) {
			badge.padding(.bottom, 20)
			Text(localized: .appUI.profile.createTitle)
				.font(.system(size: 18, weight: .semibold))
				.padding(.bottom, 12)
			Text(localized: .appUI.profile.createDetail)
				.font(.system(size: 14))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
				.fixedSize(horizontal: false, vertical: true)
				.padding(.bottom, 20)
			Text(localized: .appUI.profile.createQuestion)
				.font(.system(size: 14))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.Library.labelOpacity))
				.padding(.bottom, 8)
			field.padding(.bottom, 8)
			Label(
				String.localized(.appUI.profile.createNote),
				systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
			)
				.font(.system(size: 12))
				.foregroundStyle(BrowserTheme.secondary)
			if let error {
				Text(error)
					.font(.system(size: 12))
					.foregroundStyle(.red)
					.padding(.top, 8)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer()
				ArxModalButton(String.localized(.appUI.profile.createAction), action: onCreate)
					.disabled(!canCreate)
			}
			.padding(.top, 24)
		}
	}

	private var badge: some View {
		Image(systemName: "face.smiling.inverse")
			.font(.system(size: 54))
			.foregroundStyle(BrowserTheme.accent)
			.padding(4)
			.overlay {
				Circle()
					.strokeBorder(
						BrowserTheme.secondary.opacity(0.5),
						style: .init(lineWidth: 1, dash: [3, 3])
					)
			}
			.overlay(alignment: .bottomTrailing) {
				Image(systemName: "plus.circle.fill")
					.font(.system(size: 18))
					.symbolRenderingMode(.palette)
					.foregroundStyle(.white, .green)
			}
			.accessibilityHidden(true)
	}

	private var field: some View {
		TextField(
			String.localized(.appUI.common.name),
			text: $name,
			prompt: Text(localized: .appUI.profile.createPlaceholder)
		)
		.textFieldStyle(.plain)
		.font(.system(size: 14))

		// Return reaches Create, the sheet's default action, without an `onSubmit` here, which
		// could send it a second time (DEV-774).
		.focused($nameFocused)
		.padding(.horizontal, 12)
		.frame(height: 44)
		.overlay {
			ArxControlShape()
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: 1)
		}
	}
}
