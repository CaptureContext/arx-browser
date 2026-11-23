import BrowserCore
import SwiftUI

/// Page PiP's space picker (DEV-1184), where Little Arx's profile picker sits in the URL bar: the
/// floating tab's space as its Switch to Space shortcut, "⌃1", "⌃2"…, with the space's name on
/// hover, opening a menu of the spaces in the same order. Choosing another moves the tab there.
/// A space of another profile names its profile in the menu, since moving there asks first.
public struct PagePictureInPictureSpacePicker: View {
	public struct Option: Identifiable, Equatable, Sendable {
		public var id: Space.ID
		public var name: String

		/// The space's Switch to Space shortcut, as the menu shows it ("⌃1"), or its number past
		/// the ninth, which has none.
		public var shortcut: String

		/// The space's profile, shown under its name for a space of another profile than the
		/// tab's; `nil` for the tab's own.
		public var otherProfileName: String?

		public init(
			id: Space.ID,
			name: String,
			shortcut: String,
			otherProfileName: String? = nil
		) {
			self.id = id
			self.name = name
			self.shortcut = shortcut
			self.otherProfileName = otherProfileName
		}
	}

	private let options: [Option]
	private let currentID: Space.ID?
	private let selectsCurrent: Bool
	private let onSelect: (Space.ID) -> Void

	/// - Parameters:
	///   - selectsCurrent: Whether choosing the current space acts too, as Little Arx's
	///     does: its current space is where it opens, not where its tab is.
	public init(
		options: [Option],
		currentID: Space.ID?,
		selectsCurrent: Bool = false,
		onSelect: @escaping (Space.ID) -> Void
	) {
		self.options = options
		self.currentID = currentID
		self.selectsCurrent = selectsCurrent
		self.onSelect = onSelect
	}

	public var body: some View {
		Menu {
			ForEach(options) { option in
				Button {
					if selectsCurrent || option.id != currentID { onSelect(option.id) }
				} label: {
					if option.id == currentID {
						Label(option.name, systemImage: "checkmark")
					} else {
						Text(option.name)
					}
					if let profile = option.otherProfileName {
						Text(profile)
					}
				}
			}
		} label: {
			PagePictureInPictureSpaceBadge(
				shortcut: current?.shortcut ?? "",
				height: BrowserMetrics.URLBar.accessoryHeight(forHeight: BrowserMetrics.LittleArx.addressHeight),
				cornerRadius: BrowserMetrics.URLBar.accessoryCornerRadius(forHeight: BrowserMetrics.LittleArx.addressHeight)
			)
		}
		.menuStyle(.button)
		.buttonStyle(.plain)
		.menuIndicator(.hidden)
		.fixedSize()

		// The badge takes its room before the address, as the profile picker does.
		.layoutPriority(1)
		.help(current?.name ?? "")
		.accessibilityLabel(String.localized(.appUI.pagePicture.spaceLabel(current?.name ?? "")))
		.accessibilityIdentifier("page-picture-space-picker")
	}

	private var current: Option? {
		options.first { $0.id == currentID }
	}
}

/// The picker's label: the space's shortcut on a faint fill, as the profile badge draws its name,
/// raised on hover, its corners concentric with the URL bar's.
internal struct PagePictureInPictureSpaceBadge: View {
	internal let shortcut: String
	internal let height: CGFloat
	internal let cornerRadius: CGFloat

	@SwiftUI.State
	private var hovered: Bool = false

	internal var body: some View {
		Text(verbatim: shortcut)
			.font(.system(size: 12, weight: .semibold).monospacedDigit())
			.lineLimit(1)
			.foregroundStyle(BrowserTheme.text.opacity(hovered ? 0.9 : 0.62))
			.padding(.horizontal, 8)
			.frame(minWidth: height + 8, minHeight: height, maxHeight: height)
			.background(.black.opacity(hovered ? 0.28 : 0.06), in: shape)
			.contentShape(shape)
			.animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovered)
			.onHover { hovered = $0 }
	}

	private var shape: RoundedRectangle {
		RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
	}
}

extension PagePictureInPictureSpacePicker.Option {
	/// The options for `spaces` in the switcher's order: each space's Switch to Space shortcut
	/// from `shortcuts`, or its number where it has none, and its profile's name where that isn't
	/// `profileID`.
	public static func options(
		spaces: some Sequence<Space>,
		profiles: some Sequence<Profile>,
		profileID: Profile.ID?,
		shortcuts: [ShortcutBinding]
	) -> [Self] {
		let names = Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
		return spaces.enumerated().map { index, space in
			let number = index + 1
			let shortcut = BrowserCommand.switchToSpace(number).flatMap { shortcuts.shortcut(for: $0) }
			return .init(
				id: space.id,
				name: space.name,
				shortcut: shortcut?.display ?? "\(number)",
				otherProfileName: space.profileID == profileID ? nil : names[space.profileID]
			)
		}
	}
}
