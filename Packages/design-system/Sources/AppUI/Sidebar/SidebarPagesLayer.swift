import AppKit
import SwiftUI

/// What the track moves when it moves part of the sidebar: a layer the render server slides.
///
/// The pages used to be offset by SwiftUI, a frame at a time on the main thread, so every frame
/// of a slide laid the window out again and whatever else the main thread was doing, a space
/// being selected above all, held the slide up (DEV-1310). The slides are one layer
/// moved by Core Animation, which no work in the app can hold up.
@MainActor
internal protocol SidebarTrackSurface: AnyObject {
	/// Shows what it carries where it belongs with the track at `position`, a track's
	/// `spacesPosition`, at once: under the fingers.
	func show(position: CGFloat)

	/// Plays it through `positions`, one every `interval` seconds from when the render server
	/// takes it, and holds the last: a landing, handed over whole.
	func play(
		positions: [CGFloat],
		every interval: TimeInterval
	)

	/// The track has come to rest at `position`: what it carries is laid out there for real,
	/// so clicks land where it's drawn.
	func rest(at position: CGFloat)
}

/// What a slid layer's content tells the pager across its own hosting view, which preferences
/// and layout don't cross.
@MainActor
@Observable
internal final class SidebarLayerBridge {
	/// Whether something in the layer has its hover preview open (`SidebarHoverPreviewOpen`).
	internal var isPreviewOpen: Bool

	/// The content's own height, for a layer as tall as what it holds.
	internal var height: CGFloat

	internal init() {
		self.isPreviewOpen = false
		self.height = 0
	}
}

/// A bridge for each of the pager's slid layers that needs one of its own.
@MainActor
internal final class SidebarLayerBridges {
	private var bridges: [UUID: SidebarLayerBridge] = [:]

	internal init() {}

	internal func bridge(for id: UUID) -> SidebarLayerBridge {
		if let bridge = bridges[id] { return bridge }
		let bridge = SidebarLayerBridge()
		bridges[id] = bridge
		return bridge
	}
}

/// Reports a layer's open hover preview to the views above the pager, as its content did when
/// it was in the window's own hosting view.
internal struct SidebarLayerPreviewRelay: View {
	private let bridge: SidebarLayerBridge

	internal init(bridge: SidebarLayerBridge) {
		self.bridge = bridge
	}

	internal var body: some View {
		Color.clear.preference(key: SidebarHoverPreviewOpen.self, value: bridge.isPreviewOpen)
	}
}

/// Gives a layer that is as tall as its content that height, read here so only this view
/// follows it.
internal struct SidebarLayerFittedFrame<Content: View>: View {
	private let bridge: SidebarLayerBridge
	private let width: CGFloat
	private let content: Content

	internal init(
		bridge: SidebarLayerBridge,
		width: CGFloat,
		@ViewBuilder content: () -> Content
	) {
		self.bridge = bridge
		self.width = width
		self.content = content()
	}

	internal var body: some View {
		content.frame(width: width, height: bridge.height, alignment: .topLeading)
	}
}

/// Part of the sidebar in a hosting view of its own, inside a view whose layer the track slides
/// (`SidebarTrackSurface`): the pager's row of pages, and each profile's Favorites.
///
/// The content is laid out once and never by a frame of a slide: under the fingers the track
/// sets one transform, and a landing is one keyframe animation the render server plays. The
/// content keeps the window's environment, handed across whole, and what it reports upward
/// goes through `SidebarLayerBridge`.
internal struct SidebarSlidLayer<Content: View>: NSViewRepresentable {
	/// How the layer's content is sized.
	internal enum Size: Equatable {
		/// A row this many pages wide, as tall as the layer.
		case pages(Int)

		/// One page wide and as tall as its content, up to this height. The content's own
		/// height comes back through the bridge.
		case fitted(limit: CGFloat)
	}

	private let driver: SidebarTrackDriver
	private let bridge: SidebarLayerBridge
	private let pageWidth: CGFloat
	private let size: Size
	private let offset: @MainActor (CGFloat) -> CGFloat
	private let content: Content

	/// - Parameters:
	///   - offset: Where the content sits, in pages from its place in the layer, with
	///     the track at a position: the pages go one page back for each space on; a profile's
	///     Favorites stay still through that profile's spaces and go with the pages past them.
	internal init(
		driver: SidebarTrackDriver,
		bridge: SidebarLayerBridge,
		pageWidth: CGFloat,
		size: Size,
		offset: @escaping @MainActor (CGFloat) -> CGFloat,
		@ViewBuilder content: () -> Content
	) {
		self.driver = driver
		self.bridge = bridge
		self.pageWidth = pageWidth
		self.size = size
		self.offset = offset
		self.content = content()
	}

	internal func makeNSView(context: Context) -> SidebarSlidLayerView {
		.init()
	}

