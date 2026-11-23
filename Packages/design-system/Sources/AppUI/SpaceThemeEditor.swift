import BrowserCore
import SwiftUI

/// A theme in one panel (DEV-1253): a dotted color field with a dot per color, light or dark at its
/// top, a row of preset colors, the wave-shaped intensity slider and the texture dial. A space's
/// popover shows it, and so do Settings for the browser default and each profile (DEV-1286).
///
/// The field (DEV-1299): the dots sit on a circle, all the same distance
/// from its centre, at fixed angles from the main one (`ThemeDots`). Dragging the main dot turns
/// and scales the set; pressing another makes it the main one where it stands.
///
/// The field doubles as the preview: it's drawn in the colors and texture being chosen. With no
/// colors placed a space or profile uses the level above's; removing the last dot goes back to
/// them, and the dial's menu does the same for the texture. At the browser default, the level
/// above is Arx's own default theme.
///
/// Drags reach `onPreview` only, so nothing is saved per frame; `onCommit` runs once when a drag
/// ends, or when a discrete control changes.
public struct SpaceThemeEditor: View {
	/// How the panel arranges its parts. Both show the same controls on the same model.
	public enum Layout: Sendable {
		/// A column as narrow as `width`, as a space's popover shows it.
		case popover

		/// For a Settings section: the field beside the presets and sliders where the card is wide
		/// enough, else the column, then Match site, the accent and the reset as rows of their own.
		case settings
	}

	private let level: ChromeAppearanceEditor.Level
	private let layout: Layout
	private let choices: AppearanceOverride
	private let inherited: ChromeAppearance
	private let offersMatchSite: Bool
	private let offersAccent: Bool
	private let onPreview: (AppearanceOverride?) -> Void
	private let onCommit: (AppearanceOverride) -> Void
	private let onClear: () -> Void
	private let matchSiteRow: (AnyView) -> AnyView

	@SwiftUI.State
	private var draft: AppearanceOverride?

	/// Counts resets, so the accent rows drop a custom color still waiting to be saved.
	@SwiftUI.State
	private var resets: Int

	/// Each dot's identity by its index, main dot first, so a dot keeps its view when pressing it
	/// makes it the main one and its motion runs from where it was.
	@SwiftUI.State
	private var dotIDs: [Int]

	@Environment(\.colorScheme)
	private var colorScheme

	/// - Parameters:
	///   - level: Whose theme it is: the browser default's, a profile's or a space's.
	///   - layout: A popover's column, or Settings' arrangement for a wide card.
	///   - choices: This level's own choices. The browser default passes every setting.
	///   - inherited: What the level above resolves to: Arx's default for the browser default.
	///   - onPreview: The edit in progress during a drag, then nil once it ends.
	///   - onClear: Resets the browser default, or makes a profile or space inherit everything.
	///   - offersMatchSite: Shows the Match site switch (DEV-1101).
	///   - offersAccent: Shows the accent color (DEV-1117).
	///   - matchSiteRow: Wraps the Match site row, as Settings marks it for its search.
	public init(
		level: ChromeAppearanceEditor.Level = .space,
		layout: Layout = .popover,
		choices: AppearanceOverride,
		inherited: ChromeAppearance,
		offersMatchSite: Bool = false,
		offersAccent: Bool = false,
		onPreview: @escaping (AppearanceOverride?) -> Void = { _ in },
		onCommit: @escaping (AppearanceOverride) -> Void,
		onClear: @escaping () -> Void,
		matchSiteRow: @escaping (AnyView) -> AnyView = { $0 }
	) {
		self.level = level
		self.layout = layout
		self.choices = choices
		self.inherited = inherited
		self.offersMatchSite = offersMatchSite
		self.offersAccent = offersAccent
		self.onPreview = onPreview
		self.onCommit = onCommit
		self.onClear = onClear
		self.matchSiteRow = matchSiteRow
		self._draft = .init(initialValue: nil)
		self._resets = .init(initialValue: 0)
		self._dotIDs = .init(initialValue: Array(0 ..< ThemeDots.Arrangement.splitComplementary.count))
	}

	/// The panel's width, as its popovers lay it out.
	public static let width: CGFloat = 300

	/// The field's side beside the controls in Settings' wide arrangement, which fits a profile
	/// page's card (544 points inside) as well as Settings › Appearance & Sound's (592).
	private static let wideFieldSide: CGFloat = 232
	private static let wideSpacing: CGFloat = 20

	private var current: AppearanceOverride { draft ?? choices }
	private var resolved: ChromeAppearance { current.applied(to: inherited) }
	private var dots: ThemeDots? { current.themeDots(over: inherited) }

	public var body: some View {
		switch layout {
		case .popover:
			VStack(alignment: .leading, spacing: 14) {
				column
				rows
			}
		case .settings:
			// One subview per row, so a Settings section draws dividers between them.
			ViewThatFits(in: .horizontal) {
				wide
				column.frame(width: Self.width)
			}
			.padding(.vertical, 14)
			.frame(maxWidth: .infinity)
			rows
		}
	}

	/// The field over the presets and sliders.
	private var column: some View {
		VStack(alignment: .leading, spacing: 14) {
			field
				.frame(height: Self.width)
			presets(isCompact: false)
			sliders
		}
	}

