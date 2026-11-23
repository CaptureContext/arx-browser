import AppUI
import BrowserCore
import BrowserSurfaceClient
import Foundation
import SwiftUI
import _ComposableArchitecture

/// What a copy or share of links did, as a toast: "Copied Current URL" with a share button, and
/// Copy Original when the copied link isn't the original. It shows at the window's top-right
/// corner, or in split view at the top-right corner of the pane the links came from
/// (``pageLinkFeedbackNotice(store:windowID:)``), so it's clear which tab it reports on.
///
/// At the window's corner it also makes room for toasts drawn under it, such as the sidebar's
/// notice: below its own toast, or below a pane's toast that reaches into that corner.
internal struct LinkFeedbackToast: ViewModifier {
	internal let store: StoreOf<AppFeature>
	internal let windowID: UUID

	/// The page this toast is drawn on, or `nil` for the window's corner.
	internal let tabID: BrowserCore.Tab.ID?
	internal let topInset: CGFloat
	internal let trailingInset: CGFloat

	/// The toast's frame in the window's content, which the window's corner stacks below.
	@SwiftUI.State
	private var toastFrame: CGRect = .zero

	/// At the window's corner: the frame of a pane's link toast, reported up as a preference.
	@SwiftUI.State
	private var paneToastFrame: CGRect?

	/// At the window's corner: the content's width, to tell whether a pane's toast reaches into
	/// the corner.
	@SwiftUI.State
	private var contentWidth: CGFloat = 0

	internal init(
		store: StoreOf<AppFeature>,
		windowID: UUID,
		tabID: BrowserCore.Tab.ID? = nil,
		topInset: CGFloat,
		trailingInset: CGFloat
	) {
		self.store = store
		self.windowID = windowID
		self.tabID = tabID
		self.topInset = topInset
		self.trailingInset = trailingInset
	}

	internal func body(content: Content) -> some View {
		let feedback: LinkActionFeedback? = store.linkActionFeedback.flatMap { feedback in
			feedback.windowID == windowID
				&& feedback.isShown
				&& store.state.linkFeedbackTabID(feedback) == tabID
			? feedback
			: nil
		}
		let isWindowCorner: Bool = tabID == nil
		content
			.environment(\.arxToastStackOffset, isWindowCorner ? stackOffset(isShown: feedback != nil) : 0)
			.onPreferenceChange(PaneLinkToastFrameKey.self) { frame in
				if isWindowCorner { paneToastFrame = frame }
			}
			.onGeometryChange(for: CGFloat.self, of: \.size.width) { width in
				if isWindowCorner { contentWidth = width }
			}
			.arxToast(
				isPresented: feedback != nil,
				topInset: topInset,
				trailingInset: trailingInset,
				onHover: { store.send(.ui(.linkFeedbackHovered($0))) }
			) {
				if let feedback {
					LinkFeedbackView(
						feedback: feedback,
						rules: store.settings.proxyLinkRules,
						send: { store.send($0) }
					)
					.onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.windowSpace)) }) {
						toastFrame = $0
					}
					.preference(key: PaneLinkToastFrameKey.self, value: isWindowCorner ? nil : toastFrame)

					// Again for each copy, so Copy Original's own toast gets its full time.
					.task(id: store.linkActionGeneration) { store.send(.ui(.linkFeedbackShown)) }
				}
			}

			// The window's corner places toasts in this space; pages report their toast in it.
			.coordinateSpace(.named(isWindowCorner ? Self.windowSpace : Self.pageSpace))
	}

	/// How far toasts under the window's corner move down: below this toast while it shows, or
	/// below a pane's toast that reaches into the corner where they'd show.
	private func stackOffset(isShown: Bool) -> CGFloat {
		Self.cornerStackOffset(
			ownToast: isShown ? toastFrame : nil,
			paneToast: paneToastFrame,
			contentWidth: contentWidth,
			topInset: topInset,
			trailingInset: trailingInset
		)
	}

	/// The stack offset at a window's corner placed `topInset` and `trailingInset` in from the
	/// top-right of content `contentWidth` wide, for the corner's own toast or a pane's toast,
	/// both framed in that content. A pane's toast counts only where a toast at the corner, up
	/// to ``ArxToastMetrics/maximumWidth`` wide and two lines tall, would meet it.
	internal static func cornerStackOffset(
		ownToast: CGRect?,
		paneToast: CGRect?,
		contentWidth: CGFloat,
		topInset: CGFloat,
		trailingInset: CGFloat
	) -> CGFloat {
		if let ownToast { return ArxToastMetrics.stackOffset(below: ownToast.height) }

		guard
			let pane = paneToast,
			pane.maxX > contentWidth - trailingInset - ArxToastMetrics.maximumWidth,
			pane.minY < topInset + 2 * ArxToastMetrics.minimumHeight
		else { return 0 }

		return max(pane.maxY + ArxToastMetrics.stackSpacing - topInset, 0)
	}

	internal nonisolated static let windowSpace: String = "LinkFeedbackToast.window"

	/// A page's own space, so a page never hides the window's from its toast.
	private static let pageSpace: String = "LinkFeedbackToast.page"
}

/// The frame of a pane's link toast in the window's content, for the window's corner.
private struct PaneLinkToastFrameKey: PreferenceKey {
	internal static let defaultValue: CGRect? = nil

	internal static func reduce(
		value: inout CGRect?,
		nextValue: () -> CGRect?
	) {
		value = nextValue() ?? value
	}
}