	internal func updateNSView(
		_ view: SidebarSlidLayerView,
		context: Context
	) {
		let environment: EnvironmentValues = context.environment
		let isFitted: Bool = if case .fitted = size { true } else { false }
		view.host.rootView = AnyView(
			content
				.fixedSize(horizontal: false, vertical: isFitted)
				.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [bridge] height in
					if isFitted, bridge.height != height { bridge.height = height }
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
				.onPreferenceChange(SidebarHoverPreviewOpen.self) { [bridge] isOpen in
					if bridge.isPreviewOpen != isOpen { bridge.isPreviewOpen = isOpen }
				}
				.transformEnvironment(\.self) { $0 = environment }
		)
		view.configure(
			pageWidth: pageWidth,
			size: size,
			offset: offset,
			position: driver.spacesPosition
		)
		view.landingBegan = { [weak driver] in driver?.landingBegan() }
		driver.attach(view)
	}
}

internal final class SidebarSlidLayerView: NSView, SidebarTrackSurface, CAAnimationDelegate {
	private static let slideKey: String = "sidebarTrackSlide"

	internal let host: NSHostingView<AnyView>

	/// Called when the render server takes a landing, for the track to keep its clock.
	internal var landingBegan: (() -> Void)?
	private var pageWidth: CGFloat = 0
	private var size: SidebarSlidLayer<EmptyView>.Size = .pages(1)
	private var offset: @MainActor (CGFloat) -> CGFloat = { _ in 0 }

	/// Where the content is laid out, as a track position. A slide moves the layer away from
	/// there and ends by laying the content out where the slide ended.
	private var restingPosition: CGFloat = 0
	private var isSliding: Bool = false

	internal init() {
		self.host = .init(rootView: AnyView(EmptyView()))
		super.init(frame: .zero)
		wantsLayer = true
		host.sizingOptions = []
		host.safeAreaRegions = []
		host.autoresizingMask = []
		addSubview(host)
	}

	@available(*, unavailable)
	internal required init?(coder: NSCoder) {
		fatalError("init(coder:) is unavailable")
	}

	internal override var isFlipped: Bool { true }

	internal override func layout() {
		super.layout()
		place()
	}

	internal func configure<Content: View>(
		pageWidth: CGFloat,
		size: SidebarSlidLayer<Content>.Size,
		offset: @escaping @MainActor (CGFloat) -> CGFloat,
		position: CGFloat
	) {
		let erased: SidebarSlidLayer<EmptyView>.Size = switch size {
		case let .pages(count): .pages(count)
		case let .fitted(limit): .fitted(limit: limit)
		}
		let changed: Bool = self.pageWidth != pageWidth || self.size != erased
		self.pageWidth = pageWidth
		self.size = erased
		self.offset = offset

		// The pages clip to the sidebar; Favorites are as tall as they are and clip nothing.
		if case .pages = erased { clipsToBounds = true } else { clipsToBounds = false }

		// A new width or size moves everything: lay it out where the track stands.
		if !isSliding { restingPosition = position }
		if changed || !isSliding { place() }
	}

	private func place() {
		let width: CGFloat
		let height: CGFloat
		switch size {
		case let .pages(count):
			width = CGFloat(max(count, 1)) * pageWidth
			height = bounds.height
		case let .fitted(limit):
			width = pageWidth
			height = max(limit, bounds.height)
		}
		let frame = CGRect(x: offset(restingPosition) * pageWidth, y: 0, width: width, height: height)
		if host.frame != frame { host.frame = frame }
	}

	/// How far the layer is from where its content is laid out, with the track at `position`.
	private func slide(to position: CGFloat) -> CGFloat {
		(offset(position) - offset(restingPosition)) * pageWidth
	}

	private func withoutActions(_ change: () -> Void) {
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		change()
		CATransaction.commit()
	}

	internal func show(position: CGFloat) {
		isSliding = true
		withoutActions {
			layer?.removeAnimation(forKey: Self.slideKey)
			layer?.sublayerTransform = CATransform3DMakeTranslation(slide(to: position), 0, 0)
		}
	}

	internal func play(
		positions: [CGFloat],
		every interval: TimeInterval
	) {
		guard
			let layer,
			let last = positions.last,
			positions.count > 1
		else {
			if let last = positions.last { show(position: last) }
			return
		}
		isSliding = true

		// It begins when the render server takes it, not when the track set out: the update
		// that hands it over can hold this thread for frames, and an animation timed from
		// before that would open already part of the way along.
		let animation = CAKeyframeAnimation(keyPath: "sublayerTransform.translation.x")
		animation.values = positions.map { slide(to: $0) }
		animation.calculationMode = .linear
		animation.duration = interval * Double(positions.count - 1)
		animation.fillMode = .both
		animation.isRemovedOnCompletion = false
		animation.delegate = self
		withoutActions {
			layer.sublayerTransform = CATransform3DMakeTranslation(slide(to: last), 0, 0)
			layer.add(animation, forKey: Self.slideKey)
		}
	}

	internal func rest(at position: CGFloat) {
		isSliding = false
		withoutActions {
			layer?.removeAnimation(forKey: Self.slideKey)
			layer?.sublayerTransform = CATransform3DIdentity
			restingPosition = position
			place()
		}
	}

	internal nonisolated func animationDidStart(_ animation: CAAnimation) {
		MainActor.assumeIsolated { landingBegan?() }
	}
}