	/// The field beside the presets and sliders, centred between them.
	private var wide: some View {
		HStack(alignment: .center, spacing: Self.wideSpacing) {
			field
				.frame(width: Self.wideFieldSide, height: Self.wideFieldSide)
			VStack(alignment: .leading, spacing: 18) {
				presets(isCompact: true)
				sliders
			}
			.frame(minWidth: ThemeSwatchNavigator.compactWidth, maxWidth: Self.width + 40)
		}
	}

	@ViewBuilder
	private var rows: some View {
		if offersMatchSite || offersAccent {
			ChromeAppearanceEditor(
				level: level,
				sections: [.matchSite, .accent],
				offersMatchSite: offersMatchSite,
				offersAccent: offersAccent,
				// The committed choices, so a drag here doesn't count as a change there.
				choices: choices,
				inherited: inherited,
				onPreview: onPreview,
				onCommit: { commit($0) },
				matchSiteRow: matchSiteRow,
				resets: resets
			)
		}

		if canClear {
			HStack {
				Spacer()
				Button(clearTitle, action: clear)
					.buttonStyle(.link)
					.font(.caption)
			}
			.padding(.vertical, layout == .settings ? 10 : 0)
		}
	}

	private var field: some View {
		ThemeColorField(
			level: level,
			dots: dots,
			dotIDs: dotIDs,
			mode: current.theme,
			appearance: resolved,
			scheme: previewScheme,
			onPlace: { point in
				let next = (dots ?? ThemeDots(main: resolved.tint)).moving(to: point)
				commit(current.settingThemeDots(next, over: inherited))
			},
			onPress: promote,
			onMove: { point, isFinal in
				guard let dots else { return }

				update(current.settingThemeDots(dots.moving(to: point), over: inherited), isFinal: isFinal)
			},
			onNudge: { hue, intensity in
				guard let dots else { return }

				let next = ThemeDots(
					angle: dots.angle + hue,
					distance: ThemeDots.distance(forIntensity: ThemeDots.intensity(atDistance: dots.distance) + intensity),
					arrangement: dots.arrangement
				)
				commit(current.settingThemeDots(next, over: inherited))
			},
			onAdd: add,
			onRemove: remove,
			onMode: { mode in commit { $0.theme = mode } }
		)
	}

	private func presets(isCompact: Bool) -> some View {
		ThemeSwatchNavigator(
			dots: dots,
			isDark: current.theme == .dark,
			// The browser default's light or dark is Settings' own Theme, so it has no dark presets.
			pages: level == .global ? Array(ThemePreset.pages.prefix(2)) : ThemePreset.pages,
			isCompact: isCompact,
			onSelect: applyPreset
		)
	}

	private var sliders: some View {
		HStack(alignment: .center, spacing: 16) {
			WaveSlider(
				value: dots.map { ThemeDots.intensity(atDistance: $0.distance) } ?? resolved.tint.intensity,
				label: String.localized(.appUI.appearance.intensity),
				// the knob shows once a color does.
				showsHandle: dots != nil,
				onChange: { value, isFinal in
					update(current.settingThemeIntensity(value, over: inherited), isFinal: isFinal)
				}
			)
			TextureDial(
				level: level,
				texture: current.themeTexture(over: inherited),
				intensity: resolved.grain.intensity,
				inherits: !current.overridesGrain,
				onCycle: { commit(current.settingThemeTexture(AppearanceOverride.nextThemeTexture(after: $0))) },
				onIntensity: { value, isFinal in
					update(
						{
							var next = current.settingThemeTexture(current.themeTexture(over: inherited) ?? .noise)
							next.grainIntensity = value
							return next
						}(),
						isFinal: isFinal
					)
				},
				onInherit: { commit(current.inheritingGrain()) }
			)
		}
	}

	/// A profile or space with choices of its own, or a browser default that differs from Arx's.
	private var canClear: Bool {
		switch level {
		case .global: choices.applied(to: inherited) != inherited
		case .profile, .space: !choices.isEmpty
		}
	}

	/// Back to the level above, or Arx's default for the browser default.
	private var clearTitle: String {
		switch level {
		case .global: String.localized(.appUI.appearance.reset)
		case .profile: String.localized(.appUI.appearance.useGlobal)
		case .space: String.localized(.appUI.appearance.useProfile)
		}
	}

	private var previewScheme: ColorScheme {
		switch current.theme {
		case .light: .light
		case .dark: .dark
		case nil: colorScheme
		}
	}

	// MARK: - Colors

	/// Plus: over the level above's colors, its tint becomes this level's first dot.
	private func add() {
		guard let next = dots.map({ $0.adding() }) ?? ThemeDots(main: resolved.tint) else { return }

		commit(current.settingThemeDots(next, over: inherited))
	}

	/// Minus: three dots become two, two one, and one none, which inherits the level above's colors.
	private func remove() {
		guard let dots else { return }

		commit(current.settingThemeDots(dots.removing(), over: inherited))
	}

	/// Pressing a dot that isn't the main one makes it the main one where it stands. A press is
	/// shown at once and saved with the drag that follows; VoiceOver's action saves it at once.
	private func promote(
		_ index: Int,
		isFinal: Bool
	) {
		guard let dots, index > 0 else { return }

		let (next, previous) = dots.promoting(index)
		var ids = previous.map { dotIDs[safe: $0] ?? $0 }
		ids += dotIDs.filter { !ids.contains($0) }
		dotIDs = ids
		update(current.settingThemeDots(next, over: inherited), isFinal: isFinal)
	}

	/// A preset replaces the colors; a dark one chooses Dark too.
	private func applyPreset(_ preset: ThemePreset) {
		commit { next in
			next = next.settingThemeDots(preset.dots, over: inherited)
			if preset.isDark { next.theme = .dark }
		}
	}

