import SwiftUI

// MARK: - Chats

/// The command bar's Chats command opens the chat beside the sample page, "Summarize the page"
/// is chosen, a short summary streams in, and ⇧Esc hides the chat again (DEV-803).
///
/// The panel is drawn here in the Studio panel's look (ChatFeature's `ChatStudioPanel`): raised
/// tiles for the header and composer, suggestions by the composer with the first in the accent,
/// the person's message on a raised card, the browser's work in a pale accent chip and the answer
/// as plain text. Everything is scripted; there's no agent and no network.
internal struct TourChatsScene: View {
	internal let time: TimeInterval

	internal var body: some View {
		let open: CGFloat = TourTimeline.spring(time, from: 1.1, to: 1.55) * (1 - TourTimeline.ease(time, from: 7.05, to: 7.45))
		let isPressed: Bool = (2.1..<2.3).contains(time)
		let pageWidth: CGFloat = TourTimeline.mix(TourLayout.page.width, TourChatsLayout.narrowPageWidth, min(1, open))

		ZStack(alignment: .topLeading) {
			TourBrowserWindow(selection: .sidebarWidth) {
				TourSamplePage(isLinkPressed: false, isNarrow: open > 0.5)
					.frame(width: pageWidth)
					.frame(maxWidth: .infinity, alignment: .leading)
			}

			if open > 0.001 {
				TourChatPanel(time: time, isSuggestionPressed: isPressed)
					.frame(width: TourChatsLayout.panel.width, height: TourChatsLayout.panel.height)
					.offset(
						x: TourChatsLayout.panel.minX + (1 - open) * (TourChatsLayout.panel.width + TourLayout.pageInset),
						y: TourChatsLayout.panel.minY
					)
					.opacity(Double(min(1, open * 2)))
					.frame(width: TourDemo.canvasSize.width, height: TourDemo.canvasSize.height, alignment: .topLeading)
					.mask(alignment: .topLeading) {
						RoundedRectangle(cornerRadius: TourLayout.windowCornerRadius, style: .continuous)
							.frame(width: TourLayout.window.width, height: TourLayout.window.height)
							.offset(x: TourLayout.window.minX, y: TourLayout.window.minY)
					}
			}

			let barShown: CGFloat = TourTimeline.ease(time, from: 0.1, to: 0.3) * (1 - TourTimeline.ease(time, from: 1, to: 1.15))
			if barShown > 0.001 {
				let query: String = TourTimeline.typed(TourSample.chatsQuery, time, from: 0.35, to: 0.75)
				TourCommandBar(
					query: query,
					selectedID: TourSample.chatsResult.id,
					results: query.isEmpty ? [] : [TourSample.chatsResult]
				)
				.frame(width: Self.commandBarWidth)
				.scaleEffect(TourTimeline.mix(0.97, 1, barShown), anchor: .top)
				.opacity(Double(barShown))
				.offset(
					x: TourLayout.window.midX - Self.commandBarWidth / 2,
					y: TourLayout.window.minY + TourLayout.window.height * 0.16
				)
			}

			TourKeyHint(text: "↩")
				.opacity(TourTimeline.window(time, in: 0.8...1.3))
				.tourPosition(.init(x: TourLayout.page.midX, y: TourLayout.window.maxY - 26))

			TourKeyHint(text: "⇧ esc")
				.opacity(TourTimeline.window(time, in: 6.6...7.5))
				.tourPosition(.init(x: TourLayout.page.midX, y: TourLayout.window.maxY - 26))

			TourPointer(isPressed: isPressed)
				.opacity(max(TourTimeline.window(time, in: 1.35...3.2), TourTimeline.ease(time, from: 7.6, to: 7.95)))
				.tourPosition(pointer)
		}
	}

	/// Three quarters of the command bar demo's: one result needs less room.
	internal static let commandBarWidth: CGFloat = TourCommandBar.width * 0.75

	private var pointer: CGPoint {
		let start: CGPoint = .init(x: 330, y: 330)
		let toSuggestion: CGFloat = TourTimeline.ease(time, from: 1.55, to: 2.05)
		let away: CGFloat = TourTimeline.ease(time, from: 2.45, to: 3.2)
		let atSuggestion: CGPoint = TourTimeline.mix(start, TourChatsLayout.firstSuggestion, toSuggestion)
		return TourTimeline.mix(atSuggestion, .init(x: 380, y: 338), away * (time < 7 ? 1 : 0))
	}
}

/// Where the chat panel and its parts sit on the canvas.
internal enum TourChatsLayout {
	internal static let panelWidth: CGFloat = 206

	/// The chat panel, at the page's trailing side.
	internal static let panel: CGRect = .init(
		x: TourLayout.page.maxX - panelWidth,
		y: TourLayout.page.minY,
		width: panelWidth,
		height: TourLayout.page.height
	)

	/// The page beside the open panel.
	internal static let narrowPageWidth: CGFloat = TourLayout.page.width - panelWidth - TourLayout.pageInset

