#if DEBUG
import AppKit
import BrowserCaptureClient
import BrowserCore
import BrowserEngineClient
import ChromiumBrowserEngine
import Foundation

/// Rendering assertions run only in the disposable signed app-smoke process.
@MainActor
internal enum CaptureSmoke {
	internal static func run(
		engine: ChromiumBrowserEngine,
		profileID: Profile.ID,
		baseURL: URL,
		environment: [String: String]
	) async throws {
		guard
			baseURL.scheme == "http",
			baseURL.host == "127.0.0.1",
			let encoded = environment["ARX_CAPTURE_SMOKE_PATCHES"]?.data(using: .utf8)
		else { throw CaptureSmokeFailure("missing controlled fixture configuration") }

		let patches = try JSONDecoder().decode([CaptureSmokePixels.Patch].self, from: encoded)

		guard patches.count == 6
		else { throw CaptureSmokeFailure("incomplete viewport/canvas/iframe expectations") }

		let runner = Runner(
			engine: engine,
			profileID: profileID,
			baseURL: baseURL,
			patches: patches
		)
		try await runner.run()
	}
}

extension CaptureSmoke {
	@MainActor
	private final class Runner {
		private let engine: ChromiumBrowserEngine
		private let profileID: Profile.ID
		private let baseURL: URL
		private let patches: [CaptureSmokePixels.Patch]
		private let host: NSView
		private let window: NSWindow
		private var tabs: Set<Tab.ID> = []

		internal init(
			engine: ChromiumBrowserEngine,
			profileID: Profile.ID,
			baseURL: URL,
			patches: [CaptureSmokePixels.Patch]
		) {
			self.engine = engine
			self.profileID = profileID
			self.baseURL = baseURL
			self.patches = patches

			let bounds = NSRect(x: 0, y: 0, width: 640, height: 480)
			self.host = .init(frame: bounds)
			self.window = .init(
				contentRect: bounds,
				styleMask: [.titled],
				backing: .buffered,
				defer: false
			)
			self.window.isReleasedWhenClosed = false
			self.window.title = "Arx controlled capture fixture"
			self.window.contentView = self.host
		}

