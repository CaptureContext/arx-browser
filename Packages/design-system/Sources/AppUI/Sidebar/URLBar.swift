import BrowserCore
import SwiftUI

public struct URLBar: View {
	private let url: URL?
	private let height: CGFloat
	private let centersAddress: Bool
	private let prominentActions: Bool
	private let isLoading: Bool
	private let leading: AnyView?

	/// `nil` shows the address without opening it for editing, as Page PiP does (DEV-1105).
	private let onActivate: (() -> Void)?
	private let onCopy: () -> Void

	@Environment(\.showsFullURL)
	private var showsFullURL

	@Environment(\.siteMenu)
	private var siteMenu

	/// Translation Available and its popover (DEV-996); nil leaves the bar one line.
	@Environment(\.pageTranslationOffer)
	private var translation

	@Environment(\.readingModeIndicator)
	private var readingMode

	@Environment(\.urlBarReservesPageButton)
	private var reservesPageButton

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@Environment(\.colorSchemeContrast)
	private var contrast

	@SwiftUI.State
	private var hovered: Bool

	@SwiftUI.State
	private var showsDetails: Bool

	@SwiftUI.State
	private var isShowingCopied: Bool

	@SwiftUI.State
	private var copyConfirmations: Int

	@SwiftUI.State
	private var showsTranslation: Bool

	/// The bar's part that has keyboard focus.
	@FocusState
	private var focusedPart: Part?

	@Environment(\.arxControlStateOverride)
	private var stateOverride

	public init(
		url: URL?,
		height: CGFloat = BrowserMetrics.URLBar.height,
		centersAddress: Bool = false,
		prominentActions: Bool = false,
		isLoading: Bool = false,
		leading: AnyView? = nil,
		onActivate: (() -> Void)?,
		onCopy: @escaping () -> Void
	) {
		self.url = url
		self.height = height
		self.centersAddress = centersAddress
		self.prominentActions = prominentActions
		self.isLoading = isLoading
		self.leading = leading
		self.onActivate = onActivate
		self.onCopy = onCopy
		self._hovered = .init(initialValue: false)
		self._showsDetails = .init(initialValue: false)
		self._isShowingCopied = .init(initialValue: false)
		self._copyConfirmations = .init(initialValue: 0)
		self._showsTranslation = .init(initialValue: false)
	}

	public var body: some View {
		let _ = RenderTrace.body("URLBar.body")
		HStack(spacing: 4) {
			if let leading { leading }
			VStack(alignment: .leading, spacing: 0) {
				addressControl

				// a second line: Translation Available, Translating… or Translated (DEV-996).
				if url != nil, let translation, let offer = translation.offer {
					translationLine(offer, send: translation.send)
				}
			}

			// The actions show whenever a page is shown, hovered or not, and go with it (DEV-995).
			// Little Arx: site information first, then the link.
			if Self.showsActions(hasPage: url != nil) {
				HStack(spacing: actionSpacing) {
					// Reading mode, when the page has an article to show (DEV-1028), or its room
					// while the next page settles (DEV-1254).
					if let readingMode {
						readingModeButton(readingMode)
					} else if reservesPageButton {
						Color.clear.frame(width: actionSize, height: actionSize)
					}
					if prominentActions {
						siteInformationButton
						copyButton
					} else {
						copyButton
						siteInformationButton
					}
				}
			}
		}
		.font(.system(size: BrowserMetrics.URLBar.fontSize, weight: .medium))
		.foregroundStyle(BrowserTheme.text.opacity(
			BrowserMetrics.State.opacity(url == nil ? 0.55 : 0.85, contrast: contrast)
		))

		// A picker at the start sits as far from it as from the top and bottom.
		.padding(.leading, leading == nil ? BrowserMetrics.URLBar.horizontalPadding : BrowserMetrics.URLBar.accessoryInset)
		.padding(.trailing, trailingPadding)
		.frame(height: height)

		// The flat surface the Favorites share, rather than glass.
		.modifier(SidebarControlSurface(
			fill: SidebarControlFill.tint(hovered: isHovered),
			shape: RoundedRectangle(
				cornerRadius: BrowserMetrics.URLBar.cornerRadius(forHeight: height),
				style: .continuous
			)
		))
		.animation(.easeOut(duration: 0.12), value: isHovered)
		.anchorPreference(key: CommandBarAnchorsKey.self, value: .bounds) { .init(url: $0) }
		.onHover { hovered = $0 }
		.contextMenu { if url != nil { BrowserLinkMenu() } }
		.task(id: copyConfirmations) {
			guard copyConfirmations > 0 else { return }
			isShowingCopied = true
			do {
				try await Task.sleep(for: BrowserMetrics.URLBar.copiedDuration)
			} catch {
				return
			}
			isShowingCopied = false
		}
	}

