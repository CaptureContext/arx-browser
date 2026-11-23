import AppUI
import BrowserCaptureClient
import BrowserCore
import BrowserPageInspectionClient
import CoreGraphics
import Foundation
import SoundFeedbackClient
import _ComposableArchitecture

/// Placement identity survives focus changes and never resolves through the current key window.
public struct CaptureSource: Equatable, Sendable {
	public enum Host: Equatable, Sendable {
		case pane(windowID: UUID, paneID: UUID)
		case little(UUID)
		case peek(UUID)
	}

	public var host: Host
	public var tabID: BrowserCore.Tab.ID
	public var profileID: Profile.ID
	public var spaceID: Space.ID

	public init(
		host: Host,
		tabID: BrowserCore.Tab.ID,
		profileID: Profile.ID,
		spaceID: Space.ID
	) {
		self.host = host
		self.tabID = tabID
		self.profileID = profileID
		self.spaceID = spaceID
	}
}

/// Capturing on the page itself: the page dims, the pointer picks a block or draws an
/// area, and the captured frame stays on the page with a menu beside it.
///
/// The host resolves a fresh session revision (`prepared`) and draws the overlay above
/// the page's surface. Everything here is in viewport points with a top-left origin.
@Reducer
public struct PageCaptureFeature {
	@ObservableState
	public struct State: Equatable, Identifiable {
		/// Also the authorization identity the host checks before pixels are read.
		public var id: UUID
		public var source: CaptureSource
		public var title: String
		public var mode: Mode
		public var sourceGeneration: Int
		public var phase: Phase

		/// The host's in-flight preparation, while it resolves a fresh revision.
		public var preparation: UUID?
		public var request: PageCaptureRequest?

		/// Reads node bounds for picking; nil when the page has no loaded document.
		public var inspection: PageInspectionSource?

		/// The overlay's own extent.
		public var viewport: PageCaptureRegion

		/// Every pickable node the engine reported, before the page-sized ones are dropped.
		public var candidates: [PageCaptureTarget]
		public var targets: [PageCaptureTarget]
		public var highlighted: PageCaptureTarget?
		public var drag: PageCaptureRegion?

		/// The captured frame on the page.
		public var selection: PageCaptureRegion?
		public var frame: PageCaptureFrame?
		public var image: PageCaptureImage?
		public var isFullPage: Bool

		/// Whether the engine can capture the whole document, for the menu's Capture Full Page.
		public var fullPageAvailable: Bool

		/// Whether the engine renders whole pages beyond the viewport (DEV-1172), which Capture Page
		/// and Capture Full Page take over ABI16's recorded document.
		public var wholePageAvailable: Bool

		/// Whether the engine records the whole document (ABI16), what a failed whole page falls
		/// back to before the visible area.
		public var documentAvailable: Bool

		/// Why Capture Page took the visible area instead of the whole page, for the menu's note.
		public var visibleAreaReason: PageCaptureFailure?
		public var showsProtectedMediaNote: Bool
		public var generation: Int
		public var inspectionGeneration: Int
		public var staleRetries: Int
		public var isWorking: Bool
		public var message: String?

		/// Whether the host can attach the capture to a chat: Send to Chat in the menu (DEV-798).
		public var allowsSendingToChat: Bool

		/// Where the capture goes once it's taken.
		public var destination: Destination

		/// The developer header's device capture (DEV-757): the image is framed as a device on
		/// a gradient, and Portrait Mode captures a phone-shaped slice of the visible page.
		public var framing: DeviceCaptureStyle?

		/// The `ARX_CAPTURE_BEYOND_VIEWPORT` feature flag (DEV-1208): the captured frame shows
		/// everything the image holds, and drawing an area toward an edge scrolls the page.
		public var capturesBeyondViewport: Bool

		/// Whether drawing an area scrolls the page near its edges (DEV-1208): the flag, with the
		/// engine's whole page beyond the viewport and its scrolling, until a scroll fails.
		public var autoscrollAvailable: Bool

		/// The area being drawn while the page may scroll under it (DEV-1208).
		public var drawing: PageCaptureDrawing?

		/// Tells a late scroll from an earlier drawing apart.
		public var drawingGeneration: Int

		/// Where a drag began whose drawing was dropped after a lost scroll: the rest of that drag,
		/// its release included, does nothing (DEV-1208).
		public var droppedDragStart: CGPoint?