		internal func run() async throws {
			let previousWindow = NSApp.keyWindow
			defer {
				for id in tabs { engine.client.close(id) }
				engine.surface.detach(host)
				window.close()
				previousWindow?.makeKeyAndOrderFront(nil)
			}

			window.center()
			window.makeKeyAndOrderFront(nil)

			guard engine.capture.isAvailable()
			else { throw CaptureSmokeFailure("native capture capability unavailable") }

			let tab = try await open("viewport", title: "Arx capture viewport")
			let original = try snapshot(tab)
			let viewport = try await capture(tab)

			try geometry(viewport)
			try CaptureSmokePixels.verify(viewport, patches: patches)
			try unchanged(tab, from: original)

			let blue = patches[2]
			let region = PageCaptureRegion(x: blue.x - 10, y: blue.y - 10, width: 20, height: 20)
			let cropped = try engine.capture.crop(viewport, region)
			let expectedPixels = try viewport.pixels(in: region)

			guard
				cropped.width == expectedPixels.width,
				cropped.height == expectedPixels.height
			else { throw CaptureSmokeFailure("crop dimensions did not match the frozen viewport") }

			try CaptureSmokePixels.expect(
				PageCaptureCodec.decode(cropped),
				x: cropped.width / 2,
				y: cropped.height / 2,
				patch: blue
			)

			guard try PageCaptureCodec.encode(viewport.image, as: .png) == viewport.image.png
			else { throw CaptureSmokeFailure("PNG export changed captured bytes") }

			print("ARX_CAPTURE_PIXELS_SUCCESS")

			try await engine.client.command(tab, .navigate(url("long")))
			try await ready(tab, title: "Arx capture layout | 37,211,")
			let layoutBefore = try snapshot(tab)
			let layout = try await capture(tab)
			try geometry(layout)

			guard layout.documentID != viewport.documentID
			else { throw CaptureSmokeFailure("cross-document navigation reused the capture document identity") }

			let metrics = layoutBefore.navigation.title.components(separatedBy: " | ").last?
				.split(separator: ",").compactMap { Double($0) } ?? []

			guard
				metrics.count == 5,
				metrics[0] == 37,
				metrics[1] == 211,
				abs(metrics[2] - layout.viewportWidth) < 1,
				abs(metrics[3] - layout.viewportHeight) < 1,
				abs(metrics[4] - layout.deviceScale) < 0.01
			else { throw CaptureSmokeFailure("scroll/layout/device scale disagreed with page metrics") }

			try CaptureSmokePixels.verify(
				layout,
				patches: [
					.init(x: 100, y: 20, red: 255, green: 153, blue: 0),
					.init(x: 100, y: 55, red: 153, green: 0, blue: 255),
				]
			)
			try await Task.sleep(for: .milliseconds(150))
			try unchanged(tab, from: layoutBefore)

			// PNG encoders may vary metadata between calls. Frozen content must
			// retain every decoded pixel, independently of encoded container bytes.
			let repeatedCrop = try engine.capture.crop(viewport, region)
			try CaptureSmokePixels.expectSamePixels(cropped, repeatedCrop)

			engine.client.close(tab)

			let lazy = try await open("lazy", title: "Arx capture lazy | unloaded")
			let lazyBefore = try snapshot(lazy)
			_ = try await capture(lazy)
			try await Task.sleep(for: .milliseconds(150))
			try unchanged(lazy, from: lazyBefore)
			engine.client.close(lazy)

			let dynamic = try await open("dynamic", title: "Arx capture animation")
			let first = try await capture(dynamic)
			try await Task.sleep(for: .milliseconds(180))
			let second = try await capture(dynamic)

			guard
				first.documentID == second.documentID,
				try CaptureSmokePixels.sample(first, x: 50, y: 50) != CaptureSmokePixels.sample(second, x: 50, y: 50)
			else { throw CaptureSmokeFailure("animated canvas did not produce live compositor pixels") }

			engine.client.close(dynamic)

			let loading = try await open("loading", title: "Arx capture loading", whileLoading: true)
			let partial = try await capture(loading)

			guard partial.wasLoading
			else { throw CaptureSmokeFailure("loading-page capture lost its loading state") }

			try geometry(partial)
			engine.client.close(loading)
			print("ARX_CAPTURE_LAYOUT_SUCCESS")

			let bounded = try await open("viewport", title: "Arx capture viewport")

			do {
				_ = try await capture(bounded, limits: .init(maximumDimension: 1, maximumPixels: 1))
				throw CaptureSmokeFailure("oversize viewport was accepted")
			} catch PageCaptureFailure.limitExceeded {}

			engine.client.close(bounded)

			try await invalidation(.cancel)
			try await invalidation(.close)
			try await invalidation(.navigate)
			print("ARX_CAPTURE_INVALIDATION_SUCCESS")
			print("ARX_CAPTURE_SMOKE_SUCCESS")
		}

		private enum Interruption {
			case cancel, close, navigate
		}

