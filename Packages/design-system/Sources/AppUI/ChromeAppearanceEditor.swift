import AppKit
import BrowserCore
import SwiftUI

/// Match site and the accent color for one level of the appearance cascade. The theme panel
/// (`SpaceThemeEditor`) draws the colors, light or dark, intensity and texture, and nests these
/// rows under them (DEV-1253, DEV-1286).
///
/// The custom color picker's drags reach `onPreview` only, so nothing is saved per frame;
/// `onCommit` runs once the picker rests, or when a discrete control changes.
public struct ChromeAppearanceEditor: View {
	public enum Level: Sendable {
		/// Settings › Appearance: every setting is chosen, and nothing is inherited.
		case global

		/// A profile, inheriting from the app-wide appearance.
		case profile

		/// A space, inheriting from its profile.
		case space
	}

	/// The rows to show.
	public struct Sections: OptionSet, Sendable {
		public let rawValue: Int

		public init(rawValue: Int) {
			self.rawValue = rawValue
		}

		/// Match site, where the level offers it.
		public static let matchSite: Self = .init(rawValue: 1 << 1)

		/// The accent color, where the level offers it.
		public static let accent: Self = .init(rawValue: 1 << 2)

		public static let all: Self = [.matchSite, .accent]
	}

	private let level: Level
	private let sections: Sections

	/// Offers Match site (DEV-1101) at this level (DEV-1170), behind `MatchSiteBackground.featureFlag`.
	private let offersMatchSite: Bool

	/// Offers the accent color (DEV-1117), behind `ChromeAccent.featureFlag`.
	private let offersAccent: Bool
	private let choices: AppearanceOverride
	private let inherited: ChromeAppearance
	private let onPreview: (AppearanceOverride?) -> Void
	private let onCommit: (AppearanceOverride) -> Void
	private let matchSiteRowWrapper: (AnyView) -> AnyView

	/// Counts the resets the theme panel around these rows makes (DEV-1286).
	private let resets: Int

	@SwiftUI.State
	private var draft: AppearanceOverride?

	/// The custom color picker's pending commit: it reports every step of a drag, and only the
	/// color it rests on is saved.
	@SwiftUI.State
	private var accentCommit: Task<Void, Never>?

	/// The custom color `accentCommit` will save.
	@SwiftUI.State
	private var pendingAccent: ChromeAccent?

	@Environment(\.colorScheme)
	private var colorScheme

	/// - Parameters:
	///   - choices: This level's own choices. The global level passes every setting.
	///   - inherited: What the level above resolves to.
	///   - onPreview: The edit in progress during a drag, then nil once it ends.
	///   - offersMatchSite: Shows the Match site toggle.
	///   - offersAccent: Shows the accent color.
	///   - matchSiteRow: Wraps the Match site row, as Settings marks it for its search.
	///   - resets: Counts the resets the theme panel around these rows makes. A custom color still
	///     waiting to be saved is dropped when it changes, so it can't undo a reset.
	///   - sections: The parts to show.
	public init(
		level: Level,
		sections: Sections = .all,
		offersMatchSite: Bool = false,
		offersAccent: Bool = false,
		choices: AppearanceOverride,
		inherited: ChromeAppearance,
		onPreview: @escaping (AppearanceOverride?) -> Void = { _ in },
		onCommit: @escaping (AppearanceOverride) -> Void,
		matchSiteRow: @escaping (AnyView) -> AnyView = { $0 },
		resets: Int = 0
	) {
		self.level = level
		self.sections = sections
		self.offersMatchSite = offersMatchSite
		self.offersAccent = offersAccent
		self.choices = choices
		self.inherited = inherited
		self.onPreview = onPreview
		self.onCommit = onCommit
		self.matchSiteRowWrapper = matchSiteRow
		self.resets = resets
		self._draft = .init(initialValue: nil)
		self._accentCommit = .init(initialValue: nil)
		self._pendingAccent = .init(initialValue: nil)
	}

	private var current: AppearanceOverride { draft ?? choices }
	private var resolved: ChromeAppearance { current.applied(to: inherited) }
	private var inherits: Bool { level != .global }