		public init(
			id: UUID,
			source: CaptureSource,
			title: String,
			mode: Mode,
			sourceGeneration: Int,
			phase: Phase = .preparing,
			preparation: UUID? = nil,
			request: PageCaptureRequest? = nil,
			inspection: PageInspectionSource? = nil,
			viewport: PageCaptureRegion = .init(x: 0, y: 0, width: 0, height: 0),
			candidates: [PageCaptureTarget] = [],
			targets: [PageCaptureTarget] = [],
			highlighted: PageCaptureTarget? = nil,
			drag: PageCaptureRegion? = nil,
			selection: PageCaptureRegion? = nil,
			frame: PageCaptureFrame? = nil,
			image: PageCaptureImage? = nil,
			isFullPage: Bool = false,
			fullPageAvailable: Bool = false,
			wholePageAvailable: Bool = false,
			documentAvailable: Bool = false,
			visibleAreaReason: PageCaptureFailure? = nil,
			showsProtectedMediaNote: Bool = false,
			generation: Int = 0,
			inspectionGeneration: Int = 0,
			staleRetries: Int = 0,
			isWorking: Bool = false,
			message: String? = nil,
			allowsSendingToChat: Bool = false,
			destination: Destination = .menu,
			framing: DeviceCaptureStyle? = nil,
			capturesBeyondViewport: Bool = false,
			autoscrollAvailable: Bool = false,
			drawing: PageCaptureDrawing? = nil,
			drawingGeneration: Int = 0,
			droppedDragStart: CGPoint? = nil
		) {
			self.id = id
			self.source = source
			self.title = title
			self.mode = mode
			self.sourceGeneration = sourceGeneration
			self.phase = phase
			self.preparation = preparation
			self.request = request
			self.inspection = inspection
			self.viewport = viewport
			self.candidates = candidates
			self.targets = targets
			self.highlighted = highlighted
			self.drag = drag
			self.selection = selection
			self.frame = frame
			self.image = image
			self.isFullPage = isFullPage
			self.fullPageAvailable = fullPageAvailable
			self.wholePageAvailable = wholePageAvailable
			self.documentAvailable = documentAvailable
			self.visibleAreaReason = visibleAreaReason
			self.showsProtectedMediaNote = showsProtectedMediaNote
			self.generation = generation
			self.inspectionGeneration = inspectionGeneration
			self.staleRetries = staleRetries
			self.isWorking = isWorking
			self.message = message
			self.allowsSendingToChat = allowsSendingToChat
			self.destination = destination
			self.framing = framing
			self.capturesBeyondViewport = capturesBeyondViewport
			self.autoscrollAvailable = autoscrollAvailable
			self.drawing = drawing
			self.drawingGeneration = drawingGeneration
			self.droppedDragStart = droppedDragStart
		}

		/// Clears everything a capture produced, ready to pick again.
		public mutating func reset() {
			phase = .preparing
			request = nil
			inspection = nil
			candidates = []
			targets = []
			highlighted = nil
			drag = nil
			drawing = nil
			droppedDragStart = nil
			selection = nil
			frame = nil
			image = nil
			isFullPage = false
			visibleAreaReason = nil
			showsProtectedMediaNote = false
			isWorking = false
			message = nil
		}

		/// The frame menu's note: the latest failure, else why a Capture Page frame holds only the
		/// visible area, else where a whole page was cut. Those stay while the frame does, so
		/// canceling Save keeps them.
		public var menuMessage: String? {
			message
			?? visibleAreaReason.map(PageCapturePresentation.visibleAreaMessage(for:))
			?? cutPoints.map(PageCapturePresentation.cutMessage(points:))
		}

		/// How many points of a whole page cut at the capture's limits the image holds (DEV-1172).
		public var cutPoints: Int? {
			guard
				isFullPage,
				let frame,
				frame.isCut,
				frame.deviceScale > 0
			else { return nil }

			return Int((Double(frame.image.height) / frame.deviceScale).rounded(.down))
		}

		/// The whole page: rendered beyond the viewport when the engine can (DEV-1172), else
		/// ABI16's recorded document.
		fileprivate mutating func requestWholePage() {
			let beyondViewport = wholePageAvailable
			isFullPage = true
			request?.mode = .fullDocument
			request?.beyondViewport = beyondViewport
			request?.limits = beyondViewport ? .wholePage : .init()
		}

		/// An area reaching beyond the viewport (DEV-1208): it's cut from the whole page, rendered
		/// beyond the viewport.
		fileprivate mutating func requestArea() {
			isFullPage = false
			request?.mode = .fullDocument
			request?.beyondViewport = true
			request?.limits = .wholePage
		}

		/// Back to the viewport, for a pick or the visible area.
		fileprivate mutating func requestViewport() {
			isFullPage = false
			request?.mode = .viewport
			request?.beyondViewport = false
			request?.limits = .init()
		}
	}

	public enum Mode: Equatable, Sendable {
		/// Capture Area…: pick a block or draw an area.
		case area

		/// The visible area, straight away: a chat's capture and device capture.
		case visible

		/// Capture Page…: the whole page straight away, within the document capture's limits. A page
		/// the engine can't capture whole gets its visible area, with a note saying why.
		case page
	}

	public enum Destination: Equatable, Sendable {
		/// The frame stays on the page with its menu.
		case menu

		/// Captured from a chat's + menu: the capture goes straight to the chat (DEV-798).
		case chat
	}

	public enum Phase: Equatable, Sendable {
		case preparing
		case selecting
		case capturing
		case captured
	}

	@CasePathable
	public enum Action: Sendable {
		/// The host resolved `request` (and `inspection`, when it can) for the live page.
		case prepared
		case inspect
		case capture(PageCaptureRegion?)
		case ui(UI)
		case event(Event)
		case delegate(Delegate)
		case observation(ObservationAction<Observation>)