/// Draws the link toast on the page of the split view pane it reports on.
@MainActor
internal func pageLinkFeedbackNotice(
	store: StoreOf<AppFeature>,
	windowID: UUID
) -> BrowserPageOverlay {
	.init { tabID in
		AnyView(
			Color.clear
				.allowsHitTesting(false)
				.modifier(LinkFeedbackToast(
					store: store,
					windowID: windowID,
					tabID: tabID,
					topInset: ArxToastMetrics.edgeInset,
					trailingInset: ArxToastMetrics.edgeInset
				))

				// The window's corner moves its own toasts; a page's toast keeps to its corner.
				.environment(\.arxToastStackOffset, 0)
		)
	}
}

internal struct LinkFeedbackView: View {
	internal let feedback: LinkActionFeedback
	internal let rules: [ProxyLinkRule]
	internal let send: (AppFeature.Action) -> Void

	internal init(
		feedback: LinkActionFeedback,
		rules: [ProxyLinkRule],
		send: @escaping (AppFeature.Action) -> Void
	) {
		self.feedback = feedback
		self.rules = rules
		self.send = send
	}

	internal var body: some View {
		ArxToast(feedback.title, detail: feedback.detail) {
			if !feedback.changedOriginals.isEmpty {
				Button {
					send(.ui(.copyLinks(
						.original,
						items: feedback.changedOriginals,
						sourceWindowID: feedback.windowID,
						sourcePaneID: feedback.paneID
					)))
				} label: {
					Text(localized: .appUI.links.copyOriginalShort).padding(.horizontal, 3)
				}
				.buttonStyle(.arxRaised(size: .small))
				.help(String.localized(.appUI.links.copyOriginal))
			}
			if feedback.offersOtherRules, !matchingRules.isEmpty {
				moreMenu
			}
			if feedback.status == .copied, !feedback.copiedURLs.isEmpty {
				ShareLink(items: feedback.copiedURLs) {
					Image(systemName: "square.and.arrow.up")
						.accessibilityLabel(String.localized(.appUI.links.shareCopied))
				}
				.buttonStyle(.arxRaised(size: .small))
				.help(String.localized(.appUI.links.shareCopied))
			}
		}
	}

	private var moreMenu: some View {
		let originals: [LinkCopyItem] = feedback.result.transformations.map(\.original)
		return Menu {
			Section(String.localized(.appUI.links.copyUsing)) {
				ForEach(matchingRules) { rule in
					Button(rule.name) {
						send(.ui(.copyLinks(
							feedback.result.mode,
							items: originals,
							preferredRuleID: rule.id,
							sourceWindowID: feedback.windowID,
							sourcePaneID: feedback.paneID
						)))
					}
				}
			}
			Section(String.localized(.appUI.links.shareUsing)) {
				ForEach(matchingRules) { rule in
					Button(rule.name) {
						send(.ui(.shareProxyLinks(
							items: originals,
							preferredRuleID: rule.id,
							sourceWindowID: feedback.windowID,
							sourcePaneID: feedback.paneID
						)))
					}
				}
			}
		} label: {
			Image(systemName: "ellipsis")
		}
		.menuStyle(.button)
		.menuIndicator(.hidden)
		.buttonStyle(.arxRaised(size: .small))
		.fixedSize()
		.help(String.localized(.appUI.links.moreOptions))
		.accessibilityLabel(String.localized(.appUI.links.moreOptions))
	}

	private var matchingRules: [ProxyLinkRule] {
		rules.filter { rule in
			feedback.result.transformations.allSatisfy { rule.matches($0.original.url) }
		}
	}
}

extension LinkActionFeedback {
	/// A cancelled share needs no word; everything else shows a toast.
	internal var isShown: Bool {
		status != .share(.cancelled)
	}

	internal var title: String {
		switch status {
		case .copied: copiedTitle
		case .copyFailed: String.localized(.appUI.links.copyFailedTitle)
		case .share(.shared): String.localized(.appUI.links.shared)
		case .share(.cancelled): String.localized(.appUI.links.shareCancelled)
		case .share(.failed): String.localized(.appUI.links.shareFailedTitle)
		}
	}

	internal var detail: String? {
		switch status {
		case .copied, .share(.shared), .share(.cancelled): nil
		case .copyFailed: String.localized(.appUI.links.copyFailed)
		case let .share(.failed(message)): message
		}
	}

	/// The links as they were before cleaning or a proxy rule changed them, when one did.
	internal var changedOriginals: [LinkCopyItem] {
		guard status == .copied, isChanged else { return [] }
		return result.transformations.map(\.original)
	}

	/// The URLs now on the clipboard, for the share button.
	internal var copiedURLs: [URL] {
		result.transformations.map(\.output)
	}

	internal var offersOtherRules: Bool {
		result.mode == .proxy || result.mode == .markdownProxy
	}

	private var isChanged: Bool {
		result.transformations.contains { $0.output != $0.original.url }
	}

	private var copiedTitle: String {
		let count: Int = result.transformations.count
		guard count == 1 else { return String.localized(.appUI.links.copiedLinks(count)) }

		switch result.mode {
		case .original:
			return String.localized(.appUI.links.copiedCurrentURL)

		case .clean:
			return isChanged
			? String.localized(.appUI.links.copiedCleanLink)
			: String.localized(.appUI.links.copiedCurrentURL)

		case .markdownOriginal, .markdownProxy:
			return String.localized(.appUI.links.copiedMarkdownLink)

		case .proxy:
			return isChanged
			? String.localized(.appUI.links.copiedProxyLink)
			: String.localized(.appUI.links.copiedCurrentURL)
		}
	}
}
