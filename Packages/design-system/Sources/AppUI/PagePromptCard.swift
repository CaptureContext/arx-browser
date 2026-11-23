import BrowserCore
import SwiftUI

/// Arx's prompt for a site permission a page asks for (DEV-963), in the family of the app link
/// prompt (`AppLinkPromptCard`, DEV-872): portrait, with the site's icon carrying the
/// permission's symbol, a plain name line such as "github.com wants to show notifications",
/// the site that embeds it when that's another one, the caller's details (location accuracy,
/// Chromium's wording for a permission Arx doesn't name), then full-width buttons with the
/// primary one last.
public struct PagePromptCard<Icon: View, Details: View, Actions: View>: View {
	/// The app link prompt's width, so the family lines up.
	public static var width: CGFloat { AppLinkPromptCard<EmptyView, EmptyView>.width }

	private let icon: Icon
	private let symbols: [String]
	private let title: String
	private let embedder: String?
	private let details: Details
	private let actions: Actions

	/// `symbols` badge the icon, one per permission, such as a camera and a microphone.
	public init(
		symbols: [String],
		title: String,
		embedder: String?,
		@ViewBuilder icon: () -> Icon,
		@ViewBuilder details: () -> Details,
		@ViewBuilder actions: () -> Actions
	) {
		self.icon = icon()
		self.symbols = symbols
		self.title = title
		self.embedder = embedder
		self.details = details()
		self.actions = actions()
	}

	public var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 10) {
				badgedIcon
					.padding(.bottom, 4)
				Text(title)
					.font(.system(size: 17, weight: .semibold))
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
					.accessibilityAddTraits(.isHeader)
				if let embedder {
					Text(embedder)
						.font(.callout)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: .infinity)
			.padding(.bottom, 16)

			VStack(alignment: .leading, spacing: 10) {
				details
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			Spacer(minLength: 18)

			VStack(spacing: ArxModalMetrics.buttonSpacing) {
				actions
			}
			.frame(maxWidth: .infinity)
		}
		.padding(ArxModalMetrics.contentPadding)
		.frame(width: Self.width)
	}

	/// The site's icon with the permissions' symbols on its lower edge.
	private var badgedIcon: some View {
		icon
			.frame(width: 56, height: 56)
			.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			.overlay(alignment: .bottomTrailing) {
				HStack(spacing: -6) {
					ForEach(symbols, id: \.self) { symbol in
						PagePromptSymbolBadge(symbol: symbol)
					}
				}
				.offset(x: 10, y: 8)
			}
			.padding(.trailing, 10)
			.accessibilityHidden(true)
	}
}

/// One permission's symbol in a filled circle, outlined by the window's background so it reads
/// over any site icon.
public struct PagePromptSymbolBadge: View {
	private let symbol: String

	public init(symbol: String) {
		self.symbol = symbol
	}

	public var body: some View {
		Image(systemName: symbol)
			.font(.system(size: 12, weight: .semibold))
			.foregroundStyle(.white)
			.frame(width: 26, height: 26)
			.background(Color.accentColor, in: Circle())
			.overlay(Circle().strokeBorder(ArxModalMetrics.background, lineWidth: 2.5))
	}
}

/// What the page prompt shows for each permission.
public enum PagePromptPresentation {
	/// The permission's symbol, as the site menu shows it.
	public static func symbol(_ permission: SitePermission) -> String {
		SiteMenuPanel.symbol(permission)
	}

	/// "github.com wants to show notifications", with camera and microphone asked together in
	/// one line. `site` is the requesting site as the person knows it.
	public static func title(
		site: String,
		permissions: [SitePermission]
	) -> String {
		let asked = Set(permissions)
		if asked == [.camera, .microphone] {
			return String.localized(.appUI.pagePrompts.wantsCameraAndMicrophone(site))
		}
		guard asked.count == 1, let permission = asked.first else {
			return String.localized(.appUI.pagePrompts.wantsPermissions(site))
		}
		return switch permission {
		case .notifications: String.localized(.appUI.pagePrompts.wantsNotifications(site))
		case .camera: String.localized(.appUI.pagePrompts.wantsCamera(site))
		case .microphone: String.localized(.appUI.pagePrompts.wantsMicrophone(site))
		case .location: String.localized(.appUI.pagePrompts.wantsLocation(site))
		case .clipboard: String.localized(.appUI.pagePrompts.wantsClipboard(site))
		case .popups: String.localized(.appUI.pagePrompts.wantsPermissions(site))
		}
	}

	/// "Embedded in example.com", for a request from a frame of another site.
	public static func embedder(_ site: String) -> String {
		String.localized(.appUI.pagePrompts.embeddedIn(site))
	}
}

