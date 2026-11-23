import AppKit
import SwiftUI

/// A grouped list section for Settings: a header, its rows on one rounded card with a divider
/// between each, and a footnote under the card.
///
/// Rows are the content's direct subviews; a `ForEach` contributes one row per element.
public struct SettingsSection<Content: View, Footer: View>: View {
	private let title: String?
	private let caption: String?
	private let content: Content
	private let footer: Footer

	/// `caption` explains the section under its title; `footer` notes something under its rows.
	public init(
		_ title: String? = nil,
		caption: String? = nil,
		@ViewBuilder content: () -> Content,
		@ViewBuilder footer: () -> Footer
	) {
		self.title = title
		self.caption = caption
		self.content = content()
		self.footer = footer()
	}

	public var body: some View {
		let _ = RenderTrace.body("SettingsSection.body")
		VStack(alignment: .leading, spacing: 6) {
			if title != nil || caption != nil {
				VStack(alignment: .leading, spacing: 3) {
					if let title {
						Text(title)
							.font(SettingsGroupMetrics.headerFont)
							.accessibilityAddTraits(.isHeader)
					}
					if let caption {
						Text(caption)
							.font(SettingsGroupMetrics.footerFont)
							.foregroundStyle(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
				}
				.padding(.horizontal, SettingsGroupMetrics.inset)
				.padding(.bottom, 2)
			}
			SettingsGroupCard {
				Group(subviews: content) { rows in
					ForEach(rows) { row in
						if row.id != rows.first?.id {
							Divider()
						}
						row
					}
				}
			}
			footer
				.font(SettingsGroupMetrics.footerFont)
				.foregroundStyle(.secondary)
				.fixedSize(horizontal: false, vertical: true)
				.padding(.horizontal, SettingsGroupMetrics.inset)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

extension SettingsSection where Footer == EmptyView {
	public init(
		_ title: String? = nil,
		caption: String? = nil,
		@ViewBuilder content: () -> Content
	) {
		self.init(title, caption: caption, content: content, footer: { EmptyView() })
	}
}

extension SettingsSection where Footer == Text {
	public init(
		_ title: String? = nil,
		caption: String? = nil,
		footer: String,
		@ViewBuilder content: () -> Content
	) {
		self.init(title, caption: caption, content: content, footer: { Text(footer) })
	}
}

/// One row of a section: its title on the left, its control on the right.
public struct SettingsRow<Accessory: View>: View {
	private let title: String
	private let detail: String?
	private let accessory: Accessory

	public init(
		_ title: String,
		detail: String? = nil,
		@ViewBuilder accessory: () -> Accessory
	) {
		self.title = title
		self.detail = detail
		self.accessory = accessory()
	}

	public var body: some View {
		let _ = RenderTrace.body("SettingsRow.body")
		HStack(spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text(title)
				if let detail {
					Text(detail)
						.font(SettingsGroupMetrics.footerFont)
						.foregroundStyle(.secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			Spacer(minLength: 16)
			accessory
		}
		.settingsGroupRow()
	}
}

/// A row with a switch on the right, as grouped forms draw toggles.
public struct SettingsToggle: View {
	private let title: String
	private let detail: String?

	@Binding
	private var isOn: Bool

	public init(
		_ title: String,
		detail: String? = nil,
		isOn: Binding<Bool>
	) {
		self.title = title
		self.detail = detail
		self._isOn = isOn
	}

	public var body: some View {
		let _ = RenderTrace.body("SettingsToggle.body")
		SettingsRow(title, detail: detail) {
			Toggle(title, isOn: $isOn)
				.toggleStyle(.switch)
				.controlSize(.small)
				.labelsHidden()
		}
		.accessibilityElement(children: .combine)
	}
}

extension View {
	/// A section row's height and padding.
	public func settingsGroupRow() -> some View {
		padding(.vertical, 8)
			.frame(minHeight: SettingsGroupMetrics.rowHeight)
	}
}

/// A Settings row that opens a page or sheet (DEV-773): a fill shaped like the row, inside its
/// card and clear of the dividers around it, that lightens on hover and darkens when pressed.
///
/// The label lays out the row itself, with ``SwiftUI/View/settingsGroupRow()``, and keeps the
/// card's inset: the fill reaches past the label toward the card's edges on `edges`, such as
/// `.leading` for a row whose own controls sit on its trailing side. The whole label takes the
/// click, its empty space too (DEV-1002).
///
/// ```swift
/// Button { open(profile) } label: {
///     HStack { Text(profile.name); Spacer(); Image(systemName: "chevron.right") }
///         .settingsGroupRow()
/// }
/// .buttonStyle(.settingsGroupRow)
/// ```
public struct SettingsGroupRowButtonStyle: ButtonStyle {
	private let edges: Edge.Set

	public init(edges: Edge.Set = .horizontal) {
		self.edges = edges
	}

	public func makeBody(configuration: Configuration) -> some View {
		SettingsGroupRowButtonBody(
			label: configuration.label,
			isPressed: configuration.isPressed,
			edges: edges
		)
	}
}

extension ButtonStyle where Self == SettingsGroupRowButtonStyle {
	/// A Settings row that opens a page or sheet, with a row-shaped hover and pressed fill.
	public static var settingsGroupRow: Self { .init() }

	/// A Settings row whose fill reaches the card's inset only on `edges`.
	public static func settingsGroupRow(edges: Edge.Set) -> Self { .init(edges: edges) }
}

private struct SettingsGroupRowButtonBody<Label: View>: View {
	internal let label: Label
	internal let isPressed: Bool
	internal let edges: Edge.Set

	@Environment(\.isEnabled)
	private var isEnabled: Bool

	@Environment(\.arxControlStateOverride)
	private var stateOverride: ArxControlStateOverride

	@SwiftUI.State
	private var isHovered: Bool = false

	internal var body: some View {
		let hovered = isEnabled && (stateOverride.isHovered ?? isHovered)
		let pressed = isEnabled && (stateOverride.isPressed ?? isPressed)
		let reach = SettingsGroupMetrics.inset - SettingsGroupMetrics.rowFillInset
		label
			.contentShape(.rect)
			.background {
				RoundedRectangle(cornerRadius: SettingsGroupMetrics.rowFillCornerRadius, style: .continuous)
					.fill(SettingsGroupMetrics.rowFill(hovered: hovered, pressed: pressed))
					.padding(.leading, edges.contains(.leading) ? -reach : 0)
					.padding(.trailing, edges.contains(.trailing) ? -reach : 0)
					.padding(.vertical, SettingsGroupMetrics.rowFillInset)
			}
			.onHover { isHovered = $0 }
			.animation(.easeOut(duration: 0.12), value: hovered)
			.animation(.easeOut(duration: 0.08), value: pressed)
	}
}

/// The rounded card a section's rows sit on. Content lays out its own rows and dividers.
public struct SettingsGroupCard<Content: View>: View {
	private let content: Content

	public init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			content
		}
		.padding(.horizontal, SettingsGroupMetrics.inset)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(SettingsGroupMetrics.fill, in: .rect(cornerRadius: SettingsGroupMetrics.cornerRadius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: SettingsGroupMetrics.cornerRadius, style: .continuous)
				.strokeBorder(SettingsGroupMetrics.hairline, lineWidth: 0.5)
		}
	}
}

/// A text field drawn as a filled rounded card: its title as a caption above the value, and an
/// accent ring while it's being edited. It draws no pencil (DEV-1308): the card reads as a field.
public struct SettingsTextField: View {
	private let title: String
	private let prompt: String?

	@Binding
	private var text: String

	private let onEditingChanged: (Bool) -> Void
	private let onSubmit: () -> Void

	@FocusState
	private var isFocused: Bool

	/// `onEditingChanged` reports focus coming (true) and going (false); `onSubmit` is Return.
	public init(
		_ title: String,
		text: Binding<String>,
		prompt: String? = nil,
		onEditingChanged: @escaping (Bool) -> Void = { _ in },
		onSubmit: @escaping () -> Void = {}
	) {
		self.title = title
		self._text = text
		self.prompt = prompt
		self.onEditingChanged = onEditingChanged
		self.onSubmit = onSubmit
	}

	public var body: some View {
		SettingsFieldFrame(title, isEditing: isFocused) {
			// The caption already names the field: an empty one shows its prompt or nothing.
			TextField(title, text: $text, prompt: Text(prompt ?? ""))
				.textFieldStyle(.plain)
				.labelsHidden()
				.focused($isFocused)
				.onSubmit(onSubmit)
		}
		.onTapGesture { isFocused = true }
		.onChange(of: isFocused) { _, focused in onEditingChanged(focused) }
	}
}

/// The card a Settings field sits in, for fields SwiftUI doesn't draw, such as AppKit ones.
/// The field inside draws no border or background of its own; an AppKit field keeps its native
/// focus ring, since `isEditing` only follows focus the caller tracks.
public struct SettingsFieldFrame<Field: View>: View {
	private let title: String
	private let isEditing: Bool
	private let field: Field

	public init(
		_ title: String,
		isEditing: Bool = false,
		@ViewBuilder field: () -> Field
	) {
		self.title = title
		self.isEditing = isEditing
		self.field = field()
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title)
				.font(SettingsGroupMetrics.footerFont)
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			field
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(SettingsGroupMetrics.fill, in: ArxControlShape())
		.overlay {
			ArxControlShape()
				.strokeBorder(
					isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(SettingsGroupMetrics.hairline),
					lineWidth: isEditing ? 2 : 0.5
				)
		}
		.contentShape(.rect)
	}
}

internal enum SettingsGroupMetrics {
	internal static let rowHeight: CGFloat = 52
	internal static let inset: CGFloat = 14
	internal static let cornerRadius: CGFloat = 10
	internal static let headerFont: Font = .system(size: 13, weight: .semibold)
	internal static let footerFont: Font = .system(size: 11, weight: .regular)

	/// Lighter than the window in either appearance, as macOS draws grouped forms.
	internal static let fill: Color = .init(nsColor: NSColor(name: nil) { appearance in
		appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.75)
	})

	/// Between a drill-down row's fill and the card's edges or the dividers around it.
	internal static let rowFillInset: CGFloat = 4

	/// Concentric with the card's corners at ``rowFillInset``.
	internal static let rowFillCornerRadius: CGFloat = cornerRadius - rowFillInset

	/// A drill-down row's fill: none at rest, a hover fill, and a darker one while pressed. Dark
	/// rows lighten on hover; the light card is already near white, so there hover shades it
	/// faintly and pressing shades it more.
	internal static func rowFill(
		hovered: Bool,
		pressed: Bool
	) -> Color {
		if pressed { return rowPressedFill }
		if hovered { return rowHoveredFill }
		return .clear
	}

	private static let rowHoveredFill: Color = .init(nsColor: NSColor(name: nil) { appearance in
		appearance.isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.035)
	})

	private static let rowPressedFill: Color = .init(nsColor: NSColor(name: nil) { appearance in
		appearance.isDark ? NSColor.black.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.08)
	})

	internal static let hairline: Color = .init(nsColor: NSColor(name: nil) { appearance in
		appearance.isDark ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.08)
	})
}

extension NSAppearance {
	fileprivate var isDark: Bool {
		bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
	}
}
