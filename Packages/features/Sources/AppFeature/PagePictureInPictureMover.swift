import AppKit
import Foundation

/// A window that moves as Page PiP does: Page PiP's own panel (DEV-1105), and Little Arx's while
/// it's in Page PiP (DEV-1112).
@MainActor
internal protocol PagePictureInPictureMoving: NSWindow {
	var pictureInPictureMover: PagePictureInPictureMover? { get }
}

/// Moves a window as Page PiP does (DEV-1105): a press-drag moves it 1:1, and on release it's
/// thrown to the corner its velocity carries it to (``PagePictureInPictureMotion``), settling there
/// on that screen's display link. After an edge resize, and when displays change, it settles back
/// to a corner. Call ``invalidate()`` before the window stops behaving as PiP or goes away.
@MainActor
internal final class PagePictureInPictureMover: NSObject {
	/// A settle towards a corner, driven by the target screen's display link.
	private final class Settle {
		internal let target: PagePictureInPictureMotion.Rest
		internal let spring: PagePictureInPictureMotion.Spring
		internal let start: CGVector
		internal var offset: CGVector
		internal var velocity: CGVector
		internal var elapsed: TimeInterval = 0
		internal var last: CFTimeInterval?
		internal var link: CADisplayLink?

		internal init(
			target: PagePictureInPictureMotion.Rest,
			spring: PagePictureInPictureMotion.Spring,
			offset: CGVector,
			velocity: CGVector
		) {
			self.target = target
			self.spring = spring
			self.start = offset
			self.offset = offset
			self.velocity = velocity
		}
	}

	private weak var window: NSWindow?

	/// The corner it rests at, or settles towards.
	internal private(set) var corner: PagePictureInPictureMotion.Corner
	private var settle: Settle?
	private var observers: [NSObjectProtocol] = []

	internal init(
		window: NSWindow,
		corner: PagePictureInPictureMotion.Corner
	) {
		self.window = window
		self.corner = corner
		super.init()
		observe(window)
	}

	/// Stops any settle and stops following resizes and displays.
	internal func invalidate() {
		stopSettling()
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		observers = []
	}

	private var screenAreas: [CGRect] { NSScreen.screens.map(\.visibleFrame) }

	private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

	/// Moves the window with a press-drag that started at `event`, 1:1, then throws it to a
	/// corner. A press without a move leaves it where it is. Returns once the button is up.
	/// `start` is where the press began, in screen coordinates, for a drag that took over from a
	/// control's press (DEV-1247) once the mouse had already moved; it's the mouse otherwise.
	internal func track(
		_ event: NSEvent,
		from start: CGPoint? = nil
	) {
		guard let window else { return }

		stopSettling()
		let startMouse = start ?? NSEvent.mouseLocation
		let startOrigin = window.frame.origin
		var samples: [PagePictureInPictureMotion.Sample] = [
			.init(position: .init(x: window.frame.midX, y: window.frame.midY), time: event.timestamp),
		]

		// A drag that took over from a control has already moved: the window catches up.
		var moved = start != nil
		if moved {
			let mouse = NSEvent.mouseLocation
			window.setFrameOrigin(.init(
				x: startOrigin.x + mouse.x - startMouse.x,
				y: startOrigin.y + mouse.y - startMouse.y
			))
		}
		while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
			let mouse = NSEvent.mouseLocation
			if next.type == .leftMouseUp {
				guard moved else { return }

				let velocity = PagePictureInPictureMotion.velocity(of: samples, at: next.timestamp)
				return settle(velocity: velocity)
			}
			moved = true
			window.setFrameOrigin(.init(
				x: startOrigin.x + mouse.x - startMouse.x,
				y: startOrigin.y + mouse.y - startMouse.y
			))
			samples.append(.init(position: .init(x: window.frame.midX, y: window.frame.midY), time: next.timestamp))

			// Only the last tenth of a second counts.
			samples.removeAll { next.timestamp - $0.time > PagePictureInPictureMotion.velocityWindow * 2 }
		}
	}

	/// Settles at the corner where `velocity` carries the window, with a slightly bouncy spring
	/// that starts at that velocity; with Reduce Motion, without bounce and from rest.
	internal func settle(velocity: CGVector) {
		guard
			let window,
			let target = PagePictureInPictureMotion.rest(for: window.frame, velocity: velocity, areas: screenAreas)
		else { return }

		settle(to: target, velocity: velocity)
	}

	/// Back to its corner on the screen it's on, or the nearest one, when displays change.
	private func resnap() {
		guard
			let window,
			let target = PagePictureInPictureMotion.rest(for: window.frame, at: corner, areas: screenAreas)
		else { return }

		settle(to: target, velocity: .zero)
	}

	private func observe(_ window: NSWindow) {
		let center = NotificationCenter.default
		observers = [
			center.addObserver(
				forName: NSWindow.didEndLiveResizeNotification,
				object: window,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.settle(velocity: .zero) }
			},
			center.addObserver(
				forName: NSApplication.didChangeScreenParametersNotification,
				object: nil,
				queue: .main
			) { [weak self] _ in
				MainActor.assumeIsolated { self?.resnap() }
			},
		]
	}

	private func settle(
		to target: PagePictureInPictureMotion.Rest,
		velocity: CGVector
	) {
		guard let window else { return }

		stopSettling()
		corner = target.corner
		PagePictureInPictureMotion.remember(target.corner)
		let offset = CGVector(dx: window.frame.minX - target.frame.minX, dy: window.frame.minY - target.frame.minY)
		guard abs(offset.dx) >= 0.5 || abs(offset.dy) >= 0.5 else {
			return window.setFrame(target.frame, display: true)
		}

		let reduceMotion = reduceMotion
		let settle = Settle(
			target: target,
			spring: reduceMotion ? .reducedMotion : .thrown,
			offset: offset,
			velocity: reduceMotion ? .zero : velocity
		)
		let screen = NSScreen.screens.first { $0.visibleFrame == target.area } ?? window.screen ?? NSScreen.main
		guard let link = screen?.displayLink(target: self, selector: #selector(step(_:))) else {
			return window.setFrame(target.frame, display: true)
		}

		settle.link = link
		self.settle = settle
		link.add(to: .main, forMode: .common)
	}

	@objc
	private func step(_ link: CADisplayLink) {
		guard let window, let settle, settle.link === link else { return link.invalidate() }

		let now = link.timestamp
		let dt = settle.last.map { min(now - $0, 1.0 / 30) } ?? 1.0 / 120
		settle.last = now
		settle.elapsed += dt
		settle.spring.step(offset: &settle.offset, velocity: &settle.velocity, dt: dt)
		PagePictureInPictureMotion.boundOvershoot(
			&settle.offset,
			velocity: &settle.velocity,
			from: settle.start,
			at: settle.target.corner
		)
		let isAtRest = abs(settle.offset.dx) < 0.5 && abs(settle.offset.dy) < 0.5
		&& abs(settle.velocity.dx) < 10 && abs(settle.velocity.dy) < 10

		// A settle that hasn't come to rest within three seconds finishes there.
		if isAtRest || settle.elapsed > 3 {
			stopSettling()
			window.setFrame(settle.target.frame, display: true)
			return
		}
		window.setFrameOrigin(.init(
			x: settle.target.frame.minX + settle.offset.dx,
			y: settle.target.frame.minY + settle.offset.dy
		))
	}

	private func stopSettling() {
		settle?.link?.invalidate()
		settle = nil
	}
}