		@CasePathable
		public enum UI: Sendable {
			case viewportChanged(CGSize)
			case pointerMoved(CGPoint)
			case dragChanged(from: CGPoint, to: CGPoint)
			case dragEnded(from: CGPoint, to: CGPoint)
			case clicked(CGPoint)
			case scrolled
			case move(PageCaptureMovement)
			case commit
			case cancel
			case copy
			case save
			case edit

			/// Send to Chat: attaches the capture to the window's chat and ends the capture.
			case sendToChat
			case retake
			case captureFullPage
		}

		@CasePathable
		public enum Event: Sendable {
			case inspected(Int, [PageCaptureTarget])
			case inspectionFailed(Int, isStale: Bool)
			case captured(Int, PageCaptureFrame, PageCaptureImage, PageCaptureRegion)
			case failed(Int, String, isStale: Bool)

			/// Capture Page couldn't take the whole page, so it takes the visible area.
			case wholePageFailed(Int, PageCaptureFailure)
			case mediaChecked(Int, Bool)

			/// Time to scroll the page again while an area is drawn toward its edge (DEV-1208).
			case autoscrollTick(Int)

			/// How far the page moved for the drawing's last scroll.
			case autoscrolled(Int, PageCaptureOffset)

			/// A scroll failed. Unless it never ran (busy or unavailable), the page may have moved anyway.
			case autoscrollFailed(Int, mayHaveMoved: Bool)
			case finished(Int)
			case saved(Int, URL?)
		}

		@CasePathable
		public enum Delegate: Sendable {
			case dismiss

			/// Asks the host for a fresh revision of the same page.
			case retake

			/// The host attaches the capture to the chat of the page's window (DEV-798).
			case sendToChat(PageCaptureImage, title: String)
		}

		@CasePathable
		public enum Observation: Equatable, Sendable {}
	}

	/// The most nodes a pick reads, in windows the engine accepts.
	public static let maximumInspectedNodes: Int = 2_048
	public static let inspectionWindow: Int = 128

	/// How long scrolling must settle before node bounds are read again.
	public static let scrollSettleDelay: Duration = .milliseconds(180)

	/// How often the page scrolls while an area is drawn toward its edge (DEV-1208).
	public static let autoscrollInterval: Duration = .milliseconds(16)

	/// The most ticks one scroll makes up for while the one before it was still out.
	public static let maximumAutoscrollTicks: Int = 6

	/// How many times a capture of a page that changed under the overlay is taken again.
	public static let maximumStaleRetries: Int = 2

	@Dependency(\.browserCapture)
	private var captureClient

	@Dependency(\.continuousClock)
	private var clock

	@Dependency(\.pageCaptureAuthorization)
	private var authorization

	@Dependency(\.pageCaptureExport)
	private var exportClient

	@Dependency(\.pageCaptureInspection)
	private var inspectionClient

	@Dependency(\.soundFeedback)
	private var soundFeedback

	fileprivate static let mediaCancellation: Cancellation = .media

	fileprivate enum Cancellation: Hashable {
		case capture
		case inspection
		case settle
		case export
		case media
		case autoscroll
		case scroll
	}

	public init() {}

