import SwiftUI

/// Where a window's pop-ups at the bottom go (DEV-1260): centred on the page area beside the
/// sidebar, whichever side it's on, expanded or hidden, a toast's inset above the page's bottom
/// edge. They follow the page while the sidebar is resized or toggled.
///
/// The window's main view marks its page area with ``SwiftUI/View/pagePopupArea()``; the window
/// draws its pop-ups with ``SwiftUI/View/pagePopups(_:)`` around that view:
///
/// ```swift
/// MainView(…)
///     .pagePopups {
///         PasswordSaveView(…)
///         WorkspaceRecoveryView(…)
///     }
/// ```
///
/// Pop-ups stack from the bottom up in the order given, ``PagePopupMetrics/spacing`` apart. Draw
/// each on ``PagePopupCard`` so they look alike. Without a marked page area they centre on the
/// whole view.
public enum PagePopupMetrics {
	/// Between a pop-up and the page's bottom edge: a toast's inset from the edges it's placed
	/// against.
	public static let bottomInset: CGFloat = ArxToastMetrics.edgeInset

	/// The least room between a pop-up and the page's sides, in a narrow window.
	public static let sideInset: CGFloat = ArxToastMetrics.edgeInset

	/// Between stacked pop-ups.
	public static let spacing: CGFloat = ArxToastMetrics.stackSpacing

	/// A pop-up's width: the app link prompt's, so the prompts line up as a family (DEV-1233).
	public static var width: CGFloat { AppLinkPromptCard<EmptyView, EmptyView>.width }

	/// The area pop-ups are centred in: the page's frame, clipped to the view drawing them, or
	/// the whole view when no page is marked or the page is off it.
	public static func area(
		page: CGRect?,
		in bounds: CGRect
	) -> CGRect {
		guard let page else { return bounds }

		let area: CGRect = page.intersection(bounds)
		return area.isNull || area.isEmpty ? bounds : area
	}

	/// The frame of a pop-up `size` big at the bottom of `area`: centred, ``bottomInset`` above
	/// its bottom edge, and no wider than the area less ``sideInset`` on each side.
	public static func frame(
		size: CGSize,
		in area: CGRect
	) -> CGRect {
		let width: CGFloat = max(min(size.width, area.width - 2 * sideInset), 0)
		return CGRect(
			x: area.midX - width / 2,
			y: area.maxY - bottomInset - size.height,
			width: width,
			height: size.height
		)
	}
}

/// The page area a window's pop-ups centre on, as an anchor in the view that marked it.
public struct PagePopupAreaKey: PreferenceKey {
	public static let defaultValue: Anchor<CGRect>? = nil

	public static func reduce(
		value: inout Anchor<CGRect>?,
		nextValue: () -> Anchor<CGRect>?
	) {
		value = value ?? nextValue()
	}
}

extension View {
	/// Marks this view as the page area the window's ``pagePopups(_:)`` centre on (DEV-1260).
	public func pagePopupArea() -> some View {
		anchorPreference(key: PagePopupAreaKey.self, value: .bounds) { $0 }
	}

	/// Draws `popups` at the bottom of the page area marked inside this view with
	/// ``pagePopupArea()``, centred on it, stacked from the bottom up (DEV-1260).
	public func pagePopups<Popups: View>(
		@ViewBuilder _ popups: () -> Popups
	) -> some View {
		modifier(PagePopupPlacement(popups: popups()))
	}
}

private struct PagePopupPlacement<Popups: View>: ViewModifier {
	internal let popups: Popups

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion: Bool