	internal static let headerHeight: CGFloat = 42
	internal static let composerHeight: CGFloat = 78
	internal static let rowHeight: CGFloat = 22
	internal static let suggestionCount: Int = 3
	internal static let bodyBottomPadding: CGFloat = 6
	internal static let horizontalPadding: CGFloat = 14

	/// The middle of the first suggestion's label, where the pointer clicks.
	internal static var firstSuggestion: CGPoint {
		.init(
			x: panel.minX + horizontalPadding + 70,
			y: panel.maxY - composerHeight - bodyBottomPadding
				- CGFloat(suggestionCount) * rowHeight + rowHeight / 2
		)
	}
}

/// The Studio panel on sample data: a new chat's suggestions, then the summary streaming in.
private struct TourChatPanel: View {
	internal let time: TimeInterval
	internal let isSuggestionPressed: Bool

	/// When "Summarize the page" is sent.
	internal static let sent: TimeInterval = 2.3

	internal var body: some View {
		let isSent: Bool = time >= Self.sent

		VStack(spacing: 0) {
			header(isSent: isSent)
				.frame(height: TourChatsLayout.headerHeight)

			Group {
				if isSent {
					TourChatTranscript(time: time)
				} else {
					suggestions
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)

			composer(isSent: isSent)
				.frame(height: TourChatsLayout.composerHeight)
		}
		.foregroundStyle(BrowserTheme.text)
		.background {
			// As the chat panel draws itself: the window's tint, a step lighter.
			ZStack {
				BrowserChromeBackground(textured: true)
				BrowserTheme.fill
			}
			.clipShape(.rect(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous))
			.shadow(color: .black.opacity(0.08), radius: 6, y: 2)
		}
		.overlay {
			RoundedRectangle(cornerRadius: BrowserMetrics.PageCard.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
		}
	}

	/// The list button, the centered title tile, and ⋯ with × sharing a tile.
	private func header(isSent: Bool) -> some View {
		HStack(spacing: 6) {
			TourRaisedIcon(symbol: "line.3.horizontal")
			Spacer(minLength: 0)
			HStack(spacing: 0) {
				TourRaisedIcon(symbol: "ellipsis", isGrouped: true)
				TourRaisedIcon(symbol: "xmark", isGrouped: true)
			}
			.padding(2)
			.background { ArxRaisedTile(cornerRadius: ArxControlShape.cornerRadius(forSide: 26)) }
		}
		.overlay {
			Group {
				if isSent {
					Text(localized: .appUI.onboarding.tour.sample.chats.summarize)
				} else {
					Text(localized: .appUI.chat.newChat)
				}
			}
			.font(.system(size: 10, weight: .semibold))
			.lineLimit(1)

			// Clear of the buttons on either side, as the panel's title tile stays.
			.frame(maxWidth: 62)
			.padding(.horizontal, 8)
			.frame(height: 24)
			.background { ArxRaisedTile(cornerRadius: ArxControlShape.cornerRadius(forSide: 24)) }
		}
		.padding(.horizontal, 10)
		.padding(.top, 8)
	}

	/// A new chat: suggestions by the composer, the first in the accent with a ›.
	private var suggestions: some View {
		VStack(alignment: .leading, spacing: 0) {
			Spacer(minLength: 0)
			Text(localized: .appUI.chat.suggestions)
				.font(.system(size: 10.5, weight: .semibold))
				.padding(.bottom, 2)
			row("text.alignleft", .appUI.onboarding.tour.sample.chats.summarize, isProminent: true)
				.opacity(isSuggestionPressed ? 0.55 : 1)
			row("list.bullet", .appUI.onboarding.tour.sample.chats.takeaways, isProminent: false)
			row("lightbulb", .appUI.onboarding.tour.sample.chats.explain, isProminent: false)
		}
		.padding(.horizontal, TourChatsLayout.horizontalPadding)
		.padding(.bottom, TourChatsLayout.bodyBottomPadding)
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func row(
		_ symbol: String,
		_ title: _XCStringResource,
		isProminent: Bool
	) -> some View {
		HStack(spacing: 7) {
			Image(systemName: symbol)
				.font(.system(size: 10, weight: .light))
				.frame(width: 14)
				.foregroundStyle(isProminent ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(BrowserTheme.secondary))
			Text(localized: title)
				.font(.system(size: 10.5))
				.lineLimit(1)
				.foregroundStyle(isProminent ? AnyShapeStyle(BrowserTheme.accent) : AnyShapeStyle(BrowserTheme.text))
			if isProminent {
				Image(systemName: "chevron.right")
					.font(.system(size: 7, weight: .semibold))
					.foregroundStyle(BrowserTheme.accent.opacity(0.6))
			}
			Spacer(minLength: 0)
		}
		.frame(height: TourChatsLayout.rowHeight)
	}

	/// A raised card: the placeholder, then + and send.
	private func composer(isSent: Bool) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Group {
				if isSent {
					Text(localized: .appUI.chat.composerFollowUp)
				} else {
					Text(localized: .appUI.chat.composerNew)
				}
			}
			.font(.system(size: 10.5))
			.foregroundStyle(BrowserTheme.secondary)
			.lineLimit(1)
			.padding(.horizontal, 3)
			.frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)

			HStack(spacing: 6) {
				TourRaisedIcon(symbol: "plus", side: 22)
				Spacer(minLength: 0)
				TourRaisedIcon(symbol: "arrow.up.circle.fill", side: 22, weight: .regular, size: 13)
					.foregroundStyle(BrowserTheme.secondary)
			}
		}
		.padding(8)
		.background { ArxRaisedTile(cornerRadius: 12) }
		.padding(.horizontal, 10)
		.padding(.top, 4)
		.padding(.bottom, 10)
	}
}

