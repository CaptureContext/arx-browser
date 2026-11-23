import BrowserCore
import SwiftUI

/// One frame of a tour demo at ``TourDemo/canvasSize``, built from AppUI's browser components
/// on sample data.
///
/// The frame depends only on `demo` and `time`. Nothing in it is interactive or focusable, it
/// starts no animations of its own, and it makes no engine or network calls, so it can be drawn
/// offscreen frame by frame. It draws no background; hosts put it on theirs.
public struct TourDemoScene: View {
	public let demo: TourDemo
	public let time: TimeInterval

	/// - Parameters:
	///   - time: Seconds into the loop; wrapped into the demo's duration.
	public init(
		demo: TourDemo,
		time: TimeInterval
	) {
		self.demo = demo
		self.time = time
	}

	public var body: some View {
		let time: TimeInterval = wrappedTime

		ZStack(alignment: .topLeading) {
			switch demo {
			case .peek: TourPeekScene(time: time)
			case .splitView: TourSplitViewScene(time: time)
			case .commandBar: TourCommandBarScene(time: time)
			case .chats: TourChatsScene(time: time)
			case .littleArx: TourLittleArxScene(time: time)
			}
		}
		.frame(width: TourDemo.canvasSize.width, height: TourDemo.canvasSize.height, alignment: .topLeading)
		.environment(\.commandBarIsStatic, true)
		.environment(\.sidebarIsStatic, true)
		.transaction { transaction in
			transaction.disablesAnimations = true
			transaction.animation = nil
		}
		.allowsHitTesting(false)
		.focusable(false)
		.accessibilityHidden(true)
	}

	private var wrappedTime: TimeInterval {
		let remainder: TimeInterval = time.truncatingRemainder(dividingBy: demo.duration)
		return remainder < 0 ? remainder + demo.duration : remainder
	}
}

// MARK: - Layout

/// Where things sit on the canvas, so the pointer and overlays can aim at them.
internal enum TourLayout {
	internal static let window: CGRect = .init(x: 12, y: 12, width: 616, height: 336)
	internal static let sidebarWidth: CGFloat = 168
	internal static let pageInset: CGFloat = 6
	internal static let windowCornerRadius: CGFloat = 10

	/// The page card beside the sidebar.
	internal static let page: CGRect = .init(
		x: window.minX + sidebarWidth,
		y: window.minY + pageInset,
		width: window.width - sidebarWidth - pageInset,
		height: window.height - 2 * pageInset
	)

	/// Peek's card and its buttons, as AppFeature places them over the page.
	internal static let peekFrame: CGRect = BrowserMetrics.Peek.frame(inPane: page)

	internal static var peekCard: CGRect {
		var card: CGRect = peekFrame
		card.size.width -= BrowserMetrics.Peek.Control.size + BrowserMetrics.Peek.controlsSpacing
		return card
	}

	/// The center of Peek's button at `index`, top to bottom.
	internal static func peekControl(_ index: Int) -> CGPoint {
		let size: CGFloat = BrowserMetrics.Peek.Control.size
		return .init(
			x: peekFrame.maxX - size / 2,
			y: peekFrame.minY + size / 2 + CGFloat(index) * (size + BrowserMetrics.Peek.Control.spacing)
		)
	}

	/// The two panes of a split.
	internal static var leftPane: CGRect {
		.init(x: page.minX, y: page.minY, width: (page.width - pageInset) / 2, height: page.height)
	}

	internal static var rightPane: CGRect {
		.init(x: leftPane.maxX + pageInset, y: page.minY, width: leftPane.width, height: page.height)
	}

	/// The center of the sample page's "Read the Peek spec" link, from the page card's top left.
	///
	/// It follows ``TourSamplePage``'s fixed line heights and paddings.
	internal static let linkInPage: CGPoint = .init(x: 22 + 55, y: 22 + 16 + 10 + 26 + 8 + 18 + 14 + 32 + 10 + 8)

	/// The "Read the Peek spec" link on the sample page.
	internal static let link: CGPoint = .init(x: page.minX + linkInPage.x, y: page.minY + linkInPage.y)

	/// The link expressed in the Peek card's unit space, where the card grows from.
	internal static var linkAnchor: UnitPoint {
		.init(
			x: (link.x - peekCard.minX) / peekCard.width,
			y: (link.y - peekCard.minY) / peekCard.height
		)
	}
}

// MARK: - Peek

private struct TourPeekScene: View {
	internal let time: TimeInterval

	internal var body: some View {
		let open: CGFloat = TourTimeline.spring(time, from: 1.45, to: 1.95)
		let close: CGFloat = TourTimeline.ease(time, from: 5.1, to: 5.4)
		let reveal: CGFloat = max(0, open - close * 1.4)
		let recede: CGFloat = TourTimeline.ease(time, from: 1.45, to: 1.8) * (1 - close)
		let isPressed: Bool = (1.3..<1.5).contains(time)

		ZStack(alignment: .topLeading) {
			TourBrowserWindow(selection: .sidebarWidth) {
				TourSamplePage(isLinkPressed: isPressed)
					.tourRecedesBehindPeek(recede)
			}

			// The tab the Peek came from shows the peeked site while it's open (DEV-1224).
			.environment(\.browserPeekedTab, reveal > 0.5 ? TourSample.peekedTab : nil)

			if reveal > 0.001 {
				TourPeekCard(controlsOpacity: 1, showsSplitControl: false)
					.frame(width: TourLayout.peekFrame.width, height: TourLayout.peekFrame.height)
					.modifier(
						TourPeekReveal(
							progress: reveal,
							anchor: TourLayout.linkAnchor,
							cardWidth: TourLayout.peekCard.width,
							frameWidth: TourLayout.peekFrame.width
						)
					)
					.offset(x: TourLayout.peekFrame.minX, y: TourLayout.peekFrame.minY)
			}

			TourKeyHint(text: "esc")
				.opacity(TourTimeline.window(time, in: 4.5...5.6))
				.tourPosition(.init(x: TourLayout.page.midX, y: TourLayout.window.maxY - 26))

			TourPointer(isPressed: isPressed)
				.opacity(max(TourTimeline.window(time, in: -1...2.7), TourTimeline.ease(time, from: 7.5, to: 7.9)))
				.tourPosition(pointer)
		}
	}

