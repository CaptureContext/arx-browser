import SwiftUI

/// The homepage's controls. Each section shows only what applies to its current choice.
public struct EmptyPageEditor: View {
	@Binding
	private var style: EmptyPageStyle

	public init(style: Binding<EmptyPageStyle>) {
		self._style = style
	}

	public var body: some View {
		Form {
			presets
			logo
			cursor
			effect
			guide
			background
		}
		.formStyle(.grouped)
	}

	private var presets: some View {
		Section {
			HStack {
				Menu(String.localized(.appUI.emptyPage.presets)) {
					ForEach(EmptyPageStyle.presets) { preset in
						Button(preset.title) { style = preset.style }
					}
				}
				Button(String.localized(.appUI.emptyPage.reset)) { style = .captureContext }
					.disabled(style == .captureContext)
			}
		}
	}

	private var logo: some View {
		Section(String.localized(.appUI.emptyPage.logo)) {
			Picker(String.localized(.appUI.emptyPage.placement), selection: $style.logo.placement) {
				ForEach(EmptyPageStyle.LogoPlacement.allCases) { placement in
					Text(placement.title).tag(placement)
				}
			}
			.pickerStyle(.segmented)
			if style.logo.placement != .off {
				EmptyPageSlider(String.localized(.appUI.emptyPage.size), value: $style.logo.current.size, in: 0...1) { size in
					String.localized(.appUI.emptyPage.valueTimes((0.5 + size * 2).formatted(.number.precision(.fractionLength(2)))))
				}
				EmptyPageSlider(String.localized(.appUI.emptyPage.opacity), value: $style.logo.current.opacity, in: 0...1, format: .percent)
				Picker(String.localized(.appUI.emptyPage.blendMode), selection: $style.logo.current.blend) {
					ForEach(EmptyPageStyle.Blend.allCases) { blend in
						Text(blend.title).tag(blend)
					}
				}
				Toggle(String.localized(.appUI.emptyPage.glass), isOn: $style.logo.glass)
				Toggle(String.localized(.appUI.emptyPage.hologram), isOn: $style.logo.hologram)
			}
		}
	}

	private var cursor: some View {
		Section(String.localized(.appUI.emptyPage.cursor)) {
			Picker(String.localized(.appUI.emptyPage.shape), selection: $style.cursor.shape) {
				ForEach(EmptyPageStyle.CursorShape.allCases) { shape in
					Text(shape.title).tag(shape)
				}
			}
			.pickerStyle(.segmented)
			if style.cursor.shape != .regular {
				EmptyPageSlider(String.localized(.appUI.emptyPage.size), value: $style.cursor.size, in: EmptyPageStyle.Cursor.sizeRange, format: .points)
				EmptyPageHuePicker(String.localized(.appUI.emptyPage.fill), selection: $style.cursor.fill.color)
				EmptyPageSlider(String.localized(.appUI.emptyPage.fillOpacity), value: $style.cursor.fill.opacity, in: 0...1, format: .percent)
				EmptyPageHuePicker(String.localized(.appUI.emptyPage.stroke), selection: $style.cursor.stroke.color)
				EmptyPageSlider(String.localized(.appUI.emptyPage.strokeOpacity), value: $style.cursor.stroke.opacity, in: 0...1, format: .percent)
				EmptyPageSlider(String.localized(.appUI.emptyPage.strokeWidth), value: $style.cursor.strokeWidth, in: EmptyPageStyle.Cursor.strokeRange, format: .points)
			}
		}
	}