	public var body: some ReducerOf<Self> {
		Pullback(\.prepared) { state in
			guard state.request != nil else { return .none }

			state.preparation = nil
			state.message = nil
			let (wholePage, document, scroll) = MainActor.assumeIsolated { [captureClient] in
				(
					captureClient.wholePageIsAvailable(),
					captureClient.fullDocumentIsAvailable(),
					captureClient.scrollIsAvailable()
				)
			}
			state.wholePageAvailable = wholePage
			state.documentAvailable = document
			state.fullPageAvailable = wholePage || document
			state.autoscrollAvailable = state.capturesBeyondViewport && wholePage && scroll
			switch state.mode {
			case .area:
				state.phase = .selecting
				return .send(.inspect)

			case .visible:
				return .merge(.send(.capture(nil)), .send(.inspect))

			case .page:
				if state.fullPageAvailable { state.requestWholePage() }
				return .merge(.send(.capture(nil)), .send(.inspect))
			}
		}

		Pullback(\.inspect) { state in
			state.inspectionGeneration += 1
			guard
				let request = state.request,
				let source = state.inspection
			else { return .cancel(id: Cancellation.inspection) }

			let generation = state.inspectionGeneration
			let id = state.id
			let inspection: Effect<Action> = .run { [authorization, inspectionClient] send in
				do {
					guard await inspectionClient.isAvailable(), await authorization.authorize(id, request)
					else { throw AutomationFailure.unsupported }

					var nodes: [PageInspectionNode] = []
					var start = 0
					var total = Int.max
					while start < min(total, Self.maximumInspectedNodes) {
						let snapshot = try await inspectionClient.inspectAuthorized(
							.init(
								targetID: source.tabID.rawValue,
								expectedRevision: Self.inspectionRevision,
								maximumNodes: Self.inspectionWindow,
								maximumTextBytes: 65_536,
								windowStart: start,
								includesBounds: true
							),
							source,
							{ authorization.authorize(id, request) }
						)
						try Task.checkCancellation()
						nodes += snapshot.nodes
						total = snapshot.totalNodes
						guard !snapshot.nodes.isEmpty else { break }

						start = snapshot.windowStart + snapshot.nodes.count
					}

					await inspectionClient.revokeScope(source.scopeID)
					await send(.event(.inspected(generation, PageCaptureGeometry.candidates(from: nodes))))
				} catch is CancellationError {
					// A newer read or the capture ending superseded this one.
					await inspectionClient.revokeScope(source.scopeID)
				} catch {
					await inspectionClient.revokeScope(source.scopeID)
					await send(.event(.inspectionFailed(
						generation,
						isStale: (error as? AutomationFailure) == .staleTarget
					)))
				}
			}
			.cancellable(id: Cancellation.inspection)

			// Cancel synchronously in reducer order; a late older read reports a stale generation.
			return .concatenate(.cancel(id: Cancellation.inspection), inspection)
		}

		Pullback(\.event.inspected) { state, value in
			let (generation, candidates) = value
			guard generation == state.inspectionGeneration else { return .none }

			state.candidates = candidates
			state.updateTargets()

			// A visible-area capture can finish before the bounds arrive.
			return state.phase == .captured ? state.checkProtectedMedia() : .none
		}

		Pullback(\.event.inspectionFailed) { state, value in
			let (generation, isStale) = value
			guard generation == state.inspectionGeneration else { return .none }

			// Picking blocks is a nicety: drawing an area still works without bounds.
			state.candidates = []
			state.updateTargets()
			guard isStale, state.phase == .selecting else { return .none }

			return state.retryStale()
		}

		Pullback(\.ui.viewportChanged) { state, size in
			let viewport = PageCaptureRegion(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
			guard viewport != state.viewport else { return .none }

			let resized = state.viewport.width > 0 && state.viewport.height > 0
			state.viewport = viewport
			state.updateTargets()

			// A resize can reflow the page, so the measured blocks move like a scroll.
			return resized ? .send(.ui(.scrolled)) : .none
		}

		Pullback(\.ui.pointerMoved) { state, point in
			guard state.phase == .selecting, state.drag == nil else { return .none }

			let target = PageCaptureGeometry.target(at: point, in: state.targets)
			if target != state.highlighted { state.highlighted = target }
			return .none
		}

		Pullback(\.ui.dragChanged) { state, value in
			guard state.phase == .selecting else { return .none }

			// The drag whose drawing was dropped draws nothing until the pointer goes up.
			guard state.droppedDragStart != value.from else { return .none }

			state.droppedDragStart = nil

			state.highlighted = nil

			// A drawing that began with scrolling keeps its place after a scroll fails.
			guard state.autoscrollAvailable || state.drawing != nil else {
				state.drag = PageCaptureGeometry.region(from: value.from, to: value.to, viewport: state.viewport)
				return .none
			}

			// The pointer went up while a scroll was out: that area is taken once it's back.
			guard state.drawing?.end == nil else { return .none }

			if state.drawing == nil {
				state.drawingGeneration += 1
				state.drawing = .init(start: value.from, pointer: value.to)
			}
			state.drawing?.pointer = value.to
			state.updateDrawnArea()
			return autoscroll(&state)
		}

		Pullback(\.ui.dragEnded) { state, value in
			guard state.phase == .selecting else { return .none }
			guard state.droppedDragStart != value.from else {
				state.droppedDragStart = nil
				return .none
			}

			if let drawing = state.drawing {
				// Only the drag being drawn ends it, once: a later drag waits for its last scroll.
				guard drawing.end == nil, drawing.start == value.from else { return .none }
				guard !drawing.isScrolling else {
					state.drawing?.end = value.to
					state.drawing?.isTicking = false
					return .cancel(id: Cancellation.autoscroll)
				}

				return .merge(.cancel(id: Cancellation.autoscroll), state.finishDrawing(at: value.to))
			}

			state.drag = nil
			guard
				PageCaptureGeometry.isDrag(from: value.from, to: value.to),
				let region = PageCaptureGeometry.region(from: value.from, to: value.to, viewport: state.viewport)
			else { return .none }

			return .send(.capture(region))
		}

		Pullback(\.ui.clicked) { state, point in
			switch state.phase {
			case .selecting:
				// An area being drawn, or waiting on its last scroll, comes first (DEV-1208).
				guard
					state.drawing == nil,
					let target = PageCaptureGeometry.target(at: point, in: state.targets),
					let region = PageCaptureGeometry.intersection(target.bounds, state.viewport)
				else { return .none }

				state.highlighted = target
				return .send(.capture(region))

			case .captured:
				// A click away from the frame ends the capture.
				guard
					let selection = state.selection,
					!PageCaptureGeometry.contains(selection, point)
				else { return .none }

				return .send(.ui(.cancel))

			case .preparing, .capturing:
				return .none
			}
		}

		Pullback(\.ui.scrolled) { state in
			guard state.phase == .selecting else { return .none }

			return boundsMoved(&state)
		}

		Pullback(\.event.autoscrollTick) { state, generation in
			guard
				generation == state.drawingGeneration,
				var drawing = state.drawing,
				drawing.isTicking,
				let request = state.request
			else { return .none }

			drawing.ticks = min(drawing.ticks + 1, Self.maximumAutoscrollTicks)
			guard !drawing.isScrolling else {
				state.drawing = drawing
				return .none
			}

			let velocity = PageCaptureGeometry.autoscrollVelocity(
				from: drawing.start,
				to: drawing.pointer,
				viewport: state.viewport
			)
			let seconds = Double(drawing.ticks) * Self.autoscrollIntervalSeconds
			let offset = PageCaptureOffset(x: velocity.x * seconds, y: velocity.y * seconds)
			drawing.ticks = 0
			drawing.isScrolling = true
			state.drawing = drawing
			let id = state.id
			return .run { [captureClient, authorization] send in
				do {
					guard await authorization.authorize(id, request)
					else { throw PageCaptureFailure.staleDocument }

					let moved = try await captureClient.scrollAuthorized(request, offset, {
						authorization.authorize(id, request)
					})
					await send(.event(.autoscrolled(generation, moved)))
				} catch is CancellationError {
					// The capture ended.
				} catch {
					// A busy or unavailable scroll never ran (a pinched page, or one that isn't HTTP(S));
					// a timed-out one may have scrolled before it gave up.
					let failure = error as? PageCaptureFailure
					let mayHaveMoved = failure != .busy && failure != .unavailable
					await send(.event(.autoscrollFailed(generation, mayHaveMoved: mayHaveMoved)))
				}
			}
			.cancellable(id: Cancellation.scroll)
		}

		Pullback(\.event.autoscrolled) { state, value in
			let (generation, moved) = value
			guard
				generation == state.drawingGeneration,
				var drawing = state.drawing
			else { return .none }

			drawing.isScrolling = false
			drawing.scrolled = drawing.scrolled + moved

			// At the page's end nothing moves: stop until the pointer moves again.
			if moved == .zero { drawing.isTicking = false }
			state.drawing = drawing
			let moves: Effect<Action> = moved == .zero ? .cancel(id: Cancellation.autoscroll) : boundsMoved(&state)
			if let end = drawing.end {
				return .merge(moves, state.finishDrawing(at: end))
			}

			state.updateDrawnArea()
			return moves
		}

		Pullback(\.event.autoscrollFailed) { state, value in
			let (generation, mayHaveMoved) = value
			guard
				generation == state.drawingGeneration,
				state.drawing != nil
			else { return .none }

			state.autoscrollAvailable = false
			guard !mayHaveMoved else {
				// How far the page went is unknown, so the area drawn so far can't be placed: the
				// pointer draws a fresh area within the viewport.
				// Only while that drag's pointer is still down: a release already taken ends it.
				state.droppedDragStart = state.drawing?.end == nil ? state.drawing?.start : nil
				state.drawing = nil
				state.drag = nil
				state.message = String.localized(.appUI.capture.scrollLost)

				// The blocks may have moved with it.
				return .merge(.cancel(id: Cancellation.autoscroll), boundsMoved(&state))
			}

			// Drawing goes on within the viewport, without scrolling.
			state.drawing?.isScrolling = false
			state.drawing?.isTicking = false
			if let end = state.drawing?.end {
				return .merge(.cancel(id: Cancellation.autoscroll), state.finishDrawing(at: end))
			}

			return .cancel(id: Cancellation.autoscroll)
		}

		Pullback(\.ui.move) { state, movement in
			guard state.phase == .selecting else { return .none }

			state.highlighted = PageCaptureGeometry.target(
				movement,
				from: state.highlighted,
				in: state.targets,
				viewport: state.viewport
			)
			return .none
		}

		Pullback(\.ui.commit) { state in
			guard
				state.phase == .selecting,
				state.drawing == nil,
				let target = state.highlighted,
				let region = PageCaptureGeometry.intersection(target.bounds, state.viewport)
			else { return .none }

			return .send(.capture(region))
		}

		Pullback(\.capture) { state, region in
			guard
				state.phase != .preparing || state.mode != .area,
				!state.isWorking,
				let request = state.request
			else { return .none }

			state.generation += 1
			state.phase = .capturing
			state.drag = nil
			state.drawing = nil
			state.message = nil
			state.showsProtectedMediaNote = false
			state.selection = region ?? state.viewport
			let generation = state.generation
			let id = state.id

			// A whole document is framed as a window: a phone that tall would hide the page.
			let framing: DeviceCaptureStyle? = state.framing.map { framing in
				var style = framing
				if request.mode == .fullDocument { style.isPortrait = false }
				return style
			}

			// Capture Page falls back to the visible area; Capture Full Page keeps its frame.
			let fallsBack = state.mode == .page && request.mode == .fullDocument && state.image == nil

			// An area reaching beyond the viewport is cut from the whole page (DEV-1208).
			let cutsArea = request.mode == .fullDocument && !state.isFullPage

			let capture: Effect<Action> = .run { [captureClient, authorization] send in
				do {
					guard await authorization.authorize(id, request)
					else { throw PageCaptureFailure.staleDocument }

					let frame = try await captureClient.captureAuthorized(request, {
						authorization.authorize(id, request)
					})
					try Task.checkCancellation()
					guard await authorization.authorize(id, request), frame.request == request
					else { throw PageCaptureFailure.staleDocument }

					try frame.validate()
					let viewport = PageCaptureRegion(x: 0, y: 0, width: frame.viewportWidth, height: frame.viewportHeight)

					// Portrait Mode takes its slice of the viewport the frame was captured at.
					let portrait: PageCaptureRegion? = framing?.isPortrait == true && request.mode == .viewport
					? DeviceCaptureStyle.portraitRegion(in: viewport)
					: nil
					let selection: PageCaptureRegion
					var image: PageCaptureImage
					if let region = region ?? portrait, request.mode == .viewport {
						guard let visible = PageCaptureGeometry.intersection(region, viewport)
						else { throw PageCaptureFailure.invalidRegion }

						selection = visible
						image = try captureClient.crop(frame, visible)
					} else if cutsArea, let region {
						guard let area = PageCaptureGeometry.documentRegion(for: region, in: frame)
						else { throw PageCaptureFailure.limitExceeded }

						selection = region
						image = try captureClient.crop(frame, area)
					} else {
						selection = viewport
						image = frame.image
					}
					if let framing { image = try captureClient.frame(image, framing) }
					await send(.event(.captured(generation, frame, image, selection)))
				} catch is CancellationError {
					// A newer capture or the overlay closing superseded this one.
				} catch let failure as PageCaptureFailure where fallsBack && Self.fallsBackToVisibleArea(failure) {
					await send(.event(.wholePageFailed(generation, failure)))
				} catch {
					await send(.event(.failed(
						generation,
						PageCapturePresentation.message(for: error),
						isStale: (error as? PageCaptureFailure) == .staleDocument
					)))
				}
			}
			.cancellable(id: Cancellation.capture)

			// Cancel synchronously in reducer order; a late older capture reports a stale generation.
			// The page stops scrolling under a capture (DEV-1208).
			return .concatenate(
				.cancel(id: Cancellation.capture),
				.cancel(id: Cancellation.autoscroll),
				.cancel(id: Cancellation.scroll),
				capture
			)
		}

		Pullback(\.event.captured) { state, value in
			let (generation, frame, image, selection) = value
			guard generation == state.generation, state.phase == .capturing
			else { return .none }

			state.phase = .captured
			state.frame = frame
			state.image = image
			state.selection = state.capturedSelection(frame: frame, image: image, selection: selection)
			state.highlighted = nil
			state.staleRetries = 0
			guard state.destination == .chat
			else { return state.checkProtectedMedia() }

			return .send(.ui(.sendToChat))
		}

		Pullback(\.ui.sendToChat) { state in
			guard
				state.phase == .captured,
				!state.isWorking,
				state.allowsSendingToChat || state.destination == .chat,
				let image = state.image
			else { return .none }

			state.isWorking = true
			return .concatenate(
				.send(.delegate(.sendToChat(image, title: state.title))),
				.send(.delegate(.dismiss))
			)
		}

		Pullback(\.event.wholePageFailed) { state, value in
			let (generation, reason) = value
			guard
				generation == state.generation,
				state.phase == .capturing,
				state.isFullPage
			else { return .none }

			if state.request?.beyondViewport == true, state.documentAvailable {
				// Today's path before the visible area: ABI16's recorded document.
				state.wholePageAvailable = false
				state.requestWholePage()
				return .send(.capture(nil))
			}

			state.requestViewport()

			// The same page would fail the same way, so the menu doesn't offer Capture Full Page.
			state.fullPageAvailable = false
			state.visibleAreaReason = reason

			// Bounds read for the whole-page request no longer authorize, so they're read again.
			return .merge(.send(.capture(nil)), .send(.inspect))
		}

		Pullback(\.event.mediaChecked) { state, value in
			let (generation, isBlank) = value
			guard generation == state.generation, state.phase == .captured else { return .none }

			state.showsProtectedMediaNote = isBlank
			return .none
		}

		Pullback(\.event.failed) { state, value in
			let (generation, message, isStale) = value
			guard generation == state.generation else { return .none }

			state.isWorking = false
			if state.phase == .capturing {
				state.phase = state.image == nil ? .selecting : .captured
				if state.image == nil { state.selection = nil }

				// A block or an area picked next is cut from the viewport, not the whole page.
				if state.request?.mode == .fullDocument { state.requestViewport() }
			}
			state.message = message

			// A page that changed under the overlay is taken again, quietly, a couple of times.
			if isStale, state.image == nil, state.staleRetries < Self.maximumStaleRetries {
				return state.retryStale()
			}

			return .run { [soundFeedback] _ in await soundFeedback.play(.couldNot) }
		}

		Pullback(\.ui.copy) { state in
			guard state.phase == .captured, !state.isWorking, let image = state.image
			else { return .none }

			state.isWorking = true
			let generation = state.generation
			return .run { [exportClient, soundFeedback] send in
				do {
					try await exportClient.copy(image)

					// The clipboard shows nothing, so a sound says it's there.
					await soundFeedback.play(.capture)
					await send(.event(.finished(generation)))
				} catch {
					await send(.event(.failed(generation, PageCapturePresentation.message(for: error), isStale: false)))
				}
			}
			.cancellable(id: Cancellation.export)
		}

		Pullback(\.ui.save) { state in
			guard state.phase == .captured, !state.isWorking, let image = state.image
			else { return .none }

			state.isWorking = true
			state.message = nil
			let generation = state.generation
			let title = state.title
			return .run { [exportClient, soundFeedback] send in
				do {
					let url = try await exportClient.save(image, .png, title)
					if url != nil { await soundFeedback.play(.capture) }
					await send(.event(.saved(generation, url)))
				} catch is CancellationError {
					// The overlay closed while the panel was open.
				} catch {
					await send(.event(.failed(generation, PageCapturePresentation.message(for: error), isStale: false)))
				}
			}
			.cancellable(id: Cancellation.export)
		}

		Pullback(\.ui.edit) { state in
			guard state.phase == .captured, !state.isWorking, let image = state.image
			else { return .none }

			state.isWorking = true
			let generation = state.generation
			let title = state.title
			return .run { [exportClient] send in
				do {
					try await exportClient.edit(image, title)
					await send(.event(.finished(generation)))
				} catch is CancellationError {
					// The overlay closed first.
				} catch {
					await send(.event(.failed(generation, PageCapturePresentation.message(for: error), isStale: false)))
				}
			}
			.cancellable(id: Cancellation.export)
		}

		Pullback(\.event.saved) { state, value in
			let (generation, url) = value
			guard generation == state.generation, state.isWorking else { return .none }

			state.isWorking = false

			// Canceling the save panel keeps the frame and its menu.
			return url == nil ? .none : .send(.delegate(.dismiss))
		}

		Pullback(\.event.finished) { state, generation in
			guard generation == state.generation, state.isWorking else { return .none }

			state.isWorking = false
			return .send(.delegate(.dismiss))
		}

		Pullback(\.ui.retake) { state in
			guard state.phase == .captured, !state.isWorking else { return .none }

			state.mode = .area
			state.staleRetries = 0
			return .merge(
				.cancel(id: Cancellation.media),
				.send(.delegate(.retake))
			)
		}

		Pullback(\.ui.captureFullPage) { state in
			guard
				state.phase == .captured,
				!state.isWorking,
				!state.isFullPage,
				state.fullPageAvailable,
				state.request != nil
			else { return .none }

			state.requestWholePage()
			return .send(.capture(nil))
		}

		Pullback(\.ui.cancel) { state in
			state.generation += 1
			state.inspectionGeneration += 1
			state.isWorking = false
			return .merge(
				.cancel(id: Cancellation.capture),
				.cancel(id: Cancellation.inspection),
				.cancel(id: Cancellation.settle),
				.cancel(id: Cancellation.export),
				.cancel(id: Cancellation.media),
				.cancel(id: Cancellation.autoscroll),
				.cancel(id: Cancellation.scroll),
				.send(.delegate(.dismiss))
			)
		}
	}

	internal static var autoscrollIntervalSeconds: Double {
		let components = autoscrollInterval.components
		return Double(components.seconds) + Double(components.attoseconds) / 1e18
	}

	/// Starts or stops scrolling the page while an area is drawn, as the pointer nears an edge or
	/// leaves it (DEV-1208).
	private func autoscroll(_ state: inout State) -> Effect<Action> {
		guard let drawing = state.drawing else { return .none }

		let velocity = PageCaptureGeometry.autoscrollVelocity(
			from: drawing.start,
			to: drawing.pointer,
			viewport: state.viewport
		)
		let scrolls = state.autoscrollAvailable && velocity != .zero && drawing.end == nil
		guard scrolls != drawing.isTicking else { return .none }

		state.drawing?.isTicking = scrolls
		state.drawing?.ticks = 0
		guard scrolls else { return .cancel(id: Cancellation.autoscroll) }

		let generation = state.drawingGeneration
		return .run { [clock] send in
			while true {
				try await clock.sleep(for: Self.autoscrollInterval)
				await send(.event(.autoscrollTick(generation)))
			}
		}
		.cancellable(id: Cancellation.autoscroll, cancelInFlight: true)
	}

	/// Bounds are viewport points, so a scroll moves every block: they're read again once it
	/// settles.
	private func boundsMoved(_ state: inout State) -> Effect<Action> {
		state.highlighted = nil
		state.candidates = []
		state.targets = []
		state.inspectionGeneration += 1
		return .merge(
			.cancel(id: Cancellation.inspection),
			.run { [clock] send in
				try await clock.sleep(for: Self.scrollSettleDelay)
				await send(.inspect)
			}
			.cancellable(id: Cancellation.settle, cancelInFlight: true)
		)
	}

	/// The inspection request's revision field names an MCP connection's view of a tab;
	/// a capture binds the session and document revisions in its source instead.
	internal static let inspectionRevision: String = .init(repeating: "0", count: 64)

	/// Whether Capture Page takes the visible area after the whole page failed this way. A busy
	/// slot or a changed page fails the visible area too, and a timed-out document capture keeps
	/// the engine's one capture slot until its work drains, so those keep their own handling.
	internal static func fallsBackToVisibleArea(_ failure: PageCaptureFailure) -> Bool {
		switch failure {
		case .limitExceeded, .unsupportedRendering, .unavailable, .invalidImage, .encodingFailed:
			true

		case .busy, .staleDocument, .timedOut, .invalidRegion, .invalidFormat:
			false
		}
	}
}

extension PageCaptureFeature.State {
	/// The part of the area being drawn that's on screen, for the cut-out (DEV-1208).
	fileprivate mutating func updateDrawnArea() {
		guard let drawing else { return }

		drag = PageCaptureGeometry.region(
			from: drawing.start,
			to: drawing.pointer,
			scrolled: drawing.scrolled,
			viewport: viewport
		)
		.flatMap { PageCaptureGeometry.intersection($0, viewport) }
	}