	private var pointer: CGPoint {
		let start: CGPoint = .init(x: 430, y: 300)
		let toLink: CGFloat = TourTimeline.ease(time, from: 0.3, to: 1.2)
		let away: CGFloat = TourTimeline.ease(time, from: 1.9, to: 2.7)
		let atLink: CGPoint = TourTimeline.mix(start, TourLayout.link, toLink)
		return TourTimeline.mix(atLink, .init(x: 520, y: 330), away * (time < 7 ? 1 : 0))
	}
}

/// Mirrors Peek's own reveal: the card grows out of the link and is solid before it's full size.
private struct TourPeekReveal: ViewModifier {
	internal let progress: CGFloat
	internal let anchor: UnitPoint
	internal let cardWidth: CGFloat
	internal let frameWidth: CGFloat

	internal func body(content: Content) -> some View {
		let scale: CGFloat = TourTimeline.mix(BrowserMetrics.Peek.originScale, 1, progress)
		content
			.scaleEffect(
				scale,
				anchor: .init(x: anchor.x * cardWidth / frameWidth, y: anchor.y)
			)
			.opacity(Double(min(1, progress * 2.5)))
	}
}

/// Peek's card with its round buttons beside it, as PeekView draws them.
private struct TourPeekCard: View {
	internal let controlsOpacity: CGFloat
	internal let showsSplitControl: Bool

	internal var body: some View {
		HStack(alignment: .top, spacing: BrowserMetrics.Peek.controlsSpacing) {
			TourSamplePeekPage()
				.frame(width: TourLayout.peekCard.width)
				.frame(maxHeight: .infinity)
				.tourPeekCardShape(cornerRadius: BrowserMetrics.Peek.cornerRadius)

			VStack(spacing: BrowserMetrics.Peek.Control.spacing) {
				control("xmark")
				control("arrow.up.left.and.arrow.down.right")
				control("macwindow")
				if showsSplitControl {
					control(BrowserCommand.newSplit.symbol)
				}
			}
			.opacity(controlsOpacity)
		}
	}

	private func control(_ symbol: String) -> some View {
		TourPeekControl(symbol: symbol)
	}
}

/// One of Peek's buttons at rest, drawn by Peek's own `BrowserPeekControlStyle`: an Arx button,
/// a filled rounded square on a solid backing (DEV-1224). The scene takes no hits or focus, so it
/// never shows its hover hint.
private struct TourPeekControl: View {
	internal let symbol: String

	internal var body: some View {
		Button {} label: {
			Image(systemName: symbol)
		}
		.buttonStyle(BrowserPeekControlStyle(hint: ""))
	}
}

// MARK: - Split View

private struct TourSplitViewScene: View {
	internal let time: TimeInterval

	internal var body: some View {
		let split: CGFloat = TourTimeline.ease(time, from: 2.1, to: 2.7) * (1 - TourTimeline.ease(time, from: 7.2, to: 7.9))
		let isPressed: Bool = (1.95..<2.1).contains(time)
		let focusShown: CGFloat = TourTimeline.ease(time, from: 2.8, to: 3.1) * (1 - TourTimeline.ease(time, from: 6.9, to: 7.2))
		let focusLeft: CGFloat = TourTimeline.ease(time, from: 5, to: 5.2) * (1 - TourTimeline.ease(time, from: 6.2, to: 6.4))

		let pageFrame: CGRect = TourTimeline.mix(TourLayout.page, TourLayout.leftPane, split)
		let cardFrame: CGRect = TourTimeline.mix(TourLayout.peekFrame, TourLayout.rightPane, split)
		let controlsWidth: CGFloat = BrowserMetrics.Peek.Control.size + BrowserMetrics.Peek.controlsSpacing

		ZStack(alignment: .topLeading) {
			TourBrowserWindow(selection: .sidebarWidth, splitWith: split > 0.5 ? .peekSpec : nil) {
				Color.clear
			}
			.environment(\.browserPeekedTab, split > 0.5 ? nil : TourSample.peekedTab)

			TourPane(host: TourSample.trackerHost, headerOpacity: split) {
				TourSamplePage(isLinkPressed: false)
			}
			.frame(width: pageFrame.width, height: pageFrame.height)
			.tourRecedesBehindPeek(1 - split)
			.overlay { TourFocusRing(opacity: focusShown * focusLeft) }
			.offset(x: pageFrame.minX, y: pageFrame.minY)

			HStack(alignment: .top, spacing: BrowserMetrics.Peek.controlsSpacing * (1 - split)) {
				TourPane(host: TourSample.docsHost, headerOpacity: split) {
					TourSamplePeekPage()
				}
				.frame(width: max(0, cardFrame.width - controlsWidth * (1 - split)), height: cardFrame.height)
				.tourPeekCardShape(cornerRadius: TourTimeline.mix(BrowserMetrics.Peek.cornerRadius, BrowserMetrics.PageCard.cornerRadius, split))
				.overlay { TourFocusRing(opacity: focusShown * (1 - focusLeft)) }

				VStack(spacing: BrowserMetrics.Peek.Control.spacing) {
					ForEach(
						["xmark", "arrow.up.left.and.arrow.down.right", "macwindow", BrowserCommand.newSplit.symbol],
						id: \.self
					) { symbol in
						TourPeekControl(symbol: symbol)
					}
				}
				.frame(width: controlsWidth * (1 - split), alignment: .leading)
				.opacity(Double(1 - TourTimeline.ease(time, from: 2.05, to: 2.3)) + Double(TourTimeline.ease(time, from: 7.5, to: 7.9)))
				.clipped()
			}
			.offset(x: cardFrame.minX, y: cardFrame.minY)

			TourHint(text: BrowserCommand.newSplit.title)
				.opacity(TourTimeline.window(time, in: 1.3...2.2, fade: 0.15))
				.tourPosition(.init(x: TourLayout.peekControl(3).x - 60, y: TourLayout.peekControl(3).y))

			TourHint(text: BrowserCommand.focusOtherPane.title)
				.opacity(TourTimeline.window(time, in: 4.5...5.8))
				.tourPosition(.init(x: TourLayout.page.midX, y: TourLayout.window.maxY - 26))

			TourPointer(isPressed: isPressed)
				.opacity(TourTimeline.window(time, in: 0.5...3))
				.tourPosition(pointer)
		}
	}