	private var effect: some View {
		Section(String.localized(.appUI.emptyPage.effect)) {
			Picker(String.localized(.appUI.emptyPage.effect), selection: $style.effect) {
				ForEach(EmptyPageStyle.Effect.allCases) { effect in
					Text(effect.title).tag(effect)
				}
			}
			.pickerStyle(.segmented)
			if style.effect == .inkTrail {
				Picker(String.localized(.appUI.emptyPage.coloring), selection: $style.ink.coloring) {
					ForEach(EmptyPageStyle.InkColoring.allCases) { coloring in
						Text(coloring.title).tag(coloring)
					}
				}
				if style.ink.coloring != .rainbow {
					EmptyPageHuePicker(
						style.ink.coloring == .shifting
						? String.localized(.appUI.emptyPage.colorFrom)
						: String.localized(.appUI.emptyPage.color),
						selection: $style.ink.color
					)
				}
				if style.ink.coloring == .shifting {
					EmptyPageHuePicker(String.localized(.appUI.emptyPage.colorTo), selection: $style.ink.secondColor)
				}
				EmptyPageSlider(String.localized(.appUI.emptyPage.width), value: $style.ink.width, in: EmptyPageStyle.Ink.widthRange, format: .points)
				EmptyPageSlider(String.localized(.appUI.emptyPage.dryingTime), value: $style.ink.drying, in: EmptyPageStyle.Ink.dryingRange) { seconds in
					String.localized(.appUI.emptyPage.valueSeconds(seconds.formatted(.number.precision(.fractionLength(1)))))
				}
				EmptyPageSlider(String.localized(.appUI.emptyPage.softness), value: $style.ink.softness, in: 0...1, format: .percent)
				EmptyPageSlider(String.localized(.appUI.emptyPage.opacity), value: $style.ink.opacity, in: 0...1, format: .percent)
				Toggle(String.localized(.appUI.emptyPage.tapers), isOn: $style.ink.tapers)
			}
		}
	}

	private var guide: some View {
		Section(String.localized(.appUI.emptyPage.guide)) {
			Picker(String.localized(.appUI.emptyPage.guide), selection: $style.guide) {
				ForEach(EmptyPageStyle.Guide.allCases) { guide in
					Text(guide.title).tag(guide)
				}
			}
			.pickerStyle(.segmented)
			if style.guide != .none, style.logo.placement != .centered {
				Picker(String.localized(.appUI.emptyPage.position), selection: $style.guidePosition) {
					ForEach(EmptyPageStyle.GuidePosition.allCases) { position in
						Text(position.title).tag(position)
					}
				}
				.pickerStyle(.segmented)
			}
		}
	}

	private var background: some View {
		Section(String.localized(.appUI.emptyPage.background)) {
			Picker(String.localized(.appUI.emptyPage.background), selection: $style.background) {
				ForEach(EmptyPageStyle.Background.allCases) { background in
					Text(background.title).tag(background)
				}
			}
			if style.background == .sky {
				Toggle(String.localized(.appUI.emptyPage.stars), isOn: $style.sky.stars)
				Toggle(String.localized(.appUI.emptyPage.clouds), isOn: $style.sky.clouds)
			}
		}
	}
}

/// A pop-up of the homepage's named colors.
private struct EmptyPageHuePicker: View {
	let title: String

	@Binding
	var selection: EmptyPageStyle.Hue

	init(
		_ title: String,
		selection: Binding<EmptyPageStyle.Hue>
	) {
		self.title = title
		self._selection = selection
	}

	var body: some View {
		Picker(title, selection: $selection) {
			ForEach(EmptyPageStyle.Hue.allCases) { hue in
				Text(hue.title).tag(hue)
			}
		}
	}
}

/// A slider with its title and its value.
private struct EmptyPageSlider: View {
	enum Format {
		case percent
		case points
	}

	let title: String

	@Binding
	var value: Double

	let range: ClosedRange<Double>
	let label: (Double) -> String

	init(
		_ title: String,
		value: Binding<Double>,
		in range: ClosedRange<Double>,
		label: @escaping (Double) -> String
	) {
		self.title = title
		self._value = value
		self.range = range
		self.label = label
	}

	init(
		_ title: String,
		value: Binding<Double>,
		in range: ClosedRange<Double>,
		format: Format
	) {
		self.init(title, value: value, in: range) { value in
			switch format {
			case .percent:
				value.formatted(.percent.precision(.fractionLength(0)))
			case .points:
				String.localized(.appUI.emptyPage.valuePoints(value.formatted(.number.precision(.fractionLength(0...1)))))
			}
		}
	}

	var body: some View {
		LabeledContent(title) {
			HStack {
				Slider(value: $value, in: range)
					.labelsHidden()
				Text(label(value))
					.monospacedDigit()
					.foregroundStyle(.secondary)
					.frame(width: 48, alignment: .trailing)
			}
		}
	}
}
