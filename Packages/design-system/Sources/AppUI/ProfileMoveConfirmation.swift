import SwiftUI

/// What Arx asks before a tab moves to a space of another profile (DEV-1184): what moves where,
/// and plainly what happens. The page reloads in the other profile, and its sign-ins stay with the
/// profile it leaves. Cancel answers Escape, Move answers Return.
///
/// A window shows it as a sheet (`profileMoveConfirmationSheet`); Page PiP, a borderless floating
/// window, lays it over its page (`profileMoveConfirmationOverlay`).
public struct ProfileMoveConfirmation: View {
	/// What the question is about.
	public struct Content: Equatable, Sendable {
		/// What moves.
		public enum Subject: Equatable, Sendable {
			/// One tab.
			case tab

			/// Several tabs, or a folder's.
			case tabs(Int)

			/// A whole space, named, which keeps its name in the other profile.
			case space(String)
		}

		public var subject: Subject

		/// The space it moves to.
		public var spaceName: String

		/// The profile that space belongs to.
		public var profileName: String

		public init(
			subject: Subject,
			spaceName: String,
			profileName: String
		) {
			self.subject = subject
			self.spaceName = spaceName
			self.profileName = profileName
		}

		/// The question, naming the space, or the profile for a whole space.
		public var title: String {
			switch subject {
			case .tab: String.localized(.appUI.profileMove.tabTitle(spaceName))
			case let .tabs(count): String.localized(.appUI.profileMove.tabsTitle(count, spaceName))
			case let .space(name): String.localized(.appUI.profileMove.spaceTitle(name, profileName))
			}
		}

		/// What happens: the pages reload in the other profile without their sign-ins.
		public var detail: String {
			switch subject {
			case .tab: String.localized(.appUI.profileMove.tabDetail(profileName))
			case .tabs, .space: String.localized(.appUI.profileMove.tabsDetail(profileName))
			}
		}
	}

	/// The card's widest; a narrow window, such as Page PiP's narrowest, gives it less.
	internal static let maximumWidth: CGFloat = 340

	private let content: Content
	private let onCancel: () -> Void
	private let onConfirm: () -> Void

	public init(
		_ content: Content,
		onCancel: @escaping () -> Void,
		onConfirm: @escaping () -> Void
	) {
		self.content = content
		self.onCancel = onCancel
		self.onConfirm = onConfirm
	}

	public var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			VStack(alignment: .leading, spacing: 6) {
				Text(content.title)
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(BrowserTheme.text)
				Text(content.detail)
					.font(.system(size: 13))
					.foregroundStyle(BrowserTheme.secondary)
			}
			.fixedSize(horizontal: false, vertical: true)
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer(minLength: 0)
				ArxModalButton.cancel(action: onCancel)
				ArxModalButton(String.localized(.appUI.profileMove.confirm), action: onConfirm)
			}
		}
		.padding(20)
		.frame(maxWidth: Self.maximumWidth, alignment: .leading)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(content.title)
	}
}

extension View {
	/// Asks before a move to another profile as a sheet on the window, while `content` is set.
	/// Escape, Cancel or the sheet's dismissal call `onCancel`.
	public func profileMoveConfirmationSheet(
		_ content: ProfileMoveConfirmation.Content?,
		onCancel: @escaping () -> Void,
		onConfirm: @escaping () -> Void
	) -> some View {
		sheet(isPresented: Binding(
			get: { content != nil },
			set: { if !$0 { onCancel() } }
		)) {
			if let content {
				ProfileMoveConfirmation(content, onCancel: onCancel, onConfirm: onConfirm)
					.frame(width: ProfileMoveConfirmation.maximumWidth)
					.arxModalSheet()
			}
		}
	}

	/// Asks before a move to another profile over the view, while `content` is set: the card in
	/// the middle over a dimmed view, for a borderless window such as Page PiP's, where a sheet
	/// has no title bar to hang from. It takes the keyboard from the page while it shows.
	public func profileMoveConfirmationOverlay(
		_ content: ProfileMoveConfirmation.Content?,
		onCancel: @escaping () -> Void,
		onConfirm: @escaping () -> Void
	) -> some View {
		overlay {
			if let content {
				ProfileMoveConfirmationOverlay(content: content, onCancel: onCancel, onConfirm: onConfirm)
			}
		}
	}
}

/// The confirmation laid over a borderless window: a dimmed backdrop that keeps clicks from the
/// page, and the card on the modal background, focused so Escape and Return reach it rather than
/// the page.
private struct ProfileMoveConfirmationOverlay: View {
	internal let content: ProfileMoveConfirmation.Content
	internal let onCancel: () -> Void
	internal let onConfirm: () -> Void

	@FocusState
	private var isFocused: Bool

	internal var body: some View {
		ZStack {
			Color.black.opacity(0.28)
				.contentShape(.rect)
				.onTapGesture(perform: onCancel)
				.accessibilityHidden(true)
			ProfileMoveConfirmation(content, onCancel: onCancel, onConfirm: onConfirm)
				.background(
					ArxModalMetrics.background,
					in: .rect(cornerRadius: BrowserMetrics.LittleArx.pageCornerRadius, style: .continuous)
				)
				.browserShadow(BrowserMetrics.FloatingSidebar.shadow)
				.padding(12)
				.focusable()
				.focusEffectDisabled()
				.focused($isFocused)
				.onKeyPress(.escape) {
					onCancel()
					return .handled
				}
				.onKeyPress(.return) {
					onConfirm()
					return .handled
				}
		}
		.onAppear { isFocused = true }
	}
}