	private var pointer: CGPoint {
		let start: CGPoint = .init(x: 470, y: 320)
		let toButton: CGFloat = TourTimeline.ease(time, from: 0.6, to: 1.3)
		let away: CGFloat = TourTimeline.ease(time, from: 2.3, to: 3)
		let atButton: CGPoint = TourTimeline.mix(start, TourLayout.peekControl(3), toButton)
		return TourTimeline.mix(atButton, .init(x: 560, y: 330), away)
	}
}

/// A split pane: the host above the page, shown once the Peek has become a pane.
private struct TourPane<Content: View>: View {
	internal let host: String
	internal let headerOpacity: CGFloat
	internal let content: Content

	internal init(
		host: String,
		headerOpacity: CGFloat,
		@ViewBuilder content: () -> Content
	) {
		self.host = host
		self.headerOpacity = headerOpacity
		self.content = content()
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			HStack(spacing: 6) {
				Image(systemName: "chevron.left")
				Image(systemName: "chevron.right")
					.opacity(0.4)
				Text(verbatim: host)
					.font(.system(size: 11, weight: .medium))
				Spacer(minLength: 0)
			}
			.font(.system(size: 10, weight: .semibold))
			.foregroundStyle(BrowserTheme.secondary)
			.padding(.horizontal, 10)
			.frame(height: 24 * headerOpacity, alignment: .center)
			.opacity(Double(headerOpacity))
			.clipped()

			content
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		}
		.browserPageCard()
	}
}

private struct TourFocusRing: View {
	internal let opacity: CGFloat

	internal var body: some View {
		RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
			.strokeBorder(BrowserTheme.accent, lineWidth: 2)
			.opacity(Double(opacity))
	}
}

// MARK: - Command bar

private struct TourCommandBarScene: View {
	internal let time: TimeInterval

	internal var body: some View {
		let shown: CGFloat = TourTimeline.ease(time, from: 0.9, to: 1.15) * (1 - TourTimeline.ease(time, from: 5.05, to: 5.25))
		let switched: CGFloat = TourTimeline.ease(time, from: 5.1, to: 5.4) * (1 - TourTimeline.ease(time, from: 7.3, to: 7.8))
		let query: String = TourTimeline.typed(TourSample.query, time, from: 1.3, to: 2.1)

		ZStack(alignment: .topLeading) {
			TourBrowserWindow(selection: switched > 0.5 ? .peekSpec : .sidebarWidth) {
				ZStack(alignment: .topLeading) {
					TourSamplePage(isLinkPressed: false)
						.opacity(Double(1 - switched))
					TourSamplePeekPage()
						.opacity(Double(switched))
				}
			}

			if shown > 0.001 {
				TourCommandBar(query: query, selectedID: selection, results: TourSample.commandResults(for: query))
					.frame(width: TourCommandBar.width)
					.scaleEffect(TourTimeline.mix(0.97, 1, shown), anchor: .top)
					.opacity(Double(shown))
					.offset(x: TourLayout.window.midX - TourCommandBar.width / 2, y: TourCommandBar.top)
			}

			TourKeyHint(text: BrowserCommand.commandBar.shortcut?.display ?? "")
				.opacity(TourTimeline.window(time, in: 0.4...1.5))
				.tourPosition(.init(x: TourLayout.page.midX, y: TourLayout.window.maxY - 26))

			TourKeyHint(text: "↩")
				.opacity(TourTimeline.window(time, in: 4.6...5.6))
				.tourPosition(.init(x: TourLayout.page.midX, y: TourLayout.window.maxY - 26))
		}
	}