		private func invalidation(_ interruption: Interruption) async throws {
			let tab = try await open("viewport", title: "Arx capture viewport")

			// Drain any previous canceled physical copy before testing the next case.
			_ = try await capture(tab)
			try await Task.sleep(for: .milliseconds(50))

			let request = PageCaptureRequest(tabID: tab, revision: try snapshot(tab).revision)
			let (started, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
			let task = Task {
				defer { continuation.finish() }

				return try await engine.capture.captureAuthorized(request) {
					continuation.yield(())
					return true
				}
			}

			var expired = false
			let watchdog = Task {
				try await Task.sleep(for: .seconds(6))
				expired = true
				task.cancel()
			}
			defer {
				task.cancel()
				watchdog.cancel()
				engine.client.close(tab)
			}

			var iterator = started.makeAsyncIterator()

			guard await iterator.next() != nil else {
				_ = try await task.value
				throw CaptureSmokeFailure("capture did not reach authorization")
			}

			switch interruption {
			case .cancel: task.cancel()
			case .close: engine.client.close(tab)
			case .navigate: try await engine.client.command(tab, .navigate(url("long")))
			}

			do {
				_ = try await task.value
				throw CaptureSmokeFailure("\(interruption) returned a stale image")
			} catch is CancellationError where interruption == .cancel {
				guard !expired
				else { throw CaptureSmokeFailure("caller cancellation did not complete before its deadline") }

				// Expected caller cancellation; no successful image may escape.
			} catch PageCaptureFailure.staleDocument where interruption != .cancel {
				// Expected native/document or service revision rejection.
			}
		}

		private func open(
			_ endpoint: String,
			title: String,
			whileLoading: Bool = false
		) async throws -> Tab.ID {
			let tab = Tab(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Capture smoke", url: url(endpoint))
			)
			tabs.insert(tab.id)
			try await engine.client.open(tab)
			engine.surface.attach(tab.id, host)
			try await ready(tab.id, title: title, whileLoading: whileLoading)

			return tab.id
		}

		private func url(_ endpoint: String) -> URL {
			var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
			components.path = "/capture/\(endpoint).html"
			components.queryItems = [.init(name: "run", value: UUID().uuidString)]

			return components.url!
		}

		private func snapshot(_ id: Tab.ID) throws -> BrowserSessionSnapshot {
			guard let snapshot = engine.client.snapshot(id)
			else { throw CaptureSmokeFailure("fixture session missing") }

			return snapshot
		}

		private func ready(
			_ id: Tab.ID,
			title: String,
			whileLoading: Bool = false
		) async throws {
			let deadline = ContinuousClock.now.advanced(by: .seconds(10))

			while ContinuousClock.now < deadline {
				if let value = engine.client.snapshot(id) {
					let isReady = value.navigation.title.hasPrefix(title)
					&& value.navigation.errorCode == nil
					&& (whileLoading || !value.navigation.isLoading)
					&& engine.isAttached(id)

					if isReady {
						// Let the committed fixture submit its first compositor frame.
						try await Task.sleep(for: .milliseconds(150))
						return
					}
				}

				try await Task.sleep(for: .milliseconds(50))
			}

			throw CaptureSmokeFailure("fixture did not become ready: \(title)")
		}

		private func capture(
			_ id: Tab.ID,
			limits: PageCaptureLimits = .init()
		) async throws -> PageCaptureFrame {
			let deadline = ContinuousClock.now.advanced(by: .seconds(6))

			while ContinuousClock.now < deadline {
				let request = PageCaptureRequest(
					tabID: id,
					revision: try snapshot(id).revision,
					limits: limits
				)
				let task = Task { try await engine.capture.capture(request) }
				let watchdog = Task {
					try await Task.sleep(for: .seconds(6))
					task.cancel()
				}
				defer {
					task.cancel()
					watchdog.cancel()
				}

				do {
					return try await task.value
				} catch PageCaptureFailure.busy {
					try await Task.sleep(for: .milliseconds(50))
				}
			}

			throw CaptureSmokeFailure("physical capture slot did not drain")
		}

		private func geometry(_ frame: PageCaptureFrame) throws {
			_ = try PageCaptureCodec.decode(frame.image, limits: frame.request.limits)

			guard
				abs(frame.viewportWidth - host.bounds.width) < 1,
				abs(frame.viewportHeight - host.bounds.height) < 1,
				abs(frame.deviceScale - window.backingScaleFactor) < 0.01,
				abs(Double(frame.image.width) - frame.viewportWidth * frame.deviceScale) <= 1,
				abs(Double(frame.image.height) - frame.viewportHeight * frame.deviceScale) <= 1,
				frame.warnings.contains(.protectedMediaMayBeMissing)
			else { throw CaptureSmokeFailure("capture dimensions/device scale disagreed with the mounted viewport") }
		}

		private func unchanged(
			_ id: Tab.ID,
			from before: BrowserSessionSnapshot
		) throws {
			let after = try snapshot(id)

			guard
				after.navigation.url == before.navigation.url,
				after.navigation.title == before.navigation.title,
				after.revision == before.revision
			else { throw CaptureSmokeFailure("capture changed the original page URL, title, scroll, layout, or session") }
		}
	}
}

internal struct CaptureSmokeFailure: LocalizedError {
	internal var errorDescription: String?

	internal init(_ message: String) { self.errorDescription = "Capture smoke: " + message }
}
#endif