	/// Takes the area drawn from where the drag began to `end` (DEV-1208): from the viewport when
	/// it's all on screen, else cut from the whole page.
	fileprivate mutating func finishDrawing(at end: CGPoint) -> Effect<PageCaptureFeature.Action> {
		guard let drawing else { return .none }

		self.drawing = nil
		drag = nil
		guard
			drawing.scrolled != .zero || PageCaptureGeometry.isDrag(from: drawing.start, to: end),
			let region = PageCaptureGeometry.region(
				from: drawing.start,
				to: end,
				scrolled: drawing.scrolled,
				viewport: viewport
			)
		else { return .none }

		if PageCaptureGeometry.fits(region, in: viewport) {
			return PageCaptureGeometry.intersection(region, viewport).map { .send(.capture($0)) } ?? .none
		}

		requestArea()
		return .send(.capture(region))
	}

	/// Where the frame sits once the capture is in (DEV-1208): over what was captured, scaled down
	/// to fit the viewport when it's larger. Without the flag, a whole page's frame is the viewport.
	fileprivate func capturedSelection(
		frame: PageCaptureFrame,
		image: PageCaptureImage,
		selection: PageCaptureRegion
	) -> PageCaptureRegion {
		guard capturesBeyondViewport else { return isFullPage ? viewport : selection }
		guard isFullPage else { return PageCaptureGeometry.capturedFrame(for: selection, viewport: viewport) }

		let scale = frame.deviceScale > 0 ? frame.deviceScale : 1
		let page = PageCaptureRegion(
			x: viewport.x,
			y: viewport.y,
			width: Double(image.width) / scale,
			height: Double(image.height) / scale
		)
		return PageCaptureGeometry.capturedFrame(for: page, viewport: viewport)
	}

