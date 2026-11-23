import BrowserCore
import SwiftUI

/// The Customizable homepage feature flag: a button in the corner of a pane with no page opens
/// the homepage's controls there, and the page keeps what they set. Off, every pane shows the
/// default homepage.
public enum EmptyPageCustomization {
	public static let featureFlag: String = FeatureFlag.customizableHomepage.name

	/// Read once, at launch, through the `FeatureFlag` registry. Tests set it.
	@MainActor
	public static var isEnabled: Bool = FeatureFlag.customizableHomepage.isOn()
}

/// The middle of a pane with no page: the homepage, in the style the person chose, or the
/// default one while the homepage can't be customized.
public struct BrowserEmptyPage: View {
	@AppStorage(EmptyPageStyle.storageKey)
	private var stored: EmptyPageStyle.Stored = .init()

	@SwiftUI.State
	private var isCustomizing: Bool = false

	private let isCustomizable: Bool

	public init(isCustomizable: Bool? = nil) {
		self.isCustomizable = isCustomizable ?? EmptyPageCustomization.isEnabled
	}

	public var body: some View {
		let style: EmptyPageStyle = isCustomizable ? stored.style : .captureContext
		EmptyPageView(style: style)
			.preference(key: BrowserPageSeeThroughKey.self, value: style.background.isClear)
			.overlay(alignment: .topTrailing) {
				if isCustomizable, isCustomizing {
					EmptyPageEditor(style: $stored.style)
						.scrollContentBackground(.hidden)
						.frame(width: BrowserMetrics.EmptyPage.editorWidth)
						.frame(maxHeight: .infinity)
						.background(.regularMaterial, in: .rect(cornerRadius: BrowserMetrics.EmptyPage.editorCornerRadius, style: .continuous))
						.padding(BrowserMetrics.EmptyPage.editorInset)
						.padding(.bottom, BrowserMetrics.EmptyPage.buttonSide + BrowserMetrics.EmptyPage.editorInset)
						.onExitCommand { isCustomizing = false }
						.transition(.opacity)
				}
			}
			.overlay(alignment: .bottomTrailing) {
				if isCustomizable {
					customizeButton
				}
			}
	}

	private var customizeButton: some View {
		Button {
			isCustomizing.toggle()
		} label: {
			Image(systemName: isCustomizing ? "xmark" : "paintbrush.pointed")
				.font(.system(size: 11, weight: .medium))
				.foregroundStyle(BrowserTheme.secondary)
				.frame(width: BrowserMetrics.EmptyPage.buttonSide, height: BrowserMetrics.EmptyPage.buttonSide)
				.contentShape(.circle)
		}
		.buttonStyle(.plain)
		.background(BrowserTheme.fill, in: .circle)
		.help(String.localized(.appUI.emptyPage.customize))
		.accessibilityLabel(String.localized(.appUI.emptyPage.customize))
		.padding(BrowserMetrics.EmptyPage.editorInset)
	}
}
