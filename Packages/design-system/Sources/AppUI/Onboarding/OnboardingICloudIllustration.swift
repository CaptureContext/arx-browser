import SwiftUI

/// Two Macs around iCloud, from the Figma "iCloud Sync Illustration" (460 × 230): this Mac
/// shows its Arx window, and the other one fills in as sync brings it over.
///
/// - `ready`: the other Mac's window is empty.
/// - `syncing`: tabs travel along the dashed paths, iCloud breathes, and the other Mac fills
///   in a tab at a time. It loops on a `TimelineView`, which holds still under Reduce Motion
///   on a frame that shows the same thing.
/// - `done`: both windows match and a check appears on iCloud.
///
/// Every value is computed from the time since syncing began, so a frame never depends on the
/// frames before it. VoiceOver reads it as one image.
public struct OnboardingICloudIllustration: View {
	public enum Phase: Equatable, Sendable {
		case ready
		case syncing
		case done
	}

	public static let size: CGSize = .init(width: 460, height: 230)

	public let phase: Phase

	/// Holds `syncing` this long after it began, for snapshots.
	internal let frozenElapsed: TimeInterval?

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	/// When syncing began, for the fill-in and the loop.
	@SwiftUI.State
	private var syncStart: Date

	@SwiftUI.State
	private var showsCheck: Bool

	public init(phase: Phase) {
		self.init(phase: phase, frozenElapsed: nil)
	}

	internal init(
		phase: Phase,
		frozenElapsed: TimeInterval?
	) {
		self.phase = phase
		self.frozenElapsed = frozenElapsed
		self._syncStart = .init(initialValue: .now)
		self._showsCheck = .init(initialValue: phase == .done)
	}

	public var body: some View {
		TimelineView(.animation(paused: phase != .syncing || reduceMotion || frozenElapsed != nil)) { context in
			ICloudSyncScene(
				frame: frame(at: context.date),
				showsCheck: showsCheck
			)
		}
		.frame(width: Self.size.width, height: Self.size.height)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onChange(of: phase) { _, phase in
			if phase == .syncing { syncStart = .now }
			withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.45)) {
				showsCheck = phase == .done
			}
		}
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(localized: .appUI.onboarding.iCloud.illustration))
		.accessibilityAddTraits(.isImage)
	}

	private func frame(at date: Date) -> ICloudSyncFrame {
		switch phase {
		case .ready:
			.ready

		case .done:
			.done

		case .syncing where reduceMotion:
			.syncing(elapsed: ICloudSyncFrame.fillDuration / 2, loopTime: ICloudSyncFrame.loopDuration * 0.3)

		case .syncing:
			.syncing(
				elapsed: frozenElapsed ?? date.timeIntervalSince(syncStart),
				loopTime: (frozenElapsed ?? date.timeIntervalSince(syncStart))
					.truncatingRemainder(dividingBy: ICloudSyncFrame.loopDuration)
			)
		}
	}
}

// MARK: - Frame

/// Everything that moves, for one moment.
private struct ICloudSyncFrame {
	/// How long the other Mac takes to fill in once syncing begins.
	static let fillDuration: TimeInterval = 2

	/// One trip of a tab from this Mac to iCloud and on to the other Mac.
	static let loopDuration: TimeInterval = 1.6

	/// The other Mac's tabs shown so far, 0 to 4; each fades in over one unit.
	var tabs: CGFloat

	var pageOpacity: CGFloat
	var spaceOpacity: CGFloat
	var pathOpacity: CGFloat
	var dashPhase: CGFloat
	var cloudScale: CGFloat
	var glowOpacity: CGFloat

	/// Where along the first and the second path a travelling tab is, with its opacity.
	var outbound: (progress: CGFloat, opacity: CGFloat)
	var inbound: (progress: CGFloat, opacity: CGFloat)

	/// The paths are faint until sync starts and stay drawn once it's done, as the Figma
	/// component's Ready (25%) and Done (60%) states (DEV-1300).
	static let ready: Self = .init(
		tabs: 0,
		pageOpacity: 0.35,
		spaceOpacity: 0,
		pathOpacity: 0.25,
		dashPhase: 0,
		cloudScale: 1,
		glowOpacity: 0.55,
		outbound: (0, 0),
		inbound: (0, 0)
	)

	static let done: Self = .init(
		tabs: 4,
		pageOpacity: 1,
		spaceOpacity: 1,
		pathOpacity: 0.6,
		dashPhase: 0,
		cloudScale: 1,
		glowOpacity: 0.55,
		outbound: (0, 0),
		inbound: (0, 0)
	)