	// MARK: - Committing

	private func update(
		_ next: AppearanceOverride,
		isFinal: Bool
	) {
		if isFinal {
			commit(next)
		} else {
			draft = next
			onPreview(next)
		}
	}

	private func commit(_ change: (inout AppearanceOverride) -> Void) {
		var next = current
		change(&next)
		commit(next)
	}

	private func commit(_ next: AppearanceOverride) {
		draft = nil
		onPreview(nil)
		onCommit(next)
	}

	private func clear() {
		resets += 1
		draft = nil
		onPreview(nil)
		onClear()
	}
}

// MARK: - Color field

/// The dotted field: the theme's chrome behind a grid of dots, a draggable dot per color, light or
/// dark at the top and − and + at the bottom. The dots stay inside the circle inscribed in the
/// square field; angle is hue and the distance from the centre the strength (`ThemeDots`).
private struct ThemeColorField: View {
	fileprivate let level: ChromeAppearanceEditor.Level
	fileprivate let dots: ThemeDots?
	fileprivate let dotIDs: [Int]
	fileprivate let mode: AppearanceOverride.Theme?
	fileprivate let appearance: ChromeAppearance
	fileprivate let scheme: ColorScheme

	/// A click where no dot is: the first dot lands there, or the main one moves there.
	fileprivate let onPlace: (ThemeDots.Point) -> Void

	/// A dot that isn't the main one was pressed: shown, and saved when the flag says so.
	fileprivate let onPress: (Int, Bool) -> Void
	fileprivate let onMove: (ThemeDots.Point, Bool) -> Void

	/// Turns the hue and changes the intensity, from the keyboard and VoiceOver.
	fileprivate let onNudge: (_ hue: Double, _ intensity: Double) -> Void
	fileprivate let onAdd: () -> Void
	fileprivate let onRemove: () -> Void
	fileprivate let onMode: (AppearanceOverride.Theme?) -> Void

	/// Whether a dot is held: every dot grows while one is.
	@SwiftUI.State
	private var isHolding: Bool = false

	private static let shape: RoundedRectangle = .init(cornerRadius: 16, style: .continuous)

	/// Keeps a dot at the circle's edge from touching the field's.
	private static let margin: CGFloat = 4

	/// Plus and minus spring the dots round the circle: about 270 ms with a 6% overshoot in the
	/// recording. Measured from frames; tune by eye.
	fileprivate static let spring: Animation = .spring(duration: 0.28, bounce: 0.3)