/// The person's message, the browser's work and the answer, streamed by the time.
private struct TourChatTranscript: View {
	internal let time: TimeInterval

	internal static let readingEnds: TimeInterval = 3.05
	internal static let streamStarts: TimeInterval = 3.15
	internal static let streamEnds: TimeInterval = 5.4

	internal var body: some View {
		let sentIn: CGFloat = TourTimeline.ease(time, from: TourChatPanel.sent, to: TourChatPanel.sent + 0.2)
		let toolsIn: CGFloat = TourTimeline.ease(time, from: TourChatPanel.sent + 0.25, to: TourChatPanel.sent + 0.4)
		let answer: String = String.localized(.appUI.onboarding.tour.sample.chats.answer)
		let streamed: String = TourTimeline.typed(answer, time, from: Self.streamStarts, to: Self.streamEnds)
		let isStreaming: Bool = time >= Self.streamStarts && time < Self.streamEnds

		VStack(alignment: .leading, spacing: 8) {
			Text(localized: .appUI.onboarding.tour.sample.chats.summarize)
				.font(.system(size: 10.5))
				.lineLimit(1)
				.padding(.horizontal, 9)
				.padding(.vertical, 6)
				.background { ArxRaisedTile(cornerRadius: 10) }
				.frame(maxWidth: .infinity, alignment: .trailing)
				.opacity(Double(sentIn))
				.offset(y: 6 * (1 - sentIn))

			tools
				.opacity(Double(toolsIn))

			if !streamed.isEmpty {
				Text("\(Text(verbatim: streamed))\(caret(isShown: isStreaming))")
					.font(.system(size: 10.5))
					.lineSpacing(2)
					.fixedSize(horizontal: false, vertical: true)
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, 2)
			}

			Spacer(minLength: 0)
		}
		.padding(.horizontal, 12)
		.padding(.top, 4)
	}

	/// The pale accent chip: what the browser is reading, then what it read.
	private var tools: some View {
		let isReading: Bool = time < Self.readingEnds

		return HStack(spacing: 5) {
			if isReading {
				Circle()
					.trim(from: 0, to: 0.7)
					.stroke(BrowserTheme.accent, style: .init(lineWidth: 1.4, lineCap: .round))
					.frame(width: 8, height: 8)
					.rotationEffect(.degrees(time * 360))
				Text(localized: .appUI.onboarding.tour.sample.chats.reading)
			} else {
				Image(systemName: "globe")
					.font(.system(size: 9))
				Text(localized: .appUI.onboarding.tour.sample.chats.read)
			}
		}
		.font(.system(size: 9.5, weight: .medium))
		.foregroundStyle(BrowserTheme.accent)
		.lineLimit(1)
		.padding(.horizontal, 7)
		.padding(.vertical, 4)
		.background(BrowserTheme.accent.opacity(0.1), in: .rect(cornerRadius: 6, style: .continuous))
	}

	private func caret(isShown: Bool) -> Text {
		guard isShown else { return Text(verbatim: "") }

		return Text(verbatim: " ●")
			.font(.system(size: 7))
			.foregroundStyle(BrowserTheme.accent)
	}
}

/// An icon on a raised tile, as `.arxRaised` draws a button at rest, without being a button.
private struct TourRaisedIcon: View {
	internal let symbol: String
	internal var isGrouped: Bool
	internal var side: CGFloat
	internal var weight: Font.Weight
	internal var size: CGFloat

	internal init(
		symbol: String,
		isGrouped: Bool = false,
		side: CGFloat = 26,
		weight: Font.Weight = .medium,
		size: CGFloat = 11
	) {
		self.symbol = symbol
		self.isGrouped = isGrouped
		self.side = side
		self.weight = weight
		self.size = size
	}

	internal var body: some View {
		Image(systemName: symbol)
			.font(.system(size: size, weight: weight))
			.frame(width: isGrouped ? side - 4 : side, height: isGrouped ? side - 4 : side)
			.background {
				if !isGrouped {
					ArxRaisedTile(cornerRadius: ArxControlShape.cornerRadius(forSide: side))
				}
			}
	}
}