	/// The address opens for editing, or only shows where nothing edits it, as in Page PiP (DEV-1105).
	@ViewBuilder
	private var addressControl: some View {
		if let onActivate {
			Button(action: onActivate) { addressLabel }
				.buttonStyle(.plain)
				.focused($focusedPart, equals: .address)
				.accessibilityLabel(String.localized(.appUI.url.searchAccessibility))

				// The label names the control; the value is the page it's showing.
				.accessibilityValue(address ?? "")

				// VoiceOver also reaches the actions from the address.
				.accessibilityActions { addressAccessibilityActions }
				.help(String.localized(.appUI.url.searchHelp))
		} else {
			addressLabel
				.accessibilityElement(children: .ignore)
				.accessibilityLabel(address ?? "")
				.accessibilityActions { addressAccessibilityActions }
		}
	}

	private func translationLine(
		_ offer: PageTranslationOffer,
		send: @escaping @MainActor @Sendable (PageTranslationOfferAction) -> Void
	) -> some View {
		Button { showsTranslation.toggle() } label: {
			Text(offer.line)
				.font(.system(size: BrowserMetrics.URLBar.secondLineFontSize, weight: .medium))
				.foregroundStyle(BrowserTheme.text.opacity(BrowserMetrics.State.opacity(0.55, contrast: contrast)))
				.lineLimit(1)
				.frame(maxWidth: .infinity, alignment: centersAddress ? .center : .leading)
				.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.help(offer.line)
		.accessibilityLabel(offer.line)
		.popover(isPresented: $showsTranslation, arrowEdge: .bottom) {
			PageTranslationPopover(offer: offer, send: send) { showsTranslation = false }
		}

		// The popover describes the page it opened over.
		.onChange(of: url) { showsTranslation = false }
	}

	private enum Part: Hashable {
		case address
		case copy
		case siteInformation
	}

	private var isHovered: Bool { stateOverride.isHovered ?? hovered }

	/// Whether the copy-link and site-menu buttons show: while a tab's page is shown, and never
	/// without one, such as in an empty space (DEV-995).
	internal static func showsActions(hasPage: Bool) -> Bool {
		hasPage
	}

	private var actionSymbolSize: CGFloat {
		switch (ChromeInlineButtons.isEnabled, prominentActions) {
		case (true, true): BrowserMetrics.URLBar.inlineProminentActionSymbolSize
		case (true, false): BrowserMetrics.URLBar.inlineActionSymbolSize
		case (false, true): BrowserMetrics.URLBar.prominentActionSymbolSize
		case (false, false): BrowserMetrics.URLBar.actionSymbolSize
		}
	}

	private var actionSymbolWeight: Font.Weight {
		ChromeInlineButtons.isEnabled
		? BrowserMetrics.URLBar.inlineActionSymbolWeight
		: BrowserMetrics.URLBar.actionSymbolWeight
	}

	/// The toolbar's color for its symbols with `ARX_INLINE_BUTTONS`, else the address's.
	private var actionSymbolStyle: AnyShapeStyle {
		ChromeInlineButtons.isEnabled ? AnyShapeStyle(BrowserTheme.secondary) : AnyShapeStyle(.foreground)
	}

	private var actionSpacing: CGFloat {
		ChromeInlineButtons.isEnabled ? BrowserMetrics.URLBar.inlineActionSpacing : 4
	}

	/// With `ARX_INLINE_BUTTONS`, the last button sits as far from the field's end as from its top
	/// and bottom, so its hovered shape does too (DEV-1252).
	private var trailingPadding: CGFloat {
		guard ChromeInlineButtons.isEnabled, Self.showsActions(hasPage: url != nil) else {
			return BrowserMetrics.URLBar.horizontalPadding - 4
		}
		return Self.actionEdgeInset(height: height, actionSize: actionSize)
	}

	/// The room above and below a button in a field of `height`.
	internal static func actionEdgeInset(
		height: CGFloat,
		actionSize: CGFloat
	) -> CGFloat {
		max((height - actionSize) / 2, 0)
	}

	private var actionSize: CGFloat {
		prominentActions ? BrowserMetrics.URLBar.prominentActionSize : BrowserMetrics.URLBar.actionSize
	}

	private var addressLabel: some View {
		HStack(spacing: 8) {
			if centersAddress { Spacer(minLength: 0) }
			if url == nil {
				Image(systemName: "magnifyingglass")
					.font(.system(size: 12, weight: .medium))
			}
			Text(address ?? String.localized(.appUI.url.search))
				.lineLimit(1)

				// A file's name is at the end of its path (DEV-987).
				.truncationMode(showsFullURL || url?.isFileURL == true ? .middle : .tail)
				.modifier(BrowserLoadingUnderline(isLoading: isLoading && url != nil))
			Spacer(minLength: 0)
		}
		.contentShape(.rect)
	}

	@ViewBuilder
	private var addressAccessibilityActions: some View {
		if url != nil {
			Button(String.localized(.appUI.url.copy), action: copy)
			Button(String.localized(.appUI.url.siteInformation)) { showsDetails = true }
		}
	}

	private var copyButton: some View {
		Button(action: copy) {
			ZStack {
				FigmaSymbol(.link, pointSize: actionSymbolSize).opacity(isShowingCopied ? 0 : 1)
				Image(systemName: "checkmark")
					.opacity(reduceMotion && !isShowingCopied ? 0 : 1)
					.symbolEffect(.drawOn, isActive: !reduceMotion && !isShowingCopied)
			}
			.font(.system(size: actionSymbolSize, weight: actionSymbolWeight))
			.foregroundStyle(actionSymbolStyle)
			.animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isShowingCopied)
			.frame(width: actionSize, height: actionSize)
		}
		.buttonStyle(ChromeInlineButtonStyle())
		.focused($focusedPart, equals: .copy)
		.help(String.localized(.appUI.url.copy))
		.accessibilityLabel(String.localized(.appUI.url.copy))
	}

