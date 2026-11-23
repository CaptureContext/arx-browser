import AppUI
import BrowserCore
import SwiftUI

/// System, Light and Dark, each as a small Arx window in the current window background.
internal struct AppThemePicker: View {
	private let selection: AppTheme
	private let chromeAppearance: ChromeAppearance
	private let select: (AppTheme) -> Void

	internal init(
		selection: AppTheme,
		chromeAppearance: ChromeAppearance,
		select: @escaping (AppTheme) -> Void
	) {
		self.selection = selection
		self.chromeAppearance = chromeAppearance
		self.select = select
	}

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.appearance.theme),
			footer: String.localized(.appUI.appearance.themeDescription)
		) {
			HStack(alignment: .top, spacing: 16) {
				ForEach(AppTheme.allCases, id: \.self) { theme in
					AppThemeOption(
						theme: theme,
						isSelected: theme == selection,
						chromeAppearance: chromeAppearance
					) { select(theme) }
				}
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 14)
		}
	}
}

private struct AppThemeOption: View {
	internal let theme: AppTheme
	internal let isSelected: Bool
	internal let chromeAppearance: ChromeAppearance
	internal let select: () -> Void

	internal var body: some View {
		Button(action: select) {
			VStack(spacing: 8) {
				AppThemeWindowPreview(theme: theme, chromeAppearance: chromeAppearance)
					.padding(3)
					.overlay {
						RoundedRectangle(cornerRadius: 15, style: .continuous)
							.strokeBorder(Color.accentColor, lineWidth: 2.5)
							.opacity(isSelected ? 1 : 0)
					}
				Text(theme.title)
					.font(.system(size: 13, weight: isSelected ? .semibold : .regular))
					.foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
			}
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.frame(maxWidth: .infinity)
		.accessibilityLabel(Text(theme.title))
		.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
	}
}

/// A miniature Arx window: the tinted frame, a sidebar of rows and a page card.
private struct AppThemeWindowPreview: View {
	internal let theme: AppTheme
	internal let chromeAppearance: ChromeAppearance

	internal static let size: CGSize = .init(width: 148, height: 88)

	internal var body: some View {
		Group {
			switch theme {
			case .system:
				ZStack {
					window.environment(\.colorScheme, .light)
					window.environment(\.colorScheme, .dark)
						.mask(alignment: .trailing) {
							Rectangle().frame(width: Self.size.width / 2)
						}
				}
			case .light:
				window.environment(\.colorScheme, .light)
			case .dark:
				window.environment(\.colorScheme, .dark)
			}
		}
		.frame(width: Self.size.width, height: Self.size.height)
		.clipShape(.rect(cornerRadius: 12, style: .continuous))
		.accessibilityHidden(true)
	}

	private var window: some View {
		WindowSketch()
			.browserChromeAppearance(chromeAppearance)
	}
}

private struct WindowSketch: View {
	@Environment(\.colorScheme)
	private var colorScheme

	internal var body: some View {
		ZStack(alignment: .bottom) {
			BrowserChromeBackground(textured: true)
			HStack(alignment: .top, spacing: 5) {
				VStack(alignment: .leading, spacing: 4) {
					ForEach(0 ..< 6, id: \.self) { index in
						Capsule()
							.fill(.primary.opacity(index == 3 ? 0.35 : 0.14))
							.frame(width: index.isMultiple(of: 2) ? 16 : 22, height: 2.5)
					}
				}
				.frame(width: 26, alignment: .leading)
				.padding(.top, 10)

				VStack(alignment: .leading, spacing: 4) {
					Capsule().fill(.primary.opacity(0.7)).frame(width: 22, height: 3)
						.padding(.bottom, 4)
					Capsule().fill(.primary.opacity(0.18)).frame(width: 50, height: 2.5)
					Capsule().fill(.primary.opacity(0.18)).frame(width: 44, height: 2.5)
					ForEach(0 ..< 3, id: \.self) { index in
						HStack(spacing: 3) {
							RoundedRectangle(cornerRadius: 1, style: .continuous)
								.fill(index < 2 ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary.opacity(0.3)))
								.frame(width: 5, height: 5)
							Capsule().fill(.primary.opacity(0.18)).frame(width: 24, height: 2.5)
						}
					}
				}
				.padding(10)
				.frame(width: 76, height: 72, alignment: .topLeading)
				.background(pageColor, in: .rect(cornerRadius: 5, style: .continuous))
				.shadow(color: .black.opacity(0.12), radius: 2, y: 1)
			}
			.padding(.horizontal, 12)
		}
		.environment(\.colorScheme, colorScheme)
	}

	private var pageColor: Color {
		colorScheme == .dark ? Color(white: 0.13) : .white
	}
}

extension AppTheme {
	internal var title: String {
		switch self {
		case .system: String.localized(.appUI.appearance.themeSystem)
		case .light: String.localized(.appUI.appearance.themeLight)
		case .dark: String.localized(.appUI.appearance.themeDark)
		}
	}
}

/// The Dock icon while Arx runs: dark or light (DEV-839).
internal struct ApplicationIconSection: View {
	internal let selection: AppIconStyle
	internal let select: (AppIconStyle) -> Void

	internal var body: some View {
		SettingsSection(
			String.localized(.appUI.settings.icon),
			footer: String.localized(.appUI.settings.iconDescription)
		) {
			HStack(spacing: 16) {
				ForEach(AppIconStyle.allCases, id: \.self) { icon in
					ApplicationIconOption(
						icon: icon,
						isSelected: icon == selection,
						select: { select(icon) }
					)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.vertical, 14)
		}
	}
}

private struct ApplicationIconOption: View {
	internal let icon: AppIconStyle
	internal let isSelected: Bool
	internal let select: () -> Void

	internal var body: some View {
		Button(action: select) {
			VStack(spacing: 6) {
				Group {
					if let image = icon.image {
						Image(nsImage: image)
							.resizable()
							.interpolation(.high)
					} else {
						Color.clear
					}
				}
				.frame(width: 56, height: 56)
				.padding(4)
				.overlay {
					RoundedRectangle(cornerRadius: 16, style: .continuous)
						.strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
				}

				Text(verbatim: icon.title)
					.font(.system(size: 12, weight: isSelected ? .semibold : .regular))
					.foregroundStyle(isSelected ? Color.accentColor : .secondary)
			}
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(verbatim: icon.title))
		.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
	}
}
