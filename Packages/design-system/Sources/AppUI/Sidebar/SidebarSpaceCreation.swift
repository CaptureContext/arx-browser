import AppKit
import BrowserCore
import SwiftUI

/// What the Create a Space page past the last space offers (DEV-1109): the profiles a new space
/// can use, and how the window makes one. A window that can't make spaces, such as a private one,
/// passes none, and the last space only rubber-bands.
public struct SidebarSpaceCreation {
	public struct Profile: Identifiable, Equatable, Sendable {
		public let id: UUID
		public var name: String

		/// The profile's own appearance, which the new space's theme starts from.
		public var appearance: AppearanceOverride?

		public init(
			id: UUID,
			name: String,
			appearance: AppearanceOverride? = nil
		) {
			self.id = id
			self.name = name
			self.appearance = appearance
		}
	}

	public static let featureFlag: String = FeatureFlag.swipeToCreateSpace.name

	/// Whether a swipe past the last space offers the page. Read once, through the `FeatureFlag`
	/// registry: the environment, then Arx's defaults under the flag's name; on unless it says
	/// `0`, `false`, `no` or `off`.
	public static let isEnabled: Bool = FeatureFlag.swipeToCreateSpace.isOn()

	/// What one value turns it to.
	internal static func isOn(read: (String) -> String?) -> Bool {
		read(featureFlag).flatMap(FeatureFlag.parse) ?? FeatureFlag.swipeToCreateSpace.isOnByDefault
	}

	public var profiles: [Profile]

	/// The app-wide appearance, which the profiles' own appearances apply over. Not the
	/// environment's, which already has the shown space's on it.
	public var global: ChromeAppearance

	/// Makes the space, after the others, with its name, profile and theme, and shows it.
	public var create: @MainActor (_ name: String, _ profileID: UUID, _ appearance: AppearanceOverride?) -> Void

	public init(
		profiles: [Profile],
		global: ChromeAppearance,
		create: @escaping @MainActor (_ name: String, _ profileID: UUID, _ appearance: AppearanceOverride?) -> Void
	) {
		self.profiles = profiles
		self.global = global
		self.create = create
	}
}

/// The Create a Space page, one page after the last space: a name, the profile, which starts as
/// the last space's, and a theme over the profile's. Return creates once there's a name, and Esc,
/// like Cancel, goes back to the last space. Its draft goes with the page when it closes.
internal struct SidebarSpaceCreationPage: View {
	private let creation: SidebarSpaceCreation
	private let onCreate: () -> Void
	private let onCancel: () -> Void

	@SwiftUI.State
	private var name: String

	@SwiftUI.State
	private var profileID: UUID

	@SwiftUI.State
	private var appearance: AppearanceOverride?

	@SwiftUI.State
	private var isChoosingTheme: Bool

	/// Clicking Theme while its panel is open first closes the panel, and that same click must not reopen it.
	@SwiftUI.State
	private var themeClosedAt: Date

	@FocusState
	private var isNameFocused: Bool

	internal init(
		creation: SidebarSpaceCreation,
		profileID: UUID?,
		onCreate: @escaping () -> Void = {},
		onCancel: @escaping () -> Void
	) {
		self.creation = creation
		self.onCreate = onCreate
		self.onCancel = onCancel
		let initial: UUID = profileID.flatMap { id in creation.profiles.first { $0.id == id }?.id }
		?? creation.profiles.first?.id
		?? UUID()
		self._name = .init(initialValue: "")
		self._profileID = .init(initialValue: initial)
		self._appearance = .init(initialValue: nil)
		self._isChoosingTheme = .init(initialValue: false)
		self._themeClosedAt = .init(initialValue: .distantPast)
	}