	/// One row per setting, so a grouped section draws dividers between them; elsewhere they stack.
	public var body: some View {
		if offersMatchSite, sections.contains(.matchSite) { matchSiteRowWrapper(AnyView(matchSiteRow)) }

		if offersAccent, sections.contains(.accent) { accentRow }
	}

	/// Match site (DEV-1101): the chrome takes the shown page's color, and the tint below stays for
	/// pages without one. A profile or space inherits until it turns it on or off, as for the accent
	/// (DEV-1170); the switch shows the setting in effect.
	private var matchSiteRow: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				Text(localized: .appUI.appearance.matchSite)
				inheritControl(overridden: current.matchesSite != nil) { commit(current.inheritingMatchSite()) }
				Spacer(minLength: 12)
				Toggle(String.localized(.appUI.appearance.matchSite), isOn: matchSiteSelection)
					.labelsHidden()
					.toggleStyle(.switch)
					.controlSize(.small)
			}
			Text(localized: .appUI.appearance.matchSiteDescription)
				.font(.caption)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
		}
		.appearanceEditorRow()
	}

	/// The accent color (DEV-1117): Automatic at the app-wide level, a preset, or a custom color.
	/// A profile or space inherits until it chooses one.
	private var accentRow: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 8) {
				Text(localized: .appUI.appearance.accent)
				inheritControl(overridden: current.accent != nil) { commit(current.inheritingAccent()) }
				Spacer(minLength: 12)
				ColorPicker(
					String.localized(.appUI.appearance.accentCustom),
					selection: customAccent,
					supportsOpacity: false
				)
				.labelsHidden()
				.help(String.localized(.appUI.appearance.accentCustom))
			}
			AccentSwatches(
				selection: inherits ? resolved.accent : current.accent,
				automatic: inherits ? nil : ChromeAccent.automatic(tint: resolved.tint, isDark: previewScheme == .dark),
				onSelect: { accent in commit { $0.accent = accent } }
			)
		}
		.appearanceEditorRow()
		.onDisappear { editorDisappeared() }
		.onChange(of: ChoicesChange(choices: choices, resets: resets)) { old, new in
			choicesChanged(reset: old.resets != new.resets)
		}
	}

	/// The choices and the resets together, so a reset and the choices it brings are seen at once.
	private struct ChoicesChange: Equatable {
		let choices: AppearanceOverride
		let resets: Int
	}

	/// The choices changed elsewhere, as the theme panel around these rows commits (DEV-1253). A
	/// custom color still waiting is saved now over the new choices, since its task holds the old
	/// ones; after a reset, to the level above or to Arx's default, it's dropped.
	private func choicesChanged(reset: Bool) {
		draft = nil
		guard let accent = pendingAccent else { return }

		cancelPendingAccent()
		guard !reset, !choices.isEmpty else { return }

		commit { $0.accent = accent }
	}

	/// The custom color, shown as the accent in effect: the chosen one or Automatic's.
	private var customAccent: Binding<Color> {
		Binding(
			get: {
				Color(resolved.accent?.rgb ?? ChromeAccent.automatic(tint: resolved.tint, isDark: previewScheme == .dark))
			},
			set: { color in customAccentPicked(color) }
		)
	}

	/// Shows the picked color at once and saves it once the picker rests.
	private func customAccentPicked(_ color: Color) {
		guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }

		let accent = ChromeAccent(
			red: Double(srgb.redComponent),
			green: Double(srgb.greenComponent),
			blue: Double(srgb.blueComponent)
		)
		preview { $0.accent = accent }
		accentCommit?.cancel()
		pendingAccent = accent
		accentCommit = Task { @MainActor in
			try? await Task.sleep(for: .milliseconds(400))
			guard !Task.isCancelled, pendingAccent == accent else { return }

			commit { $0.accent = accent }
		}
	}

	private var previewScheme: ColorScheme {
		switch current.theme {
		case .light: .light
		case .dark: .dark
		case nil: colorScheme
		}
	}

	/// For a profile or space: a button that goes back to the level above, or a quiet note that it
	/// already follows it.
	@ViewBuilder
	private func inheritControl(
		overridden: Bool,
		inherit: @escaping () -> Void
	) -> some View {
		if inherits {
			if overridden {
				Button(String.localized(.appUI.appearance.inheritSetting), action: inherit)
					.buttonStyle(.link)
					.font(.caption)
			} else {
				Text(localized: .appUI.appearance.inherited)
					.font(.caption)
					.foregroundStyle(.secondary)
			}
		}
	}

	/// On or off is this level's own choice, over the level above's, until Inherit drops it.
	private var matchSiteSelection: Binding<Bool> {
		Binding(
			get: { resolved.matchesSite },
			set: { matches in commit { $0.matchesSite = matches } }
		)
	}

	private func preview(_ change: (inout AppearanceOverride) -> Void) {
		var next = current
		change(&next)
		draft = next
		onPreview(next)
	}

	private func commit(_ change: (inout AppearanceOverride) -> Void) {
		var next = current
		change(&next)
		commit(next)
	}

	private func commit(_ next: AppearanceOverride) {
		// A discrete choice supersedes a custom color still waiting to be saved.
		cancelPendingAccent()
		draft = nil
		onPreview(nil)
		onCommit(next)
	}

	private func cancelPendingAccent() {
		accentCommit?.cancel()
		accentCommit = nil
		pendingAccent = nil
	}

	/// The editor went away with a custom color still waiting: it's the last one picked, so it's saved.
	private func editorDisappeared() {
		guard let accent = pendingAccent else { return }

		commit { $0.accent = accent }
	}
}