	/// Down to the history entry and the action, then back up to the tab.
	private var selection: String? {
		switch time {
		case ..<3.7: TourSample.CommandResult.tab.rawValue
		case ..<4.1: TourSample.CommandResult.history.rawValue
		case ..<4.5: TourSample.CommandResult.action.rawValue
		default: TourSample.CommandResult.tab.rawValue
		}
	}
}

/// The Raised command bar as the window shows it with typed text (DEV-1277): "Ask an agent ⇥"
/// at the input's end and Actions ⌘K floating in its corner while there's a result to act on.
internal struct TourCommandBar: View {
	/// Wider than the app's 55% of a narrow window, so the demo's rows read at the canvas' size.
	internal static let width: CGFloat = 420

	/// Near the window's top, as the Raised bar's taller rows fill the small window.
	internal static let top: CGFloat = TourLayout.window.minY + 10

	internal let query: String
	internal let selectedID: String?
	internal let results: [CommandBarResult]

	internal var body: some View {
		CommandBar(
			query: .constant(query),
			selectedID: .constant(selectedID),
			results: results,
			// Typed text that isn't a shortcut keyword goes to a chat on Tab (DEV-751).
			onAskAgent: query.isEmpty ? nil : {},
			onShowActions: {},
			onSelect: { _ in },
			onDismiss: {}
		)
	}
}

// MARK: - Little Arx

private struct TourLittleArxScene: View {
	internal let time: TimeInterval

	/// Where Little Arx settles, over the chat's right side.
	internal static let littleArx: CGRect = .init(x: 204, y: 44, width: 424, height: 280)

	internal var body: some View {
		let isPressed: Bool = (1.3..<1.5).contains(time)
		let open: CGFloat = TourTimeline.spring(time, from: 1.45, to: 2)
		let close: CGFloat = TourTimeline.ease(time, from: 6.6, to: 6.95)
		let shown: CGFloat = max(0, open - close * 1.4)

		ZStack(alignment: .topLeading) {
			TourChatWindow(isLinkPressed: isPressed)
				.frame(width: TourChatWindow.frame.width, height: TourChatWindow.frame.height)
				.offset(x: TourChatWindow.frame.minX, y: TourChatWindow.frame.minY)

			if shown > 0.001 {
				TourLittleArxWindow()
					.frame(width: Self.littleArx.width, height: Self.littleArx.height)
					.scaleEffect(
						TourTimeline.mix(0.5, 1, shown),
						anchor: .init(
							x: (TourChatWindow.link.x - Self.littleArx.minX) / Self.littleArx.width,
							y: (TourChatWindow.link.y - Self.littleArx.minY) / Self.littleArx.height
						)
					)
					.opacity(Double(min(1, shown * 2.5)))
					.offset(x: Self.littleArx.minX, y: Self.littleArx.minY)
			}

			TourPointer(isPressed: isPressed)
				.opacity(max(TourTimeline.window(time, in: -1...2.6), TourTimeline.ease(time, from: 7.4, to: 7.9)))
				.tourPosition(pointer)
		}
	}

	private var pointer: CGPoint {
		let start: CGPoint = .init(x: 250, y: 320)
		let toLink: CGFloat = TourTimeline.ease(time, from: 0.3, to: 1.2)
		let away: CGFloat = TourTimeline.ease(time, from: 1.9, to: 2.6)
		let atLink: CGPoint = TourTimeline.mix(start, TourChatWindow.link, toLink)
		return TourTimeline.mix(atLink, .init(x: 200, y: 345), away * (time < 7 ? 1 : 0))
	}
}

/// Another app's window: a chat with a shared link.
private struct TourChatWindow: View {
	internal static let frame: CGRect = .init(x: 24, y: 28, width: 380, height: 300)

	/// The shared link, in canvas coordinates.
	internal static var link: CGPoint { .init(x: frame.minX + 230, y: frame.minY + 186) }

	internal let isLinkPressed: Bool

	internal var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: TourLayout.windowCornerRadius, style: .continuous)

		HStack(spacing: 0) {
			VStack(alignment: .leading, spacing: 4) {
				TourTrafficLights()
					.frame(height: 28)
				conversation(.appUI.onboarding.tour.sample.chat.person1, initial: "S", isSelected: true)
				conversation(.appUI.onboarding.tour.sample.chat.person2, initial: "R", isSelected: false)
				conversation(.appUI.onboarding.tour.sample.chat.person3, initial: "J", isSelected: false)
				Spacer(minLength: 0)
			}
			.padding(.horizontal, 8)
			.frame(width: 120)
			.frame(maxHeight: .infinity)
			.background(.quaternary.opacity(0.5))

			VStack(alignment: .leading, spacing: 8) {
				Text(localized: .appUI.onboarding.tour.sample.chat.person1)
					.font(.system(size: 11, weight: .semibold))
					.frame(height: 28)
				Spacer(minLength: 0)
				bubble {
					Text(localized: .appUI.onboarding.tour.sample.chat.message)
				}
				bubble {
					Text(verbatim: TourSample.notesLink)
						.underline()
						.foregroundStyle(isLinkPressed ? AnyShapeStyle(BrowserTheme.accent.opacity(0.6)) : AnyShapeStyle(BrowserTheme.accent))
				}
				.frame(height: 30)
				Spacer(minLength: 0)
					.frame(height: 76)
			}
			.font(.system(size: 11))
			.padding(.horizontal, 14)
			.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
		}
		.background(Color(nsColor: .windowBackgroundColor), in: shape)
		.clipShape(shape)
		.overlay { shape.strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
		.shadow(color: .black.opacity(0.18), radius: 14, y: 6)
	}

	private func conversation(
		_ name: _XCStringResource,
		initial: String,
		isSelected: Bool
	) -> some View {
		HStack(spacing: 6) {
			Text(verbatim: initial)
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(BrowserTheme.onAccent)
				.frame(width: 18, height: 18)
				.background(BrowserTheme.accent.opacity(isSelected ? 1 : 0.5), in: .circle)
			Text(localized: name)
				.font(.system(size: 10, weight: .medium))
				.lineLimit(1)
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 6)
		.frame(height: 26)
		.background(
			isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
			in: .rect(cornerRadius: 6, style: .continuous)
		)
	}

	private func bubble(@ViewBuilder _ content: () -> some View) -> some View {
		content()
			.lineLimit(1)
			.padding(.horizontal, 10)
			.padding(.vertical, 6)
			.background(.quaternary, in: .rect(cornerRadius: 12, style: .continuous))
	}
}

