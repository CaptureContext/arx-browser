import AppUI
import SwiftUI

/// A keyboard-accessible entry until native in-page link targeting is available. Its button,
/// field and Preview are Arx's own controls (DEV-743, DEV-1224).
public struct PeekURLButton: View {
	private let source: PeekFeature.Source?
	private let onPreview: (URL, PeekFeature.Source) -> Void

	@SwiftUI.State
	private var isPresented: Bool

	@SwiftUI.State
	private var location: String

	@SwiftUI.State
	private var capturedSource: PeekFeature.Source?

	@FocusState
	private var locationIsFocused: Bool

	public init(
		source: PeekFeature.Source?,
		onPreview: @escaping (URL, PeekFeature.Source) -> Void
	) {
		self.source = source
		self.onPreview = onPreview
		self._isPresented = .init(initialValue: false)
		self._location = .init(initialValue: "")
		self._capturedSource = .init(initialValue: nil)
	}

	public var body: some View {
		Button(String.localized(.appUI.peek.title)) {
			capturedSource = source
			isPresented = true
		}
		.buttonStyle(.arx)
		.disabled(source == nil)
		.popover(isPresented: $isPresented) {
			VStack(alignment: .leading, spacing: 12) {
				Text(localized: .appUI.peek.location).font(.headline)
				if let capturedSource {
					Text(capturedSource.identity)
						.font(.caption)
						.foregroundStyle(.secondary)
				}
				TextField(String.localized(.appUI.peek.location), text: $location)
					.textFieldStyle(.arx)
					.focused($locationIsFocused)
					.onSubmit(preview)
				Text(localized: .appUI.peek.invalidURL)
					.font(.caption)
					.foregroundStyle(.secondary)
				Button(action: preview) {
					ArxButtonLabel(String.localized(.appUI.peek.preview), keyHint: .return)
				}
				.buttonStyle(.arx(.primary))
				.keyboardShortcut(.defaultAction)
				.disabled(PeekFeature.previewURL(location) == nil)
				.frame(maxWidth: .infinity, alignment: .trailing)
			}
			.padding(16)
			.frame(width: 360)
			.onAppear { locationIsFocused = true }
		}
	}

	private func preview() {
		guard
			let capturedSource,
			let url = PeekFeature.previewURL(location)
		else { return }

		isPresented = false
		location = ""
		onPreview(url, capturedSource)
	}
}