extension View {
	/// An editor row: compact enough for a popover, and a row of its own in a grouped section.
	fileprivate func appearanceEditorRow() -> some View {
		padding(.vertical, 8)
			.frame(minHeight: 36)
	}
}

/// Automatic, when the level offers it, then the preset accents (DEV-1117).
private struct AccentSwatches: View {
	private let selection: ChromeAccent?

	/// Automatic's color, at the app-wide level; nil where a level inherits instead.
	private let automatic: ChromePalette.RGB?
	private let onSelect: (ChromeAccent?) -> Void

	fileprivate init(
		selection: ChromeAccent?,
		automatic: ChromePalette.RGB?,
		onSelect: @escaping (ChromeAccent?) -> Void
	) {
		self.selection = selection
		self.automatic = automatic
		self.onSelect = onSelect
	}

	fileprivate var body: some View {
		HStack(spacing: 6) {
			if let automatic {
				swatch(
					Color(automatic),
					title: String.localized(.appUI.appearance.accentAutomatic),
					isSelected: selection == nil,
					symbol: "a.circle"
				) { onSelect(nil) }
			}
			ForEach(ChromeAccent.Preset.allCases, id: \.self) { preset in
				swatch(
					Color(preset.accent.rgb),
					title: preset.title,
					isSelected: selection == preset.accent,
					symbol: nil
				) { onSelect(preset.accent) }
			}
		}
	}

	private func swatch(
		_ color: Color,
		title: String,
		isSelected: Bool,
		symbol: String?,
		select: @escaping () -> Void
	) -> some View {
		Button(action: select) {
			Circle()
				.fill(color)
				.frame(width: 18, height: 18)
				.overlay {
					if let symbol {
						Image(systemName: symbol)
							.font(.system(size: 11, weight: .semibold))
							.foregroundStyle(.white)
					}
				}
				.overlay {
					Circle().strokeBorder(
						isSelected ? Color.accentColor : Color.primary.opacity(0.15),
						lineWidth: isSelected ? 2 : 1
					)
				}
				.padding(2)
				.contentShape(.circle)
		}
		.buttonStyle(.plain)
		.help(title)
		.accessibilityLabel(title)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}
}

extension ChromeAccent.Preset {
	fileprivate var title: String {
		switch self {
		case .indigo: String.localized(.appUI.appearance.accentIndigo)
		case .blue: String.localized(.appUI.appearance.hueBlue)
		case .purple: String.localized(.appUI.appearance.huePurple)
		case .pink: String.localized(.appUI.appearance.huePink)
		case .red: String.localized(.appUI.appearance.hueRed)
		case .orange: String.localized(.appUI.appearance.hueOrange)
		case .yellow: String.localized(.appUI.appearance.hueYellow)
		case .green: String.localized(.appUI.appearance.hueGreen)
		case .teal: String.localized(.appUI.appearance.hueTeal)
		case .graphite: String.localized(.appUI.appearance.accentGraphite)
		}
	}
}