/// Little Arx as `LittleWindowHeader` draws it (DEV-523, DEV-1153): the window's buttons, the
/// centred URL bar with the profile picker at its start, and "Open in" as a split button with its
/// ⌘O, over the page card.
///
/// The header is put together here from its parts rather than through `LittleWindowHeader`, whose
/// window buttons are AppKit's and whose profile picker is a menu, neither of which draws offscreen.
private struct TourLittleArxWindow: View {
	private typealias Metrics = BrowserMetrics.LittleArx

	internal var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: Metrics.cornerRadius, style: .continuous)

		VStack(spacing: 0) {
			HStack(spacing: 6) {
				TourTrafficLights()
					.padding(.trailing, 4)
				URLBar(
					url: URL(string: "https://\(TourSample.notesLink)"),
					height: Metrics.addressHeight,
					centersAddress: true,
					prominentActions: true,
					leading: AnyView(profileBadge),
					onActivate: {},
					onCopy: {}
				)
				.frame(minWidth: Metrics.addressMinimumWidth, maxWidth: .infinity)
				.layoutPriority(1)
				ChromeSplitButton(
					height: Metrics.addressHeight,
					moreHelp: String.localized(.appUI.profile.moveTitle),
					action: {},
					onMore: {}
				) {
					Text(localized: .appUI.littleArx.openIn(String.localized(.appUI.onboarding.tour.sample.space)))
						.lineLimit(1)
					ChromeKeyHint("⌘O")
				}
			}
			.padding(.horizontal, 8)
			.frame(height: Metrics.toolbarHeight)

			TourSampleNotesPage()
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.browserPageCard(cornerRadius: Metrics.pageCornerRadius)
				.padding([.horizontal, .bottom], Metrics.pageInset)
		}
		.background { BrowserChromeBackground(textured: true) }
		.clipShape(shape)
		.overlay { shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: 0.5) }
		.background {
			shape
				.fill(.black.opacity(0.01))
				.browserShadow(BrowserMetrics.Peek.shadow)
		}
	}

	/// The profile picker's badge, the face alone as in a narrow window: the sample has no
	/// profile name to show.
	private var profileBadge: some View {
		ProfileBadge(
			name: "",
			showsName: false,
			height: BrowserMetrics.URLBar.accessoryHeight(forHeight: Metrics.addressHeight),
			cornerRadius: BrowserMetrics.URLBar.accessoryCornerRadius(forHeight: Metrics.addressHeight)
		)
	}
}

// MARK: - Browser window

/// A small Arx window: the chrome, a sidebar with the address, favorites and tabs, and a page.
internal struct TourBrowserWindow<Page: View>: View {
	internal let selection: TourSample.Tab
	internal let splitWith: TourSample.Tab?
	internal let page: Page

	internal init(
		selection: TourSample.Tab,
		splitWith: TourSample.Tab? = nil,
		@ViewBuilder page: () -> Page
	) {
		self.selection = selection
		self.splitWith = splitWith
		self.page = page()
	}

	internal var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: TourLayout.windowCornerRadius, style: .continuous)

		HStack(spacing: 0) {
			sidebar
				.frame(width: TourLayout.sidebarWidth)

			page
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.padding([.top, .bottom, .trailing], TourLayout.pageInset)
		}
		.frame(width: TourLayout.window.width, height: TourLayout.window.height)
		.background { BrowserChromeBackground(textured: true) }
		.clipShape(shape)
		.overlay { shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: 0.5) }
		.background {
			shape
				.fill(.black.opacity(0.01))
				.browserShadow(.init(opacity: 0.18, radius: 14, y: 6))
		}
		.offset(x: TourLayout.window.minX, y: TourLayout.window.minY)
	}

	private var sidebar: some View {
		VStack(alignment: .leading, spacing: BrowserMetrics.Sidebar.sectionSpacing) {
			TourTrafficLights()
				.frame(height: 22)
				.padding(.horizontal, 4)

			// The sidebar's own field, at its own 36 points (DEV-1252).
			URLBar(
				url: URL(string: "https://\(selection.host)"),
				onActivate: {},
				onCopy: {}
			)

			HStack(spacing: BrowserMetrics.Favorites.spacing) {
				ForEach(TourSample.favorites) { item in
					FavoriteTile(item: item, onAction: { _ in })
				}
			}

			VStack(spacing: BrowserMetrics.Row.spacing) {
				ForEach(TourSample.Tab.allCases, id: \.self) { tab in
					if tab == selection, let splitWith {
						// A Split View is one row with a segment per pane (DEV-1006).
						SplitSidebarRow(
							item: tab.splitItem(with: splitWith),
							split: tab.split(with: splitWith),
							selected: true,
							onAction: { _ in }
						)
					} else {
						SidebarRow(
							item: tab.item,
							selected: tab == selection,
							onAction: { _ in }
						)
					}
				}
			}

			Spacer(minLength: 0)
		}
		.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
		.padding(.top, 8)
	}
}