	fileprivate var body: some View {
		GeometryReader { proxy in
			let side = min(proxy.size.width, proxy.size.height)
			let circle = Area(
				center: .init(x: proxy.size.width / 2, y: proxy.size.height / 2),
				radius: max(side / 2 - Self.margin, 1)
			)
			ZStack {
				background
					.contentShape(Self.shape)
					.gesture(
						SpatialTapGesture().onEnded { tap in onPlace(circle.point(at: tap.location)) }
					)
					.accessibilityHidden(true)

				if dots == nil { emptyPrompt(circle: circle) }

				if let dots {
					ForEach(Self.slots(dots: dots, ids: dotIDs)) { slot in
						let index = slot.index
						ThemeColorDot(
							tint: dots.colors[index],
							index: index,
							// Offsets from the main dot unwrapped, so a spring turns the short way.
							angle: dots.angle + (index == 0 ? 0 : dots.arrangement.offsets[index - 1]),
							distance: dots.distance,
							isHolding: isHolding,
							circle: circle,
							onPress: { isFinal in onPress(index, isFinal) },
							onHold: { isHolding = $0 },
							onMove: onMove,
							onNudge: onNudge,
							onRemove: onRemove
						)
						.transition(.identity)
					}
					.animation(Self.spring, value: dots.arrangement)
				}

				// Over the dots, as a dot may sit under them near the edge: the buttons always take
				// the click, and the dot can still be taken hold of round them.
				VStack {
					// The browser default's light or dark is Settings' own Theme, just above the panel.
					if level != .global { modePicker }
					Spacer()
					countButtons
				}
				.padding(.vertical, 10)
			}
			.coordinateSpace(.named(ThemeColorDot.space))
		}
		.aspectRatio(1, contentMode: .fit)
		.clipShape(Self.shape)
		.overlay {
			Self.shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.appearance.colorField))
	}

	/// The chrome these choices draw, light or dark as chosen, under a grid of faint dots.
	private var background: some View {
		BrowserChromeBackground(textured: true)
			.browserChromeAppearance(appearance)
			.environment(\.colorScheme, scheme)
			.overlay {
				Canvas { context, size in
					let spacing: CGFloat = 8
					let dot = Path(ellipseIn: .init(x: -0.6, y: -0.6, width: 1.2, height: 1.2))
					var y = spacing / 2
					while y < size.height {
						var x = spacing / 2
						while x < size.width {
							context.fill(dot.offsetBy(dx: x, dy: y), with: .color(.primary.opacity(0.16)))
							x += spacing
						}
						y += spacing
					}
				}
				.environment(\.colorScheme, scheme)
				.allowsHitTesting(false)
			}
	}

	private func emptyPrompt(circle: Area) -> some View {
		VStack(spacing: 4) {
			Text(verbatim: prompt)
				.font(.callout.weight(.semibold))
			Text(verbatim: inheritedNote)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.multilineTextAlignment(.center)
		.padding(.horizontal, 24)
		.environment(\.colorScheme, scheme)

		// A click anywhere places the first dot there, the prompt included.
		.allowsHitTesting(false)
		.position(circle.center)
	}

	private var prompt: String {
		switch level {
		case .global: String.localized(.appUI.appearance.colorFieldPromptGlobal)
		case .profile: String.localized(.appUI.appearance.colorFieldPromptProfile)
		case .space: String.localized(.appUI.appearance.colorFieldPrompt)
		}
	}

	/// Whose colors show while this level has none of its own.
	private var inheritedNote: String {
		switch level {
		case .global: String.localized(.appUI.appearance.colorFieldInheritedGlobal)
		case .profile: String.localized(.appUI.appearance.colorFieldInheritedProfile)
		case .space: String.localized(.appUI.appearance.colorFieldInherited)
		}
	}

	/// Automatic, light and dark: Automatic follows the profile and the system.
	private var modePicker: some View {
		HStack(spacing: 6) {
			modeButton(nil, symbol: "sparkles", title: String.localized(.appUI.appearance.modeAutomatic))
			modeButton(.light, symbol: "sun.max", title: AppearanceOverride.Theme.light.title)
			modeButton(.dark, symbol: "moon.stars", title: AppearanceOverride.Theme.dark.title)
		}
		.padding(3)
		.background(.ultraThinMaterial, in: .capsule)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.appearance.mode))
	}

	private func modeButton(
		_ theme: AppearanceOverride.Theme?,
		symbol: String,
		title: String
	) -> some View {
		let isSelected = mode == theme
		return Button { onMode(theme) } label: {
			Image(systemName: symbol)
				.font(.system(size: 13, weight: .medium))
				.frame(width: 30, height: 24)
				.foregroundStyle(isSelected ? .primary : .secondary)
				.background(isSelected ? Color.primary.opacity(0.14) : .clear, in: .capsule)
				.contentShape(.capsule)
		}
		.buttonStyle(.plain)
		.help(title)
		.accessibilityLabel(title)
		.accessibilityAddTraits(isSelected ? .isSelected : [])
	}

	private var countButtons: some View {
		HStack(spacing: 4) {
			countButton(symbol: "minus", title: String.localized(.appUI.appearance.removeColor), action: onRemove)
				.disabled(dots == nil)
			countButton(symbol: "plus", title: String.localized(.appUI.appearance.addColor), action: onAdd)
				.disabled(dots.map { $0.adding() == nil } ?? false)
		}
		.padding(3)
		.background(.ultraThinMaterial, in: .capsule)
	}

	private func countButton(
		symbol: String,
		title: String,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 13, weight: .semibold))
				.frame(width: 30, height: 24)
				.contentShape(.capsule)
		}
		.buttonStyle(.plain)
		.help(title)
		.accessibilityLabel(title)
	}

	/// A dot's identity and its index, main dot first.
	private struct Slot: Identifiable {
		fileprivate let id: Int
		fileprivate let index: Int
	}

	private static func slots(
		dots: ThemeDots,
		ids: [Int]
	) -> [Slot] {
		(0 ..< dots.count).map { index in .init(id: ids.indices.contains(index) ? ids[index] : index, index: index) }
	}

	/// The circle the dots' centres stay in, in the field's coordinates.
	fileprivate struct Area {
		fileprivate let center: CGPoint
		fileprivate let radius: CGFloat

		/// A location in the field as a point of `ThemeDots`, in units of the radius.
		fileprivate func point(at location: CGPoint) -> ThemeDots.Point {
			.init(
				x: Double((location.x - center.x) / radius),
				y: Double((location.y - center.y) / radius)
			)
		}

		fileprivate func location(
			angle: Double,
			distance: Double
		) -> CGPoint {
			let point = ThemeDots.point(angle: angle, distance: distance)
			return .init(x: center.x + CGFloat(point.x) * radius, y: center.y + CGFloat(point.y) * radius)
		}
	}
}

/// One color on the field. The main dot is larger. Drag the main dot to turn and scale the set;
/// press another to make it the main one where it stands, then drag on. Focus a dot and use the
/// arrow keys: left and right turn the hue, up and down change the intensity. VoiceOver adjusts the
/// hue and offers the rest as actions.
private struct ThemeColorDot: View {
	fileprivate let tint: ChromeTint
	fileprivate let index: Int

	/// Degrees, not wrapped, so a spring between two angles turns the short way round.
	fileprivate let angle: Double
	fileprivate let distance: Double
	fileprivate let isHolding: Bool
	fileprivate let circle: ThemeColorField.Area

	/// Makes this dot the main one; true saves it at once.
	fileprivate let onPress: (Bool) -> Void
	fileprivate let onHold: (Bool) -> Void
	fileprivate let onMove: (ThemeDots.Point, Bool) -> Void
	fileprivate let onNudge: (_ hue: Double, _ intensity: Double) -> Void
	fileprivate let onRemove: () -> Void

	/// Where the pointer took hold of the dot, from the dot's centre.
	@SwiftUI.State
	private var grab: CGSize?

	@FocusState
	private var isFocused: Bool

	fileprivate static let space: String = "ThemeColorField"

	/// The main dot is 44 px across its ring in a 678 px field, the others 26 px: in a 300-point
	/// field, 38 and 22 points.
	private static let mainDiameter: CGFloat = 38
	private static let secondaryDiameter: CGFloat = 22

	/// Every dot grows by this while one is held, over about 120 ms.
	private static let holdingScale: CGFloat = 1.1
	private static let hueStep: Double = 5
	private static let intensityStep: Double = 0.05