	fileprivate mutating func updateTargets() {
		let targets = viewport.width > 0 && viewport.height > 0
		? PageCaptureGeometry.targets(from: candidates, viewport: viewport)
		: candidates
		if targets != self.targets { self.targets = targets }
		if let highlighted, !targets.contains(highlighted) { self.highlighted = nil }
	}

	/// A page that changed under the overlay gets a fresh revision, a couple of times at most.
	fileprivate mutating func retryStale() -> Effect<PageCaptureFeature.Action> {
		guard staleRetries < PageCaptureFeature.maximumStaleRetries else { return .none }

		staleRetries += 1

		// A drawing doesn't outlive the page it was drawn on (DEV-1208).
		drawing = nil
		drag = nil
		return .merge(
			.cancel(id: PageCaptureFeature.Cancellation.autoscroll),
			.cancel(id: PageCaptureFeature.Cancellation.scroll),
			.send(.delegate(.retake))
		)
	}

	/// Says protected media may be blank only when a media block in the frame came out blank.
	fileprivate func checkProtectedMedia() -> Effect<PageCaptureFeature.Action> {
		guard
			!isFullPage,
			let frame,
			frame.request.mode == .viewport,
			let selection,
			frame.warnings.contains(.protectedMediaMayBeMissing)
		else { return .none }

		// Every candidate, so a video filling the viewport counts though it can't be picked.
		let regions = PageCaptureGeometry.mediaRegions(in: selection, targets: candidates)
		guard !regions.isEmpty else { return .none }

		let generation = generation
		return .run { send in
			let isBlank = regions.contains { PageCaptureCodec.isBlank(frame, in: $0) }
			await send(.event(.mediaChecked(generation, isBlank)))
		}
		.cancellable(id: PageCaptureFeature.mediaCancellation, cancelInFlight: true)
	}
}

/// An area being drawn while the page may scroll under it (DEV-1208). Points are in the viewport.
public struct PageCaptureDrawing: Equatable, Sendable {
	/// Where the drag began, before any scroll.
	public var start: CGPoint
	public var pointer: CGPoint

	/// How far the page has moved since the drag began.
	public var scrolled: PageCaptureOffset

	/// Timer ticks since the last scroll went out, so a slow reply doesn't slow the scroll.
	public var ticks: Int

	/// Whether the timer is running.
	public var isTicking: Bool

	/// Whether a scroll is out.
	public var isScrolling: Bool

	/// Where the pointer went up while a scroll was out: the area is taken once it's back.
	public var end: CGPoint?

	public init(
		start: CGPoint,
		pointer: CGPoint,
		scrolled: PageCaptureOffset = .zero,
		ticks: Int = 0,
		isTicking: Bool = false,
		isScrolling: Bool = false,
		end: CGPoint? = nil
	) {
		self.start = start
		self.pointer = pointer
		self.scrolled = scrolled
		self.ticks = ticks
		self.isTicking = isTicking
		self.isScrolling = isScrolling
		self.end = end
	}
}