private struct TourTrafficLights: View {
	internal var body: some View {
		HStack(spacing: 6) {
			ForEach(
				[
					Color(red: 1, green: 0.37, blue: 0.34),
					Color(red: 1, green: 0.74, blue: 0.18),
					Color(red: 0.16, green: 0.79, blue: 0.25),
				],
				id: \.self
			) { color in
				Circle()
					.fill(color)
					.frame(width: 9, height: 9)
			}
		}
	}
}

// MARK: - Sample pages

/// The page the demos start on: a task in a tracker with a link to the Peek spec.
internal struct TourSamplePage: View {
	internal let isLinkPressed: Bool

	/// Reflows the description into three lines, for a page beside the chat panel.
	internal var isNarrow: Bool

	internal init(
		isLinkPressed: Bool,
		isNarrow: Bool = false
	) {
		self.isLinkPressed = isLinkPressed
		self.isNarrow = isNarrow
	}

	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Label {
				Text(localized: .appUI.onboarding.tour.sample.page.breadcrumb)
			} icon: {
				Image(systemName: "square.grid.2x2")
			}
			.font(.system(size: 10, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.frame(height: 16)
			.padding(.bottom, 10)

			Text(localized: .appUI.onboarding.tour.sample.page.title)
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(BrowserTheme.text)
				.frame(height: 26)
				.padding(.bottom, 8)

			HStack(spacing: 6) {
				chip(.appUI.onboarding.tour.sample.page.status, tint: .orange)
				chip(.appUI.onboarding.tour.sample.page.label, tint: .lavender)
			}
			.frame(height: 18)
			.padding(.bottom, 14)

			Text(localized: .appUI.onboarding.tour.sample.page.body)
				.font(.system(size: 11))
				.foregroundStyle(BrowserTheme.text.opacity(0.8))
				.lineLimit(isNarrow ? 4 : 2)
				.frame(width: isNarrow ? 180 : 360, height: isNarrow ? 60 : 32, alignment: .topLeading)
				.padding(.bottom, 10)

			Text(localized: .appUI.onboarding.tour.sample.page.link)
				.font(.system(size: 11, weight: .medium))
				.underline()
				.foregroundStyle(isLinkPressed ? AnyShapeStyle(BrowserTheme.accent.opacity(0.55)) : AnyShapeStyle(BrowserTheme.accent))
				.frame(height: 16)
				.padding(.bottom, 18)

			Text(localized: .appUI.onboarding.tour.sample.page.activity)
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(BrowserTheme.text)
				.padding(.bottom, 6)

			VStack(alignment: .leading, spacing: 4) {
				Text(localized: .appUI.onboarding.tour.sample.page.activity1)
				Text(localized: .appUI.onboarding.tour.sample.page.activity2)
			}
			.font(.system(size: 10))
			.foregroundStyle(BrowserTheme.secondary)
		}
		.lineLimit(1)
		.fixedSize(horizontal: true, vertical: false)
		.padding(22)
		.frame(width: TourLayout.page.width, alignment: .topLeading)
		.tourClippedPage()
		.browserPageCard()
	}

	private func chip(
		_ title: _XCStringResource,
		tint: SidebarTint
	) -> some View {
		Text(localized: title)
			.font(.system(size: 9, weight: .semibold))
			.foregroundStyle(tint.color)
			.padding(.horizontal, 7)
			.frame(height: 18)
			.background(tint.color.opacity(0.14), in: .capsule)
	}
}

/// The Peek spec, opened from the link.
private struct TourSamplePeekPage: View {
	internal var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Label {
				Text(verbatim: TourSample.docsHost)
			} icon: {
				Image(systemName: "doc.text")
			}
			.font(.system(size: 10, weight: .medium))
			.foregroundStyle(BrowserTheme.secondary)
			.padding(.bottom, 12)

			Text(localized: .appUI.onboarding.tour.sample.peek.title)
				.font(.system(size: 20, weight: .semibold))
				.foregroundStyle(BrowserTheme.text)
				.padding(.bottom, 12)

			VStack(alignment: .leading, spacing: 10) {
				Text(localized: .appUI.onboarding.tour.sample.peek.body1)
				Text(localized: .appUI.onboarding.tour.sample.peek.body2)
			}
			.font(.system(size: 11))
			.foregroundStyle(BrowserTheme.text.opacity(0.8))
			.fixedSize(horizontal: false, vertical: true)
		}
		.padding(22)
		.frame(width: 300, alignment: .topLeading)
		.tourClippedPage()
		.background(BrowserTheme.page)
	}
}

/// The launch notes a chat link opens in Little Arx.
private struct TourSampleNotesPage: View {
	internal var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(localized: .appUI.onboarding.defaultBrowser.sample.title)
				.font(.system(size: 17, weight: .semibold))
				.foregroundStyle(BrowserTheme.text)

			Text(localized: .appUI.onboarding.defaultBrowser.sample.shared)
				.font(.system(size: 10))
				.foregroundStyle(BrowserTheme.secondary)