	internal var body: some View {
		VStack(spacing: 0) {
			heading
				.padding(.top, Self.topPadding)
				.padding(.bottom, Self.headingSpacing)
			fields
			Spacer(minLength: Self.headingSpacing)
			actions
				.padding(.bottom, Self.bottomPadding)
		}
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onExitCommand(perform: onCancel)

		// Return creates from anywhere in the page, not only the name field; focus outside the
		// sidebar, such as in the web page, keeps its own Return.
		.onKeyPress(.return) {
			guard !trimmedName.isEmpty else { return .ignored }
			create()
			return .handled
		}
		.onAppear { isNameFocused = true }
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.sidebar.createSpace.title))
	}

	private static let topPadding: CGFloat = 28
	private static let headingSpacing: CGFloat = 18
	private static let bottomPadding: CGFloat = 12
	private static let fieldSpacing: CGFloat = 6

	private var heading: some View {
		VStack(spacing: 6) {
			Image(systemName: "square.stack.3d.up.fill")
				.font(.system(size: 28, weight: .regular))
				.foregroundStyle(.secondary)
				.padding(.bottom, 4)
				.accessibilityHidden(true)
			Text(localized: .appUI.sidebar.createSpace.title)
				.font(.headline)
				.accessibilityAddTraits(.isHeader)
			Text(localized: .appUI.sidebar.createSpace.detail)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var fields: some View {
		VStack(spacing: Self.fieldSpacing) {
			TextField(
				String.localized(.appUI.sidebar.createSpace.name),
				text: $name,
				prompt: Text(localized: .appUI.sidebar.createSpace.namePrompt)
			)
			.textFieldStyle(.arx(size: .large, systemImage: "plus"))
			.focused($isNameFocused)
			.onSubmit(create)

			HStack(spacing: 8) {
				Label(String.localized(.appUI.sidebar.createSpace.profile), systemImage: "person.crop.circle")
					.foregroundStyle(.secondary)
				Spacer(minLength: 0)
				ArxDropdown(
					String.localized(.appUI.sidebar.createSpace.profile),
					selection: Binding(get: { chosenProfileID }, set: { profileID = $0 }),
					options: creation.profiles.map { .init(id: $0.id, title: $0.name) }
				)
				.disabled(creation.profiles.count < 2)
			}
			.padding(.leading, 12)
			.padding(.trailing, 4)
			.padding(.vertical, 4)
			.background(.primary.opacity(0.05), in: ArxControlShape())

			Button {
				if Date.now.timeIntervalSince(themeClosedAt) > 0.3 { isChoosingTheme = true }
			} label: {
				HStack(spacing: 8) {
					Label(String.localized(.appUI.sidebar.createSpace.theme), systemImage: "paintbrush.pointed")
					Spacer(minLength: 0)
					if let appearance { AppearanceSwatch(appearance) }
				}
				.frame(maxWidth: .infinity)
			}
			.buttonStyle(.arx(.secondary, size: .large))
			.onChange(of: isChoosingTheme) { _, isOpen in
				if !isOpen { themeClosedAt = .now }
			}

			// Movable, so the person can see the sidebar it covers while choosing (DEV-1286).
			.movableFloatingPanel(isPresented: $isChoosingTheme, placement: .trailing) {
				SpaceThemeEditor(
					choices: appearance ?? .init(),
					inherited: inheritedAppearance,
					onCommit: { appearance = $0 },
					onClear: { appearance = nil }
				)
				.frame(width: SpaceThemeEditor.width)

				// The panel's handle sits above it, in place of most of the top padding.
				.padding([.horizontal, .bottom], 14)
				.padding(.top, 4)
			}
		}
	}

	private var actions: some View {
		VStack(spacing: Self.fieldSpacing) {
			Button(action: create) {
				ArxButtonLabel(String.localized(.appUI.sidebar.createSpace.create), keyHint: .return)
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.arx(.primary, size: .large))
			.disabled(trimmedName.isEmpty)

			Button(action: onCancel) {
				ArxButtonLabel(String.localized(.appUI.common.cancel), keyHint: .escape)
					.frame(maxWidth: .infinity)
			}
			.buttonStyle(.arx(.plain, size: .large))
		}
	}

	/// The draft's profile, or the first one left once it's removed while the page is open.
	private var chosenProfileID: UUID {
		creation.profiles.contains { $0.id == profileID } ? profileID : creation.profiles.first?.id ?? profileID
	}

	private var trimmedName: String {
		name.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// The chosen profile's appearance over the app-wide one, which the theme's choices start from.
	private var inheritedAppearance: ChromeAppearance {
		let profile = creation.profiles.first { $0.id == chosenProfileID }
		return (profile?.appearance ?? .init()).applied(to: creation.global)
	}

	private func create() {
		guard !trimmedName.isEmpty else { return }
		onCreate()
		creation.create(trimmedName, chosenProfileID, appearance)
	}
}

/// The round + at the sidebar's trailing edge while a swipe pulls past the last space: it grows
/// with the pull and fills with the accent once letting go would open Create a Space. With Reduce
/// Motion it only fades in. Reads the pull alone, so a frame of it rebuilds nothing else.
internal struct SidebarSpaceCreationBubble: View {
	private let driver: SidebarTrackDriver

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(driver: SidebarTrackDriver) {
		self.driver = driver
	}

	private static let size: CGFloat = 28
	private static let inset: CGFloat = 8
	private static let restingScale: CGFloat = 0.5

	internal var body: some View {
		let pull: CGFloat = driver.creationPull
		let progress: CGFloat = min(pull, 1)
		let isArmed: Bool = pull >= 1
		ZStack(alignment: .trailing) {
			// The edge glows a little as the pull gathers.
			// The accent is resolved from the environment (DEV-1117), so it fades through a mask.
			Rectangle()
				.fill(BrowserTheme.accent.opacity(0.25))
				.mask(LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing))
			.frame(width: Self.size * 1.5)
			.opacity(progress)

			Circle()
				.fill(isArmed ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(.regularMaterial))
				.overlay {
					Image(systemName: "plus")
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(isArmed ? AnyShapeStyle(BrowserTheme.onAccent) : AnyShapeStyle(.secondary))
				}
				.shadow(color: .black.opacity(0.15), radius: 3, y: 1)
				.frame(width: Self.size, height: Self.size)
				.scaleEffect(reduceMotion ? 1 : Self.restingScale + (1 - Self.restingScale) * progress)
				.opacity(progress)
				.padding(.trailing, Self.inset)
				.animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: isArmed)
		}
		.frame(maxHeight: .infinity)
		.allowsHitTesting(false)
		.accessibilityHidden(true)
	}
}

/// Holds the Create a Space page's place after the last space, and builds the page only while
/// it's open.
internal struct SidebarSpaceCreationSlot<Content: View>: View {
	private let driver: SidebarTrackDriver
	private let content: Content

	internal init(
		driver: SidebarTrackDriver,
		@ViewBuilder content: () -> Content
	) {
		self.driver = driver
		self.content = content()
	}

	internal var body: some View {
		if driver.isCreationOpen {
			content
		} else {
			Color.clear
		}
	}
}