	private var isMain: Bool { index == 0 }

	fileprivate var body: some View {
		let diameter = (isMain ? Self.mainDiameter : Self.secondaryDiameter) * circle.radius / 146
		Circle()
			.fill(Color(themeSwatch: tint))
			.frame(width: diameter, height: diameter)
			.overlay { Circle().strokeBorder(.white, lineWidth: isMain ? 4 : 3) }
			.shadow(color: .black.opacity(0.25), radius: 3, y: 1)
			.overlay {
				if isFocused {
					Circle()
						.strokeBorder(Color.accentColor, lineWidth: 2)
						.padding(-4)
				}
			}
			.scaleEffect(isHolding ? Self.holdingScale : 1)
			.animation(.easeOut(duration: 0.12), value: isHolding)
			.animation(.snappy(duration: 0.2), value: isMain)
			.contentShape(.circle.inset(by: -6))
			.pointerStyle(grab == nil ? .grabIdle : .grabActive)
			.modifier(PolarPosition(angle: angle, distance: distance, circle: circle))
			.zIndex(isMain ? 1 : 0)
			.gesture(
				DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
					.onChanged { drag in
						if grab == nil {
							let center = circle.location(angle: angle, distance: distance)
							grab = .init(width: center.x - drag.startLocation.x, height: center.y - drag.startLocation.y)
							onHold(true)
							if !isMain { onPress(false) }
						}
						onMove(point(at: drag.location), false)
					}
					.onEnded { drag in
						onMove(point(at: drag.location), true)
						grab = nil
						onHold(false)
					}
			)
			.focusable()
			.focused($isFocused)
			.focusEffectDisabled()
			.onKeyPress(.leftArrow) { nudge(hue: -Self.hueStep) }
			.onKeyPress(.rightArrow) { nudge(hue: Self.hueStep) }
			.onKeyPress(.upArrow) { nudge(intensity: Self.intensityStep) }
			.onKeyPress(.downArrow) { nudge(intensity: -Self.intensityStep) }
			.onKeyPress(.delete) {
				onRemove()
				return .handled
			}
			.accessibilityElement()
			.accessibilityLabel(Text(localized: .appUI.appearance.gradientColor(index + 1)))
			.accessibilityValue(Text(localized: .appUI.appearance.colorValue(
				TintName(hue: tint.hue).title,
				Int((tint.intensity * 100).rounded())
			)))
			.accessibilityAddTraits(isMain ? .isSelected : [])
			.accessibilityAdjustableAction { direction in
				switch direction {
				case .increment: _ = nudge(hue: Self.hueStep * 3)
				case .decrement: _ = nudge(hue: -Self.hueStep * 3)
				@unknown default: break
				}
			}
			.accessibilityAction(named: Text(localized: .appUI.appearance.moreIntense)) {
				_ = nudge(intensity: Self.intensityStep * 2)
			}
			.accessibilityAction(named: Text(localized: .appUI.appearance.lessIntense)) {
				_ = nudge(intensity: -Self.intensityStep * 2)
			}
			.accessibilityAction(named: Text(localized: .appUI.appearance.makeMainColor)) {
				if !isMain { onPress(true) }
			}
			.accessibilityAction(named: Text(localized: .appUI.appearance.removeColor), onRemove)
	}

	/// Where the main dot goes for a pointer location, keeping the offset it was taken hold at.
	private func point(at location: CGPoint) -> ThemeDots.Point {
		let grab = grab ?? .zero
		return circle.point(at: .init(x: location.x + grab.width, y: location.y + grab.height))
	}

	private func nudge(
		hue: Double = 0,
		intensity: Double = 0
	) -> KeyPress.Result {
		onNudge(hue, intensity)
		return .handled
	}
}

/// Places a dot by its angle and distance, so motion between two places runs round the circle.
private struct PolarPosition: ViewModifier, Animatable {
	fileprivate var angle: Double
	fileprivate var distance: Double
	fileprivate let circle: ThemeColorField.Area

	fileprivate nonisolated var animatableData: AnimatablePair<Double, Double> {
		get { .init(angle, distance) }
		set {
			angle = newValue.first
			distance = newValue.second
		}
	}

	fileprivate func body(content: Content) -> some View {
		content.position(circle.location(angle: angle, distance: distance))
	}
}

// MARK: - Presets

/// Pages of presets: single colors, gradients and dark colors.
private struct ThemeSwatchNavigator: View {
	fileprivate let dots: ThemeDots?
	fileprivate let isDark: Bool
	fileprivate let pages: [[ThemePreset]]

	/// Tighter, beside the field in Settings.
	fileprivate let isCompact: Bool
	fileprivate let onSelect: (ThemePreset) -> Void

	@SwiftUI.State
	private var page: Int = 0

	/// The compact row's width: nine 24-point swatches, the gaps between them and the arrows.
	fileprivate static let compactWidth: CGFloat = 9 * 24 + 8 * compactSpacing + 2 * compactArrow + 2 * 4
	private static let compactSpacing: CGFloat = 4
	private static let compactArrow: CGFloat = 16