			Text(localized: .appUI.onboarding.defaultBrowser.sample.summary)
				.font(.system(size: 11))
				.foregroundStyle(BrowserTheme.text.opacity(0.85))
				.fixedSize(horizontal: false, vertical: true)
				.padding(.top, 6)

			VStack(alignment: .leading, spacing: 4) {
				bullet(.appUI.onboarding.defaultBrowser.sample.item1)
				bullet(.appUI.onboarding.defaultBrowser.sample.item2)
				bullet(.appUI.onboarding.defaultBrowser.sample.item3)
			}
			.font(.system(size: 11))
			.foregroundStyle(BrowserTheme.text.opacity(0.85))
		}
		.padding(18)
	}

	private func bullet(_ text: _XCStringResource) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 6) {
			Text(verbatim: "•")
			Text(localized: text)
		}
	}
}

// MARK: - Overlays

/// A pressed key, shown while the demo "types" it.
internal struct TourKeyHint: View {
	internal let text: String

	internal var body: some View {
		Text(verbatim: text)
			.font(.system(size: 13, weight: .semibold, design: .rounded))
			.foregroundStyle(.white)
			.padding(.horizontal, 10)
			.frame(minWidth: 34, minHeight: 28)
			.background(.black.opacity(0.78), in: .rect(cornerRadius: 7, style: .continuous))
			.overlay {
				RoundedRectangle(cornerRadius: 7, style: .continuous)
					.strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
			}
			.browserShadow(.init(opacity: 0.25, radius: 6, y: 2))
	}
}

/// A command's name, as a hint beside what's about to be used.
private struct TourHint: View {
	internal let text: String

	internal var body: some View {
		Text(verbatim: text)
			.font(.system(size: 11, weight: .medium))
			.foregroundStyle(.white)
			.lineLimit(1)
			.fixedSize()
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(.black.opacity(0.82), in: .capsule)
			.overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
			.browserShadow(.init(opacity: 0.25, radius: 6, y: 2))
	}
}

/// The arrow pointer; its tip is at the view's position.
internal struct TourPointer: View {
	internal let isPressed: Bool

	internal var body: some View {
		TourPointerShape()
			.fill(.black)
			.overlay { TourPointerShape().stroke(.white, lineWidth: 1.2) }
			.frame(width: 13, height: 20)
			.scaleEffect(isPressed ? 0.88 : 1, anchor: .topLeading)
			.shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
			.offset(x: 6.5, y: 10)
	}
}

private struct TourPointerShape: Shape {
	internal func path(in rect: CGRect) -> Path {
		let width: CGFloat = rect.width
		let height: CGFloat = rect.height
		var path: Path = .init()
		path.move(to: .init(x: 0, y: 0))
		path.addLine(to: .init(x: 0, y: height * 0.8))
		path.addLine(to: .init(x: width * 0.3, y: height * 0.62))
		path.addLine(to: .init(x: width * 0.48, y: height))
		path.addLine(to: .init(x: width * 0.66, y: height * 0.93))
		path.addLine(to: .init(x: width * 0.5, y: height * 0.57))
		path.addLine(to: .init(x: width, y: height * 0.57))
		path.closeSubpath()
		return path.offsetBy(dx: rect.minX, dy: rect.minY)
	}
}

extension View {
	/// Takes whatever size it's offered and shows the content from its top left, clipped,
	/// so a narrower pane cuts the page off instead of reflowing it.
	internal func tourClippedPage() -> some View {
		Color.clear
			.overlay(alignment: .topLeading) { self }
			.clipped()
	}

	/// Centers the view on `point` of a top-leading canvas.
	internal func tourPosition(_ point: CGPoint) -> some View {
		frame(width: 0, height: 0)
			.offset(x: point.x, y: point.y)
	}

	/// The page a Peek opened from, as `browserRecedesBehindPeek` draws it: scaled back and
	/// dimmed by `progress`, from 0 at rest to 1 behind an open Peek (DEV-1224).
	fileprivate func tourRecedesBehindPeek(_ progress: CGFloat) -> some View {
		self
			.scaleEffect(TourTimeline.mix(1, BrowserMetrics.Peek.backgroundScale, progress))
			.opacity(Double(TourTimeline.mix(1, CGFloat(BrowserMetrics.Peek.backgroundOpacity), progress)))
	}

	fileprivate func tourPeekCardShape(cornerRadius: CGFloat) -> some View {
		let shape: RoundedRectangle = .init(cornerRadius: cornerRadius, style: .continuous)
		return self
			.background(BrowserTheme.page)
			.clipShape(shape)
			.overlay { shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth) }
			.background {
				shape
					.fill(BrowserTheme.page)
					.browserShadow(BrowserMetrics.Peek.shadow)
			}
	}
}

// MARK: - Sample data

internal enum TourSample {
	internal static let trackerHost: String = "tracker.example.com"
	internal static let docsHost: String = "docs.example.com"
	internal static let notesLink: String = "notes.example.com/launch"

	/// What the command bar demo types.
	internal static var query: String { String.localized(.appUI.onboarding.tour.sample.command.query) }

	/// What the chats demo types to find the Chats command.
	internal static var chatsQuery: String { String.localized(.appUI.onboarding.tour.sample.chats.query) }