	static func syncing(
		elapsed: TimeInterval,
		loopTime: TimeInterval
	) -> Self {
		let breath: CGFloat = (1 - cos(2 * .pi * loopTime / loopDuration)) / 2
		let half: TimeInterval = loopDuration / 2
		return .init(
			tabs: 4 * TourTimeline.linear(elapsed, from: 0.3, to: fillDuration),
			pageOpacity: TourTimeline.mix(0.35, 1, TourTimeline.ease(elapsed, from: 0, to: fillDuration)),
			spaceOpacity: TourTimeline.ease(elapsed, from: 0.3, to: 0.7),
			pathOpacity: TourTimeline.mix(0.25, 0.8, TourTimeline.ease(elapsed, from: 0, to: 0.3)),
			dashPhase: -16 * CGFloat(loopTime / loopDuration),
			cloudScale: 1 + 0.05 * breath,
			glowOpacity: 0.55 + 0.45 * breath,
			outbound: trip(loopTime, from: 0, to: half - 0.07),
			inbound: trip(loopTime, from: half, to: loopDuration - 0.07)
		)
	}

	private static func trip(
		_ time: TimeInterval,
		from start: TimeInterval,
		to end: TimeInterval
	) -> (progress: CGFloat, opacity: CGFloat) {
		(TourTimeline.linear(time, from: start, to: end), TourTimeline.window(time, in: start...end, fade: 0.13))
	}
}

// MARK: - Scene

/// The drawing, in the Figma component's 460 × 230 points.
private struct ICloudSyncScene: View {
	let frame: ICloudSyncFrame
	let showsCheck: Bool

	/// From this Mac's screen up to iCloud, and from iCloud down to the other Mac's.
	static let outboundPath: (CGPoint, CGPoint, CGPoint) = (.init(x: 120, y: 70), .init(x: 150, y: 30), .init(x: 190, y: 52))
	static let inboundPath: (CGPoint, CGPoint, CGPoint) = (.init(x: 270, y: 52), .init(x: 310, y: 30), .init(x: 340, y: 70))

	var body: some View {
		ZStack(alignment: .topLeading) {
			ICloudSyncMac(tabs: 4, pageOpacity: 1, spaceOpacity: 1)
				.offset(x: 0, y: 70)

			ICloudSyncMac(tabs: frame.tabs, pageOpacity: frame.pageOpacity, spaceOpacity: frame.spaceOpacity)
				.offset(x: 290, y: 70)

			path(Self.outboundPath)
			path(Self.inboundPath)

			Circle()
				.fill(
					RadialGradient(
						colors: [Color(red: 0.36, green: 0.66, blue: 1).opacity(0.32), .clear],
						center: .center,
						startRadius: 0,
						endRadius: 75
					)
				)
				.frame(width: 150, height: 150)
				.opacity(frame.glowOpacity)
				.position(x: 230, y: 63)

			Image(systemName: "icloud.fill")
				.font(.system(size: 78, weight: .regular))
				.foregroundStyle(
					LinearGradient(
						colors: [
							.init(red: 0.42, green: 0.74, blue: 1),
							.init(red: 0.1, green: 0.48, blue: 0.96),
						],
						startPoint: .top,
						endPoint: .bottom
					)
				)
				.shadow(color: .init(red: 0.1, green: 0.4, blue: 0.9).opacity(0.3), radius: 7, y: 6)
				.scaleEffect(frame.cloudScale)
				.position(x: 230, y: 57)

			packet(.tracker, on: Self.outboundPath, at: frame.outbound)
			packet(.docs, on: Self.inboundPath, at: frame.inbound)

			Image(systemName: "checkmark.circle.fill")
				.font(.system(size: 22, weight: .semibold))
				.symbolRenderingMode(.palette)
				.foregroundStyle(.white, Color(red: 0.2, green: 0.78, blue: 0.35))
				.background(Circle().fill(.white).padding(-2))
				.scaleEffect(showsCheck ? 1 : 0.01)
				.opacity(showsCheck ? 1 : 0)
				.position(x: 266, y: 72)
		}
		.frame(width: OnboardingICloudIllustration.size.width, height: OnboardingICloudIllustration.size.height, alignment: .topLeading)
	}

	private func path(_ points: (CGPoint, CGPoint, CGPoint)) -> some View {
		Path { path in
			path.move(to: points.0)
			path.addQuadCurve(to: points.2, control: points.1)
		}
		.stroke(
			Color(red: 0.2, green: 0.55, blue: 0.98),
			style: .init(lineWidth: 2, lineCap: .round, dash: [2, 6], dashPhase: frame.dashPhase)
		)
		.opacity(frame.pathOpacity)
	}