	fileprivate var body: some View {
		HStack(spacing: 4) {
			arrow("chevron.left", title: .appUI.appearance.previousPresets) { page -= 1 }
				.disabled(page == 0)

			HStack(spacing: isCompact ? Self.compactSpacing : 6) {
				ForEach(pages[min(page, pages.count - 1)], id: \.self) { preset in
					let isSelected = preset.matches(dots, isDark: isDark)
					Button { onSelect(preset) } label: {
						Circle()
							.fill(preset.swatch)
							.frame(width: 20, height: 20)
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
					.help(preset.title)
					.accessibilityLabel(preset.title)
					.accessibilityAddTraits(isSelected ? .isSelected : [])
				}
			}
			.frame(maxWidth: .infinity)
			.id(page)
			.transition(.opacity)

			arrow("chevron.right", title: .appUI.appearance.nextPresets) { page += 1 }
				.disabled(page >= pages.count - 1)
		}
		.animation(.easeOut(duration: 0.15), value: page)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.appearance.presets))
	}

	private func arrow(
		_ symbol: String,
		title: _XCStringResource,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: 13, weight: .semibold))
				.frame(width: isCompact ? Self.compactArrow : 20, height: 24)
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.foregroundStyle(.secondary)
		.help(String.localized(title))
		.accessibilityLabel(Text(localized: title))
	}
}

/// A preset: a named hue as one dot, a gradient of three, or one dark color.
private struct ThemePreset: Hashable {
	fileprivate enum Kind: Hashable {
		case single
		case gradient
		case dark
	}

	fileprivate let name: TintName
	fileprivate let kind: Kind
	fileprivate let dots: ThemeDots

	fileprivate var isDark: Bool { kind == .dark }

	fileprivate var title: String {
		switch kind {
		case .single: name.title
		case .gradient: String.localized(.appUI.appearance.gradientPreset(name.title))
		case .dark: String.localized(.appUI.appearance.darkPreset(name.title))
		}
	}

	/// The swatch: the color, or the gradient's three across it.
	fileprivate var swatch: AnyShapeStyle {
		let colors = dots.colors.map { Color(themeSwatch: $0, dark: isDark) }
		guard colors.count == 3 else { return AnyShapeStyle(colors[0]) }

		// The dot 40° behind the main one, the main one, the one 40° ahead.
		return AnyShapeStyle(LinearGradient(colors: [colors[2], colors[0], colors[1]], startPoint: .topLeading, endPoint: .bottomTrailing))
	}

	/// Whether the theme is this preset.
	fileprivate func matches(
		_ other: ThemeDots?,
		isDark: Bool
	) -> Bool {
		guard let other, other.arrangement == dots.arrangement, isDark == self.isDark else { return false }

		let difference = abs(other.angle - dots.angle).truncatingRemainder(dividingBy: 360)
		return min(difference, 360 - difference) < 1 && abs(other.distance - dots.distance) < 0.01
	}

	private static let names: [TintName] = [.white, .pink, .purple, .red, .orange, .yellow, .green, .sky, .slate]

	/// The pages: single colors at half the radius, gradients nearer the centre and so stronger,
	/// and dark colors. White sits near the edge, where colors fade to neutral.
	fileprivate static let pages: [[Self]] = [
		names.map { .init(name: $0, kind: .single, dots: .init(angle: $0.hue, distance: $0.isNeutral ? 0.95 : 0.5)) },
		names.map {
			.init(
				name: $0,
				kind: .gradient,
				dots: .init(angle: $0.hue, distance: $0.isNeutral ? 0.9 : 0.4, arrangement: .analogous)
			)
		},
		names.map { .init(name: $0, kind: .dark, dots: .init(angle: $0.hue, distance: $0.isNeutral ? 0.95 : 0.5)) },
	]
}

/// The names Arx gives hues, for presets and for VoiceOver to read a dot's color.
private enum TintName: CaseIterable {
	case white
	case pink
	case purple
	case red
	case orange
	case yellow
	case green
	case teal
	case sky
	case blue
	case slate

	/// The nearest named hue.
	fileprivate init(hue: Double) {
		let named: [Self] = [.red, .orange, .yellow, .green, .teal, .sky, .blue, .purple, .pink]
		self = named.min { lhs, rhs in
			Self.distance(lhs.hue, hue) < Self.distance(rhs.hue, hue)
		} ?? .blue
	}

	fileprivate var hue: Double {
		switch self {
		case .white: 40
		case .pink: 330
		case .purple: 280
		case .red: 0
		case .orange: 30
		case .yellow: 55
		case .green: 130
		case .teal: 175
		case .sky: 205
		case .blue: ChromeTint.default.hue
		case .slate: 230
		}
	}

	fileprivate var isNeutral: Bool { self == .white }

	fileprivate var title: String {
		switch self {
		case .white: String.localized(.appUI.appearance.hueWhite)
		case .pink: String.localized(.appUI.appearance.huePink)
		case .purple: String.localized(.appUI.appearance.huePurple)
		case .red: String.localized(.appUI.appearance.hueRed)
		case .orange: String.localized(.appUI.appearance.hueOrange)
		case .yellow: String.localized(.appUI.appearance.hueYellow)
		case .green: String.localized(.appUI.appearance.hueGreen)
		case .teal: String.localized(.appUI.appearance.hueTeal)
		case .sky: String.localized(.appUI.appearance.hueSky)
		case .blue: String.localized(.appUI.appearance.hueBlue)
		case .slate: String.localized(.appUI.appearance.hueSlate)
		}
	}

	private static func distance(
		_ lhs: Double,
		_ rhs: Double
	) -> Double {
		let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
		return min(difference, 360 - difference)
	}
}

// MARK: - Intensity

