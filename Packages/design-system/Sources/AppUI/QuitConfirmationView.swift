import SwiftUI

/// The dialog ⌘Q shows while Settings › General › Warn before quitting is on, or whenever a
/// download in progress couldn't be resumed (DEV-966).
///
/// Return quits, Esc cancels, and Quit, and Don't Ask Again also turns the warning off.
/// The window that hosts it handles the keys, including ⌘Q pressed again. Downloads in progress
/// stop and can be resumed next time, which it says; one whose server can't resume it is lost,
/// which it says first.
public struct QuitConfirmationView: View {
	public enum Choice: Equatable, Sendable {
		case cancel
		case quit
		case quitAndStopAsking
	}

	private let icon: Image
	private let downloads: Int
	private let unresumableDownloads: Int
	private let choose: (Choice) -> Void

	/// - Parameters:
	///   - downloads: Downloads in progress, paused ones included, which quitting stops.
	///   - unresumableDownloads: Those of them quitting loses, as their server can't resume them.
	public init(
		icon: Image,
		downloads: Int = 0,
		unresumableDownloads: Int = 0,
		choose: @escaping (Choice) -> Void
	) {
		self.icon = icon
		self.downloads = downloads
		self.unresumableDownloads = unresumableDownloads
		self.choose = choose
	}

	private var resumableDownloads: Int { max(downloads - unresumableDownloads, 0) }

	private var hasDownloads: Bool { downloads > 0 || unresumableDownloads > 0 }

	public static let width: CGFloat = 480

	public var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			icon
				.resizable()
				.interpolation(.high)
				.frame(width: 56, height: 56)
				.accessibilityHidden(true)
				.padding(.bottom, 16)

			Text(localized: .appUI.quit.title)
				.font(.system(size: 17, weight: .semibold))
				.accessibilityAddTraits(.isHeader)
				.padding(.bottom, hasDownloads ? 10 : 36)

			if hasDownloads {
				VStack(alignment: .leading, spacing: 6) {
					if unresumableDownloads > 0 {
						Label {
							Text(String.localized(.appUI.quit.downloadsLost(unresumableDownloads)))
						} icon: {
							Image(systemName: "exclamationmark.triangle.fill")
								.foregroundStyle(.orange)
						}
						.font(.system(size: 13, weight: .medium))
					}
					if resumableDownloads > 0 {
						Text(String.localized(.appUI.quit.downloadsStop(resumableDownloads)))
							.font(.system(size: 13))
							.foregroundStyle(.secondary)
					}
				}
				.fixedSize(horizontal: false, vertical: true)
				.padding(.bottom, 28)
			}

			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Button { choose(.quitAndStopAsking) } label: {
					Text(localized: .appUI.quit.dontAskQuit)
						.fixedSize()
				}
				.buttonStyle(.arxModal())

				Spacer(minLength: 8)

				// The window that hosts the dialog answers the keys, so the buttons only show them.
				Button { choose(.cancel) } label: {
					ArxButtonLabel(
						Text(localized: .appUI.common.cancel),
						keyHint: ArxKeyHint(Text(localized: .appUI.quit.escapeKey))
					)
				}
				.buttonStyle(.arxModal())

				Button { choose(.quit) } label: {
					ArxButtonLabel(Text(localized: .appUI.quit.confirm), keyHint: .return)
				}
				.buttonStyle(.arxModal(.primary))
			}
		}
		.padding(24)
		.frame(width: Self.width, alignment: .leading)
		.background(ArxModalMetrics.background, in: .rect(cornerRadius: 22, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 22, style: .continuous)
				.strokeBorder(.primary.opacity(0.12), lineWidth: 1)
		}
	}
}

#Preview("Quit confirmation") {
	QuitConfirmationView(icon: Image(systemName: "globe")) { _ in }
		.padding()
}