	private func copy() {
		onCopy()
		copyConfirmations += 1
	}

	private func readingModeButton(_ indicator: ReadingModeIndicator) -> some View {
		Button { indicator.toggle() } label: {
			Image(systemName: indicator.symbol)
				.font(.system(size: actionSymbolSize, weight: actionSymbolWeight))
				.foregroundStyle(indicator.isReading ? AnyShapeStyle(BrowserTheme.accent) : actionSymbolStyle)
				.frame(width: actionSize, height: actionSize)
		}
		.buttonStyle(ChromeInlineButtonStyle())
		.help(indicator.title)
		.accessibilityLabel(indicator.title)
		.accessibilityAddTraits(indicator.isReading ? .isSelected : [])
	}

	private var address: String? {
		url.flatMap { Self.displayAddress(for: $0, showsFullURL: showsFullURL) }
	}

	/// The host, or with Show Full URL on, the whole address. A diagnostic page always shows its
	/// `arx://` address (DEV-898); a local file shows its path, `~` for the home folder (DEV-987).
	/// Nil shows the field's placeholder.
	internal static func displayAddress(
		for url: URL,
		showsFullURL: Bool
	) -> String? {
		if let diagnostic = DiagnosticPage.displayAddress(for: url) { return diagnostic }
		if showsFullURL { return url.absoluteString }
		return url.localFileDisplayPath ?? url.host()
	}

	private var siteInformationButton: some View {
		Button { showsDetails.toggle() } label: {
			FigmaSymbol(.siteMenu, pointSize: actionSymbolSize)
				.font(.system(size: actionSymbolSize, weight: actionSymbolWeight))
				.foregroundStyle(actionSymbolStyle)
				.frame(width: actionSize, height: actionSize)
		}
		.buttonStyle(ChromeInlineButtonStyle())
		.focused($focusedPart, equals: .siteInformation)
		.help(String.localized(.appUI.url.siteInformation))
		.accessibilityLabel(String.localized(.appUI.url.siteInformation))
		.popover(isPresented: $showsDetails, arrowEdge: .bottom) {
			if let siteMenu {
				siteMenuContent(siteMenu)
			} else {
				addressDetails
			}
		}

		// The menu describes the page it opened over.
		.onChange(of: url) { showsDetails = false }
		.onChange(of: showsDetails) { _, isShown in
			siteMenu?.send(isShown ? .opened : .closed)
		}
	}

	@ViewBuilder
	private func siteMenuContent(_ source: SiteMenuSource) -> some View {
		if let menu = source.menu {
			SiteMenuPanel(menu: menu, send: source.send) { showsDetails = false }
		} else {
			ProgressView()
				.controlSize(.small)
				.padding(18)
				.frame(width: SiteMenuPanel.width)
		}
	}

	/// The page's address, where there's no site menu.
	private var addressDetails: some View {
		Group {
			let title: String = url?.scheme == "https"
			? .localized(.appUI.url.httpsAddress)
			: .localized(.appUI.url.pageAddress)

			VStack(alignment: .leading, spacing: 12) {
				Label(title, systemImage: "info.circle")
					.font(.headline)
				Text(url?.absoluteString ?? "")
					.font(.system(size: 12))
					.textSelection(.enabled)
				Button(String.localized(.appUI.url.copy), action: onCopy)
			}
			.padding(18)
			.frame(width: 260, alignment: .leading)
		}
		.popoverOpensWithoutFocus()
	}
}