	private func packet(
		_ glyph: TourSiteGlyph,
		on points: (CGPoint, CGPoint, CGPoint),
		at position: (progress: CGFloat, opacity: CGFloat)
	) -> some View {
		let t: CGFloat = position.progress
		let point: CGPoint = .init(
			x: (1 - t) * (1 - t) * points.0.x + 2 * t * (1 - t) * points.1.x + t * t * points.2.x,
			y: (1 - t) * (1 - t) * points.0.y + 2 * t * (1 - t) * points.1.y + t * t * points.2.y
		)
		return TourSiteGlyphView(glyph: glyph, size: 16)
			.shadow(color: .black.opacity(0.2), radius: 2, y: 2)
			.opacity(position.opacity)
			.position(point)
	}
}

// MARK: - Mac

/// A laptop showing a small Arx window: a sidebar of four tabs and a page. Its screen is
/// always light, as a picture of a Mac is, in either appearance.
private struct ICloudSyncMac: View {
	/// Tabs shown, 0 to 4; each fades in over one unit.
	let tabs: CGFloat
	let pageOpacity: CGFloat
	let spaceOpacity: CGFloat

	private static let glyphs: [TourSiteGlyph] = [.tracker, .docs, .code, .notes]

	var body: some View {
		ZStack(alignment: .topLeading) {
			Ellipse()
				.fill(.black.opacity(0.12))
				.frame(width: 150, height: 10)
				.blur(radius: 3)
				.offset(x: 10, y: 105)

			RoundedRectangle(cornerRadius: 4, style: .continuous)
				.fill(
					LinearGradient(
						colors: [Color(white: 0.82), Color(white: 0.6)],
						startPoint: .top,
						endPoint: .bottom
					)
				)
				.overlay(alignment: .top) {
					Capsule()
						.fill(.black.opacity(0.15))
						.frame(width: 30, height: 3)
				}
				.frame(width: 170, height: 8)
				.offset(y: 100)

			// The rim keeps the bezel apart from a dark window behind it.
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.fill(Color(red: 0.16, green: 0.16, blue: 0.18))
				.overlay {
					RoundedRectangle(cornerRadius: 10, style: .continuous)
						.strokeBorder(.white.opacity(0.14), lineWidth: 0.75)
				}
				.frame(width: 150, height: 100)
				.offset(x: 10)

			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.fill(
					LinearGradient(
						colors: [
							.init(red: 0.82, green: 0.86, blue: 0.98),
							.init(red: 0.93, green: 0.88, blue: 0.96),
						],
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					)
				)
				.frame(width: 140, height: 90)
				.offset(x: 15, y: 5)

			window
				.offset(x: 27, y: 14)
		}
		.frame(width: 170, height: 124, alignment: .topLeading)
	}

	private var window: some View {
		ZStack(alignment: .topLeading) {
			RoundedRectangle(cornerRadius: 5, style: .continuous)
				.fill(Color(red: 0.93, green: 0.92, blue: 0.95))
				.frame(width: 116, height: 72)
				.shadow(color: .black.opacity(0.15), radius: 2.5, y: 2)

			HStack(spacing: 1.5) {
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
						.frame(width: 3, height: 3)
				}
			}
			.offset(x: 4, y: 4)

			ForEach(Self.glyphs.indices, id: \.self) { index in
				tab(index)
					.opacity(Double(min(1, max(0, tabs - CGFloat(index)))))
					.offset(x: 2, y: 13 + CGFloat(index) * 11)
			}

			page
				.opacity(pageOpacity)
				.offset(x: 39, y: 3)

			Rectangle()
				.fill(Color(red: 0.43, green: 0.36, blue: 0.93))
				.frame(width: 38, height: 2)
				.opacity(spaceOpacity)
				.offset(y: 70)
		}
		.frame(width: 116, height: 72, alignment: .topLeading)
		.clipShape(.rect(cornerRadius: 5, style: .continuous))
	}

	private func tab(_ index: Int) -> some View {
		HStack(spacing: 3) {
			TourSiteGlyphView(glyph: Self.glyphs[index], size: 6)
			Capsule()
				.fill(.black.opacity(0.25))
				.frame(width: index.isMultiple(of: 2) ? 18 : 13, height: 2.5)
		}
		.padding(.leading, 2)
		.frame(width: 34, height: 9, alignment: .leading)
		.background {
			if index == 0 {
				RoundedRectangle(cornerRadius: 3, style: .continuous)
					.fill(.white.opacity(0.9))
			}
		}
	}

	private var page: some View {
		VStack(alignment: .leading, spacing: 3.5) {
			Capsule()
				.fill(.black.opacity(0.7))
				.frame(width: 34, height: 4)
				.padding(.bottom, 2.5)

			ForEach(0..<3, id: \.self) { line in
				Capsule()
					.fill(.black.opacity(0.15))
					.frame(width: 60 - CGFloat(line) * 12, height: 2.5)
			}
		}
		.padding(6)
		.padding(.top, 2)
		.frame(width: 74, height: 66, alignment: .topLeading)
		.background(Color(red: 0.99, green: 0.98, blue: 1), in: .rect(cornerRadius: 3, style: .continuous))
	}
}