	/// The Peek spec, peeked from the sample page's tab.
	internal static var peekedTab: BrowserPeekedTab {
		.init(
			tabID: Tab.sidebarWidth.tabID,
			siteIcon: nil,
			title: String.localized(.appUI.onboarding.tour.sample.peek.title),
			symbol: TourSiteGlyph.docs.symbol
		)
	}

	/// The Chats command, as the command bar lists it.
	internal static var chatsResult: CommandBarResult {
		.init(
			id: "chats",
			title: BrowserCommand.chats.title,
			actionTitle: String.localized(.appUI.onboarding.tour.sample.command.run),
			symbol: BrowserCommand.chats.symbol
		)
	}

	internal enum Tab: CaseIterable, Hashable {
		case sidebarWidth
		case peekSpec
		case pullRequests
		case plan

		internal var host: String {
			switch self {
			case .sidebarWidth: TourSample.trackerHost
			case .peekSpec: TourSample.docsHost
			case .pullRequests: "code.example.com"
			case .plan: "notes.example.com"
			}
		}

		internal var item: SidebarItem {
			item(id: tabID)
		}

		/// The tab's own ID, which a Peek opened from it names.
		internal var tabID: UUID {
			TourSample.id(index + 20)
		}

		/// The Split View this tab makes with `other`'s page opened beside it, as Peek's "Open in
		/// Split View" makes it: this tab and a new one, in pane order.
		internal func split(with other: Tab) -> SidebarItem.Split {
			.init(
				id: TourSample.id(index + 60),
				members: [
					item,
					other.item(id: TourSample.id(other.index + 40)),
				]
			)
		}

		/// The Split View's row, which stands for both its tabs.
		internal func splitItem(with other: Tab) -> SidebarItem {
			var row: SidebarItem = self.item(id: TourSample.id(index + 60))
			row.split = split(with: other)
			return row
		}

		private func item(id: UUID) -> SidebarItem {
			.init(
				id: .tab(id),
				title: title,
				symbol: symbol,
				tint: tint,
				isPinned: false,
				interactions: []
			)
		}

		private var index: UInt8 {
			UInt8(Tab.allCases.firstIndex(of: self) ?? 0)
		}

		private var title: String {
			switch self {
			case .sidebarWidth: String.localized(.appUI.onboarding.tour.sample.page.title)
			case .peekSpec: String.localized(.appUI.onboarding.tour.sample.peek.title)
			case .pullRequests: String.localized(.appUI.onboarding.tour.sample.tab.pullRequests)
			case .plan: String.localized(.appUI.onboarding.tour.sample.tab.plan)
			}
		}

		/// The site's favicon, drawn in code (DEV-791). The plan lives in the notes app, so it
		/// shares the notes favorite's icon.
		private var symbol: String {
			switch self {
			case .sidebarWidth: TourSiteGlyph.tracker.symbol
			case .peekSpec: TourSiteGlyph.docs.symbol
			case .pullRequests: TourSiteGlyph.code.symbol
			case .plan: TourSiteGlyph.notes.symbol
			}
		}

		private var tint: SidebarTint {
			switch self {
			case .sidebarWidth: .lavender
			case .peekSpec: .blue
			case .pullRequests: .green
			case .plan: .orange
			}
		}
	}

	internal static let favorites: [SidebarItem] = [
		.init(id: .tab(id(10)), title: "", symbol: TourSiteGlyph.mail.symbol, tint: .pink, interactions: []),
		.init(id: .tab(id(11)), title: "", symbol: TourSiteGlyph.calendar.symbol, tint: .white, interactions: []),
		.init(id: .tab(id(12)), title: "", symbol: TourSiteGlyph.notes.symbol, tint: .yellow, interactions: []),
	]

	internal enum CommandResult: String {
		case tab
		case history
		case action
		case search
	}

	/// What the command bar finds for the typed part of `query`: the tab and a search, then, once
	/// there's enough to match, the tab, a history entry and an action, which fit above Actions ⌘K
	/// in the small window.
	internal static func commandResults(for query: String) -> [CommandBarResult] {
		guard !query.isEmpty else { return [] }

		let search: CommandBarResult = .init(
			id: CommandResult.search.rawValue,
			title: String.localized(.appUI.onboarding.tour.sample.command.search(query)),
			actionTitle: String.localized(.appUI.onboarding.tour.sample.command.searchAction),
			symbol: "magnifyingglass"
		)
		let tab: CommandBarResult = .init(
			id: CommandResult.tab.rawValue,
			title: String.localized(.appUI.onboarding.tour.sample.peek.title),
			subtitle: docsHost,
			actionTitle: String.localized(.appUI.onboarding.tour.sample.command.switchToTab),
			symbol: TourSiteGlyph.docs.symbol,
			tint: .blue
		)
		guard query.count > 1 else { return [tab, search] }

		return [
			tab,
			.init(
				id: CommandResult.history.rawValue,
				title: String.localized(.appUI.onboarding.tour.sample.command.history),
				subtitle: String.localized(.appUI.onboarding.tour.sample.command.historySubtitle),
				actionTitle: String.localized(.appUI.onboarding.tour.sample.command.open),
				symbol: "clock.arrow.circlepath"
			),
			.init(
				id: CommandResult.action.rawValue,
				title: String.localized(.appUI.onboarding.tour.sample.command.action),
				actionTitle: String.localized(.appUI.onboarding.tour.sample.command.run),
				symbol: BrowserCommand.newSplit.symbol
			),
		]
	}

	internal static func id(_ value: UInt8) -> UUID {
		UUID(uuid: (0x70, value, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
	}
}
