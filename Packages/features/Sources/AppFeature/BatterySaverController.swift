import BrowserCore
import BrowserWorkspaceClient
import ChromiumEngine
import Foundation

/// Settings' Battery Saver and macOS Low Power Mode, applied to the engine (DEV-915).
///
/// It sends Chrome's Battery Saver state whenever the setting or Low Power Mode changes, and
/// reports Battery Saver turning on so the app can say so. A headless run applies it the same
/// way and shows nothing.
@MainActor
internal final class BatterySaverController {
	private let runtime: ChromiumRuntime
	private let document: WorkspaceDocument
	private let lowPowerMode: @MainActor () -> Bool
	private var lastState: Int32?
	private var observers: [any NSObjectProtocol] = []
	private var cancelDocument: (@Sendable () -> Void)?

	/// Battery Saver turned on or off.
	internal var onActiveChange: @MainActor (Bool) -> Void = { _ in }

	internal init(
		runtime: ChromiumRuntime,
		document: WorkspaceDocument,
		lowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
	) {
		self.runtime = runtime
		self.document = document
		self.lowPowerMode = lowPowerMode
	}

	/// Applies the current choice and keeps applying it. Call once the engine runs.
	internal func start() {
		guard runtime.supportsBatterySaver, observers.isEmpty else { return }
		apply()
		runtime.observeBatterySaver { [weak self] isActive in self?.onActiveChange(isActive) }
		observers.append(NotificationCenter.default.addObserver(
			forName: .NSProcessInfoPowerStateDidChange,
			object: nil,
			queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.apply() }
		})
		let cancel = document.observe(origin: nil) { [weak self] old, new in
			guard old.preferences.batterySaver != new.preferences.batterySaver else { return }
			Task { @MainActor [weak self] in self?.apply() }
		}
		cancelDocument = cancel
	}

	internal func stop() {
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		observers = []
		cancelDocument?()
		cancelDocument = nil
		runtime.observeBatterySaver(nil)
	}

	private func apply() {
		let state = document.preferences.batterySaver.engineState(lowPowerMode: lowPowerMode())
		guard state != lastState else { return }
		if runtime.setBatterySaverMode(state) { lastState = state }
	}
}