/// The intensity as a wave: the part left of the handle drawn bright, the rest faint. Drag it, click
/// along it, or focus it and use the arrow keys; VoiceOver reads and adjusts it as a slider.
private struct WaveSlider: View {
	fileprivate let value: Double
	fileprivate let label: String

	/// Hidden while there's no color of this level's own.
	fileprivate let showsHandle: Bool
	fileprivate let onChange: (Double, Bool) -> Void

	@SwiftUI.State
	private var dragged: Double?

	@FocusState
	private var isFocused: Bool

	private static let step: Double = 0.05
	private static let height: CGFloat = 44
	private static let handle: CGSize = .init(width: 18, height: 40)

	fileprivate var body: some View {
		let shown = dragged ?? value
		GeometryReader { proxy in
			let track = proxy.size.width - Self.handle.width
			let x = Self.handle.width / 2 + CGFloat(shown) * track
			ZStack(alignment: .leading) {
				Capsule()
					.fill(.primary.opacity(0.06))
					.frame(height: 22)
				WaveShape(cycles: 6)
					.stroke(.primary.opacity(0.18), style: .init(lineWidth: 4, lineCap: .round))
				WaveShape(cycles: 6)
					.stroke(.primary.opacity(0.65), style: .init(lineWidth: 4, lineCap: .round))
					.mask(alignment: .leading) { Rectangle().frame(width: x) }
				Capsule()
					.fill(.white)
					.overlay { Capsule().strokeBorder(.black.opacity(0.18), lineWidth: 0.5) }
					.shadow(color: .black.opacity(0.3), radius: 2, y: 1)
					.frame(width: Self.handle.width, height: Self.handle.height)
					.overlay {
						if isFocused {
							Capsule().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
						}
					}
					.offset(x: x - Self.handle.width / 2)
					.opacity(showsHandle || dragged != nil ? 1 : 0)
			}
			.frame(maxHeight: .infinity)
			.contentShape(.rect)
			.gesture(
				DragGesture(minimumDistance: 0)
					.onChanged { drag in
						let value = value(at: drag.location.x, track: track)
						dragged = value
						onChange(value, false)
					}
					.onEnded { drag in
						dragged = nil
						onChange(value(at: drag.location.x, track: track), true)
					}
			)
		}
		.frame(height: Self.height)
		.focusable()
		.focused($isFocused)
		.focusEffectDisabled()
		.onKeyPress(.leftArrow) { nudge(-Self.step) }
		.onKeyPress(.rightArrow) { nudge(Self.step) }
		.accessibilityRepresentation {
			Slider(
				value: Binding(get: { value }, set: { onChange($0, true) }),
				in: 0 ... 1,
				step: Self.step
			) { Text(verbatim: label) }
		}
	}

	private func value(
		at x: CGFloat,
		track: CGFloat
	) -> Double {
		Double(min(max((x - Self.handle.width / 2) / max(track, 1), 0), 1))
	}

	private func nudge(_ delta: Double) -> KeyPress.Result {
		onChange(min(max(value + delta, 0), 1), true)
		return .handled
	}
}

/// A sine wave across its rect, inset by the stroke's caps.
private struct WaveShape: Shape {
	fileprivate let cycles: Int

	fileprivate func path(in rect: CGRect) -> Path {
		var path = Path()
		let inset: CGFloat = 4
		let width = rect.width - inset * 2
		let amplitude = rect.height * 0.22
		let steps = max(Int(width), 1)
		for step in 0 ... steps {
			let progress = CGFloat(step) / CGFloat(steps)
			let point = CGPoint(
				x: rect.minX + inset + progress * width,
				y: rect.midY + sin(progress * CGFloat(cycles) * 2 * .pi) * amplitude
			)
			step == 0 ? path.move(to: point) : path.addLine(to: point)
		}
		return path
	}
}

// MARK: - Texture

/// The texture dial. Clicking the inner circle moves to the next texture: Noise, Jeans, Paper,
/// Textile, Clear. The ring of dots around it sets the texture's intensity: drag around it, or focus the
/// dial and use the arrow keys. Its menu goes back to the profile's texture.
private struct TextureDial: View {
	fileprivate let level: ChromeAppearanceEditor.Level
	fileprivate let texture: ChromeGrain.Texture?
	fileprivate let intensity: Double
	fileprivate let inherits: Bool
	fileprivate let onCycle: (ChromeGrain.Texture?) -> Void
	fileprivate let onIntensity: (Double, Bool) -> Void
	fileprivate let onInherit: () -> Void

	@SwiftUI.State
	private var dragged: Double?

	@FocusState
	private var isFocused: Bool

	private static let diameter: CGFloat = 64
	private static let ringDots: Int = 24
	private static let step: Double = 0.05

	/// The ring runs clockwise from the top, leaving a gap at the bottom between its ends.
	private static let sweep: Double = 300