	internal func body(content: Content) -> some View {
		content.overlayPreferenceValue(PagePopupAreaKey.self) { anchor in
			GeometryReader { proxy in
				let area: CGRect = PagePopupMetrics.area(
					page: anchor.map { proxy[$0] },
					in: CGRect(origin: .zero, size: proxy.size)
				)
				VStack(spacing: PagePopupMetrics.spacing) {
					popups
				}
				.frame(maxWidth: max(area.width - 2 * PagePopupMetrics.sideInset, 0))
				.frame(
					width: area.width,
					height: max(area.height - PagePopupMetrics.bottomInset, 0),
					alignment: .bottom
				)
				.offset(x: area.minX, y: area.minY)
				.animation(reduceMotion ? nil : .snappy(duration: 0.28), value: area)
			}

			// Measured from the view's own edges, as toasts are (DEV-823): a browser window's
			// content runs under its title bar.
			.ignoresSafeArea()
		}
	}
}

/// A pop-up at the bottom of the page (DEV-1233), in the family of the app link prompt
/// (``AppLinkPromptCard``, DEV-872): the prompt's width, padding, type and full-width buttons
/// with the primary one last, on a floating card of the modal background.
///
/// ```swift
/// PagePopupCard(symbol: "key.fill", title: "Save password for example.com?", detail: "max") {
///     Text("Saved only in this profile.")
/// } actions: {
///     AppLinkPromptButton("Never") { … }
///     AppLinkPromptButton("Save", prominence: .primary, keyHint: .return) { … }
///         .keyboardShortcut(.defaultAction)
/// }
/// ```
public struct PagePopupCard<Details: View, Actions: View>: View {
	private let symbol: String?
	private let title: String
	private let detail: String?
	private let details: Details
	private let actions: Actions

	public init(
		symbol: String? = nil,
		title: String,
		detail: String? = nil,
		@ViewBuilder details: () -> Details,
		@ViewBuilder actions: () -> Actions
	) {
		self.symbol = symbol
		self.title = title
		self.detail = detail
		self.details = details()
		self.actions = actions()
	}

	public var body: some View {
		VStack(spacing: 0) {
			VStack(spacing: 10) {
				if let symbol {
					Image(systemName: symbol)
						.font(.system(size: 28, weight: .regular))
						.foregroundStyle(.secondary)
						.frame(width: 44, height: 44)
						.accessibilityHidden(true)
				}
				Text(title)
					.font(.system(size: 17, weight: .semibold))
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
					.textSelection(.enabled)
					.accessibilityAddTraits(.isHeader)
				if let detail {
					Text(detail)
						.font(.callout)
						.foregroundStyle(.secondary)
						.multilineTextAlignment(.center)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: .infinity)
			.padding(.bottom, 14)

			VStack(alignment: .leading, spacing: 10) {
				details
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.bottom, 18)

			VStack(spacing: ArxModalMetrics.buttonSpacing) {
				actions
			}
			.frame(maxWidth: .infinity)
		}
		.padding(PagePopupCardMetrics.padding)
		.frame(maxWidth: PagePopupMetrics.width)
		.pagePopupSurface()
	}
}

extension View {
	/// Draws the view on a page pop-up's floating card (DEV-1233): the modal background, a
	/// hairline edge and a shadow, as ``PagePopupCard`` is. For a pop-up that lays out its own
	/// content, such as an agent's approval; pad the content yourself.
	public func pagePopupSurface() -> some View {
		let shape: RoundedRectangle = .init(cornerRadius: PagePopupCardMetrics.cornerRadius, style: .continuous)
		return self
			.background(ArxModalMetrics.background, in: shape)
			.overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
			.browserShadow(PagePopupCardMetrics.shadow)
			.accessibilityElement(children: .contain)
	}
}

extension PagePopupCard where Details == EmptyView {
	public init(
		symbol: String? = nil,
		title: String,
		detail: String? = nil,
		@ViewBuilder actions: () -> Actions
	) {
		self.init(symbol: symbol, title: title, detail: detail, details: { EmptyView() }, actions: actions)
	}
}

internal enum PagePopupCardMetrics {
	/// A little tighter than a sheet's ``ArxModalMetrics/contentPadding``: it floats over a page.
	internal static let padding: CGFloat = 20
	internal static let cornerRadius: CGFloat = 16
	internal static let shadow: BrowserShadow = .init(opacity: 0.2, radius: 16, y: 6)
}
