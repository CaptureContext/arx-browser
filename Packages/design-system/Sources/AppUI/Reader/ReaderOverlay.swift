import BrowserCore
import SwiftUI

/// Reading mode laid over the page (DEV-1028): the article in a reader of its own, which covers
/// the page without touching it, so closing it shows the page as it was, where it was scrolled.
/// Its controls float at the top: four themes, text size, column width and Exit Reading Mode.
public struct ReaderOverlay: View {
	public enum Phase: Equatable, Sendable {
		/// The article is being read from the page.
		case reading
		case article(ReaderArticle)

		/// The page has no article to show.
		case unavailable
	}

	public let phase: Phase

	/// The reader's page holds the keyboard: in Split View, while its pane is the focused one.
	public let isFocused: Bool

	/// The Find bar's search of the article (DEV-1066).
	public let find: ReaderFind

	/// The article's matches for the Find request with this serial; nil when they were cleared.
	public let onFind: @MainActor (_ serial: UInt64, BrowserNavigation.FindResult?) -> Void
	public let onOpenLink: @MainActor (URL) -> Void
	public let onClose: @MainActor () -> Void

	@AppStorage("reader.theme")
	private var themeName: String = ReaderAppearance.Theme.light.rawValue

	@AppStorage("reader.textSize")
	private var textSize: Int = 18

	@AppStorage("reader.width")
	private var width: Int = 680

	public init(
		phase: Phase,
		isFocused: Bool = true,
		find: ReaderFind = .init(),
		onFind: @escaping @MainActor (_ serial: UInt64, BrowserNavigation.FindResult?) -> Void = { _, _ in },
		onOpenLink: @escaping @MainActor (URL) -> Void,
		onClose: @escaping @MainActor () -> Void
	) {
		self.phase = phase
		self.isFocused = isFocused
		self.find = find
		self.onFind = onFind
		self.onOpenLink = onOpenLink
		self.onClose = onClose
	}

	private var appearance: ReaderAppearance {
		.init(
			theme: ReaderAppearance.Theme(rawValue: themeName) ?? .light,
			textSize: textSize,
			width: width
		)
	}

	public var body: some View {
		let appearance = appearance
		ZStack(alignment: .top) {
			appearance.theme.swatch
			switch phase {
			case .reading:
				VStack(spacing: 10) {
					ProgressView()
						.controlSize(.small)
					Text(localized: .appUI.reader.reading)
						.font(.callout)
				}
				.foregroundStyle(Color(nsColor: appearance.theme.isDark ? .white : .black).opacity(0.6))
				.frame(maxWidth: .infinity, maxHeight: .infinity)

			case let .article(article):
				ReaderWebView(
					article: article,
					appearance: appearance,
					isFocused: isFocused,
					find: find,
					onFind: onFind,
					onOpenLink: onOpenLink,
					onClose: onClose
				)

			case .unavailable:
				VStack(spacing: 12) {
					Text(localized: .appUI.reader.unavailable)
						.font(.callout)
						.multilineTextAlignment(.center)
					Button(String.localized(.appUI.reader.close), action: onClose)
				}
				.foregroundStyle(Color(nsColor: appearance.theme.isDark ? .white : .black).opacity(0.7))
				.padding(24)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			ReaderControls(appearance: appearance, set: set, onClose: onClose)
				.padding(BrowserMetrics.FindBar.inset)
				.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.environment(\.colorScheme, appearance.theme.isDark ? .dark : .light)
		.onExitCommand(perform: onClose)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.reader.command))
	}

	private func set(_ appearance: ReaderAppearance) {
		themeName = appearance.theme.rawValue
		textSize = appearance.textSize
		width = appearance.width
	}
}

/// The reader's controls, on a material that keeps them legible over any theme.
private struct ReaderControls: View {
	internal let appearance: ReaderAppearance
	internal let set: (ReaderAppearance) -> Void
	internal let onClose: () -> Void

	internal var body: some View {
		HStack(spacing: 2) {
			ForEach(ReaderAppearance.Theme.allCases, id: \.self) { theme in
				Button {
					var next = appearance
					next.theme = theme
					set(next)
				} label: {
					Circle()
						.fill(theme.swatch)
						.overlay {
							Circle().strokeBorder(
								appearance.theme == theme ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(Color.secondary.opacity(0.4)),
								lineWidth: appearance.theme == theme ? 2 : 1
							)
						}
						.frame(width: 16, height: 16)
						.frame(width: 26, height: 26)
						.contentShape(.rect)
				}
				.buttonStyle(.plain)
				.help(theme.title)
				.accessibilityLabel(theme.title)
				.accessibilityAddTraits(appearance.theme == theme ? .isSelected : [])
			}
			Divider().frame(height: 16).padding(.horizontal, 4)
			control(
				"textformat.size.smaller",
				String.localized(.appUI.reader.smallerText),
				enabled: appearance.canShrinkText
			) {
				set(appearance.steppingText(by: -1))
			}
			control(
				"textformat.size.larger",
				String.localized(.appUI.reader.largerText),
				enabled: appearance.canGrowText
			) {
				set(appearance.steppingText(by: 1))
			}
			control(
				"arrow.right.and.line.vertical.and.arrow.left",
				String.localized(.appUI.reader.narrower),
				enabled: appearance.canNarrow
			) {
				set(appearance.steppingWidth(by: -1))
			}
			control(
				"arrow.left.and.line.vertical.and.arrow.right",
				String.localized(.appUI.reader.wider),
				enabled: appearance.canWiden
			) {
				set(appearance.steppingWidth(by: 1))
			}
			Divider().frame(height: 16).padding(.horizontal, 4)
			control(
				"xmark",
				String.localized(.appUI.reader.close),
				enabled: true,
				action: onClose
			)
		}
		.font(.system(size: 12, weight: .medium))
		.padding(.horizontal, 6)
		.padding(.vertical, 3)
		.background(.regularMaterial, in: .capsule)
		.overlay { Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5) }
	}

	private func control(
		_ symbol: String,
		_ title: String,
		enabled: Bool,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.frame(width: 26, height: 26)
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.disabled(!enabled)
		.opacity(enabled ? 1 : 0.35)
		.help(title)
		.accessibilityLabel(title)
	}
}