	fileprivate var body: some View {
		let shown = dragged ?? intensity
		VStack(spacing: 4) {
			ZStack {
				ring(shown)
				Button { onCycle(texture) } label: {
					// Mid-grey, which the soft-light texture shows best on, in light and dark alike.
					Circle()
						.fill(Color.gray.opacity(texture == nil ? 0.12 : 0.45))
						.overlay {
							if let texture {
								FilmGrain(style: .init(intensity: 1, size: 1, texture: texture))
									.clipShape(.circle)
							}
						}
						.overlay { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1) }
						.frame(width: Self.diameter * 0.56, height: Self.diameter * 0.56)
						.contentShape(.circle)
				}
				.buttonStyle(.plain)
				.help(String.localized(.appUI.appearance.texture))
				.accessibilityLabel(Text(localized: .appUI.appearance.texture))
				.accessibilityValue(Text(verbatim: Self.title(texture)))
				.accessibilityHint(Text(verbatim: Self.title(AppearanceOverride.nextThemeTexture(after: texture))))
			}
			.frame(width: Self.diameter, height: Self.diameter)

			Text(verbatim: Self.title(texture))
				.font(.caption2)
				.foregroundStyle(inherits ? .tertiary : .secondary)
				.accessibilityHidden(true)
		}
		.focusable()
		.focused($isFocused)
		.onKeyPress(.space) {
			onCycle(texture)
			return .handled
		}
		.onKeyPress(.upArrow) { nudge(Self.step) }
		.onKeyPress(.rightArrow) { nudge(Self.step) }
		.onKeyPress(.downArrow) { nudge(-Self.step) }
		.onKeyPress(.leftArrow) { nudge(-Self.step) }
		.contextMenu {
			Button(inheritTitle, action: onInherit)
				.disabled(inherits)
		}
		.accessibilityElement(children: .contain)
	}

	/// The ring of dots; those up to the intensity are lit, and the last lit one is the handle.
	private func ring(_ value: Double) -> some View {
		GeometryReader { proxy in
			let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
			let radius = proxy.size.width / 2 - 3
			ZStack {
				ForEach(0 ..< Self.ringDots, id: \.self) { index in
					let progress = Double(index) / Double(Self.ringDots - 1)
					let angle = Self.angle(for: progress)
					let isLit = texture != nil && progress <= value + 0.001
					Circle()
						.fill(.primary.opacity(isLit ? 0.75 : 0.2))
						.frame(width: 3.5, height: 3.5)
						.position(Self.point(at: angle, center: center, radius: radius))
				}
				if texture != nil {
					Capsule()
						.fill(.white)
						.overlay { Capsule().strokeBorder(.black.opacity(0.25), lineWidth: 0.5) }
						.shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
						.frame(width: 6, height: 12)
						.rotationEffect(Self.angle(for: value) + .degrees(90))
						.position(Self.point(at: Self.angle(for: value), center: center, radius: radius))
				}
				if isFocused {
					Circle().strokeBorder(Color.accentColor, lineWidth: 2)
				}
			}
			.contentShape(.circle)
			.gesture(
				DragGesture(minimumDistance: 1)
					.onChanged { drag in
						let value = Self.value(at: drag.location, center: center)
						dragged = value
						onIntensity(value, false)
					}
					.onEnded { drag in
						dragged = nil
						onIntensity(Self.value(at: drag.location, center: center), true)
					}
			)
		}
		.accessibilityRepresentation {
			Slider(
				value: Binding(get: { intensity }, set: { onIntensity($0, true) }),
				in: ChromeGrain.intensityRange,
				step: Self.step
			) { Text(localized: .appUI.appearance.textureIntensity) }
		}
	}

	/// Where a value sits on the ring: the start is at the bottom left, the end at the bottom right.
	private static func angle(for value: Double) -> Angle {
		.degrees(90 + (360 - sweep) / 2 + value * sweep)
	}

	private static func point(
		at angle: Angle,
		center: CGPoint,
		radius: CGFloat
	) -> CGPoint {
		.init(
			x: center.x + cos(angle.radians) * radius,
			y: center.y + sin(angle.radians) * radius
		)
	}

	private static func value(
		at location: CGPoint,
		center: CGPoint
	) -> Double {
		var degrees = atan2(location.y - center.y, location.x - center.x) * 180 / .pi
		degrees -= 90 + (360 - sweep) / 2
		while degrees < 0 { degrees += 360 }

		// In the gap at the bottom, the nearer end.
		if degrees > sweep { return degrees - sweep < (360 - sweep) / 2 ? 1 : 0 }
		return min(max(degrees / sweep, 0), 1)
	}

	private func nudge(_ delta: Double) -> KeyPress.Result {
		onIntensity(min(max(intensity + delta, 0), 1), true)
		return .handled
	}

	/// The menu item that drops this level's texture for the level above's.
	private var inheritTitle: String {
		switch level {
		case .global: String.localized(.appUI.appearance.inheritTextureGlobal)
		case .profile: String.localized(.appUI.appearance.inheritTextureProfile)
		case .space: String.localized(.appUI.appearance.inheritTexture)
		}
	}

	fileprivate static func title(_ texture: ChromeGrain.Texture?) -> String {
		switch texture {
		case .noise: String.localized(.appUI.appearance.textureNoise)
		case .jeans: String.localized(.appUI.appearance.textureJeans)
		case .paper: String.localized(.appUI.appearance.texturePaper)
		case .textile: String.localized(.appUI.appearance.textureTextile)
		case nil: String.localized(.appUI.appearance.textureClear)
		}
	}
}

// MARK: - Helpers

extension Color {
	/// A tint as a swatch or a dot shows it: brighter and more saturated than the chrome takes it,
	/// so colors stay tellable apart, and near-white at no intensity. A dark preset's swatch is dim.
	fileprivate init(
		themeSwatch tint: ChromeTint,
		dark: Bool = false
	) {
		let tint = tint.normalized ?? .default
		self.init(
			hue: tint.hue / 360,
			saturation: 0.06 + 0.6 * tint.intensity,
			brightness: (0.95 - 0.12 * tint.intensity) * (dark ? 0.5 : 1)
		)
	}
}

extension Array {
	fileprivate subscript(safe index: Int) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}
