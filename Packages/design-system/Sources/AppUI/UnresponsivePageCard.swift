import SwiftUI

/// DEV-1009. Shown over a page whose renderer stopped answering once the person tried to use
/// it, as Chrome's Page Unresponsive does: Wait leaves it, Reload ends its renderer and loads
/// the page again on a new one.
public struct UnresponsivePageCard: View {
	private let onWait: () -> Void
	private let onReload: () -> Void

	public init(
		onWait: @escaping () -> Void,
		onReload: @escaping () -> Void
	) {
		self.onWait = onWait
		self.onReload = onReload
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Label(String.localized(.appUI.viewer.unresponsiveTitle), systemImage: "hourglass")
				.font(.headline)
			Text(String.localized(.appUI.viewer.unresponsiveDetail))
				.font(.callout)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer(minLength: 0)
				Button(String.localized(.appUI.viewer.unresponsiveWait), action: onWait)
					.keyboardShortcut(.cancelAction)
				Button(String.localized(.appUI.viewer.unresponsiveReload), action: onReload)
			}
		}
		.padding(18)
		.frame(width: 340, alignment: .leading)
		.background(.regularMaterial, in: .rect(cornerRadius: 12, style: .continuous))
		.accessibilityElement(children: .contain)
	}
}