/// A site permission prompt with its buttons (DEV-963), for the app to wire to a request.
///
/// Cancel, Block, Allow Once where it applies, then the main button last: Allow, or Always
/// Allow beside Allow Once. Return presses the main button once `isArmed`, as the app link
/// prompt does; Esc is Cancel, which dismisses and never blocks. Location asks show the accuracy
/// to share when the request offers a choice.
public struct PagePermissionPromptCard<Icon: View>: View {
	public enum Accuracy: Hashable, Sendable {
		case approximate
		case precise
	}

	private let site: String
	private let embedder: String?
	private let permissions: [SitePermission]
	private let otherRequests: [String]
	private let offersAllowOnce: Bool
	private let accuracies: [Accuracy]
	private let accuracy: Binding<Accuracy>
	private let isArmed: Bool
	private let icon: Icon
	private let onCancel: () -> Void
	private let onBlock: () -> Void
	private let onAllowOnce: () -> Void
	private let onAllow: () -> Void

	/// `otherRequests` is Chromium's wording for asks Arx has no name for, one per line.
	/// `accuracies` lists the location accuracies the person may pick; just one is said, since
	/// Allow shares exactly that, and none says nothing.
	public init(
		site: String,
		embedder: String?,
		permissions: [SitePermission],
		otherRequests: [String] = [],
		offersAllowOnce: Bool,
		accuracies: [Accuracy] = [],
		accuracy: Binding<Accuracy> = .constant(.approximate),
		isArmed: Bool,
		@ViewBuilder icon: () -> Icon,
		onCancel: @escaping () -> Void,
		onBlock: @escaping () -> Void,
		onAllowOnce: @escaping () -> Void,
		onAllow: @escaping () -> Void
	) {
		self.site = site
		self.embedder = embedder
		self.permissions = permissions
		self.otherRequests = otherRequests
		self.offersAllowOnce = offersAllowOnce
		self.accuracies = accuracies
		self.accuracy = accuracy
		self.isArmed = isArmed
		self.icon = icon()
		self.onCancel = onCancel
		self.onBlock = onBlock
		self.onAllowOnce = onAllowOnce
		self.onAllow = onAllow
	}

	public var body: some View {
		PagePromptCard(
			symbols: symbols,
			title: PagePromptPresentation.title(site: site, permissions: permissions),
			embedder: embedder.map(PagePromptPresentation.embedder),
			icon: { icon },
			details: { details },
			actions: { actions }
		)
	}

	/// The named permissions' symbols, or a generic one for asks Arx has no name for.
	private var symbols: [String] {
		let named = permissions.map(PagePromptPresentation.symbol)
		return named.isEmpty ? ["hand.raised"] : named
	}

	@ViewBuilder
	private var details: some View {
		if !otherRequests.isEmpty {
			VStack(alignment: .leading, spacing: 4) {
				ForEach(otherRequests, id: \.self) { request in
					Label(request, systemImage: "checkmark.shield")
				}
			}
			.foregroundStyle(.secondary)
		}
		if accuracies.count > 1 {
			Picker(String.localized(.appUI.pagePrompts.locationAccuracy), selection: accuracy) {
				ForEach(accuracies, id: \.self) { accuracy in
					Text(Self.title(accuracy)).tag(accuracy)
				}
			}
			.pickerStyle(.segmented)
		} else if let fixed = accuracies.first {
			Label(Self.fixedTitle(fixed), systemImage: "location")
				.foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private var actions: some View {
		AppLinkPromptButton(String.localized(.appUI.pagePrompts.cancel), keyHint: .escape, action: onCancel)
			.keyboardShortcut(.cancelAction)
		AppLinkPromptButton(String.localized(.appUI.pagePrompts.block), action: onBlock)
			.disabled(!isArmed)
		if offersAllowOnce {
			AppLinkPromptButton(String.localized(.appUI.pagePrompts.allowOnce), action: onAllowOnce)
				.disabled(!isArmed)
		}
		AppLinkPromptButton(
			String.localized(offersAllowOnce ? .appUI.pagePrompts.alwaysAllow : .appUI.pagePrompts.allow),
			prominence: .primary,
			keyHint: .return,
			action: onAllow
		)
		.keyboardShortcut(.defaultAction)
		.disabled(!isArmed)
	}

	private static func fixedTitle(_ accuracy: Accuracy) -> String {
		switch accuracy {
		case .approximate: String.localized(.appUI.pagePrompts.sharesApproximateLocation)
		case .precise: String.localized(.appUI.pagePrompts.sharesPreciseLocation)
		}
	}

	private static func title(_ accuracy: Accuracy) -> String {
		switch accuracy {
		case .approximate: String.localized(.appUI.pagePrompts.approximateLocation)
		case .precise: String.localized(.appUI.pagePrompts.preciseLocation)
		}
	}
}
