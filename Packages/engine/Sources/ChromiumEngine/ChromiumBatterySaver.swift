import Foundation

/// `bool ArxEngineSetBatterySaverMode(int32_t state)` (DEV-915): main thread, once the engine
/// runs. Sets Chrome's Battery Saver pref: 0 never, 1 when the battery is low, 2 on battery
/// power, 3 always. Outside the ABI table, like the other optional exports.
internal typealias ChromiumSetBatterySaverModeFunction = @convention(c) (Int32) -> Bool

internal let ChromiumSetBatterySaverModeSymbol: String = "ArxEngineSetBatterySaverMode"

/// `bool ArxEngineBatterySaverIsActive()` (DEV-915).
internal typealias ChromiumBatterySaverIsActiveFunction = @convention(c) () -> Bool

internal let ChromiumBatterySaverIsActiveSymbol: String = "ArxEngineBatterySaverIsActive"

/// `bool ArxEngineObserveBatterySaver(handler, context)` (DEV-915): the handler hears Battery
/// Saver turn on and off.
internal typealias ChromiumBatterySaverHandler = @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void

internal typealias ChromiumObserveBatterySaverFunction = @convention(c) (
	ChromiumBatterySaverHandler?,
	UnsafeMutableRawPointer?
) -> Bool

internal let ChromiumObserveBatterySaverSymbol: String = "ArxEngineObserveBatterySaver"

/// Each runtime's Battery Saver observer. One runtime per process; keyed anyway.
@MainActor
private var batterySaverHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]

extension ChromiumRuntime {
	/// Whether this engine has Arx's Battery Saver controls (DEV-915).
	public var supportsBatterySaver: Bool {
		optionalExports.setBatterySaverMode != nil
	}

	/// Sets Chrome's Battery Saver state (0-3). False before the engine runs, on an older engine,
	/// or while policy manages it.
	@discardableResult
	public func setBatterySaverMode(_ state: Int32) -> Bool {
		guard self.state == .running, let set = optionalExports.setBatterySaverMode
		else { return false }

		return set(state)
	}

	/// Whether Battery Saver is on now.
	public var batterySaverIsActive: Bool {
		guard state == .running, let isActive = optionalExports.batterySaverIsActive
		else { return false }

		return isActive()
	}

	/// Hears Battery Saver turn on and off; nil stops. False when the engine can't report it yet.
	@discardableResult
	public func observeBatterySaver(_ handler: ((Bool) -> Void)?) -> Bool {
		guard state == .running, let observe = optionalExports.observeBatterySaver
		else { return false }

		let key = ObjectIdentifier(self)
		batterySaverHandlers[key] = handler
		guard handler != nil else { return observe(nil, nil) }

		return observe(
			{ context, isActive in
				MainActor.assumeIsolated {
					guard let context else { return }
					let runtime = Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue()
					batterySaverHandlers[ObjectIdentifier(runtime)]?(isActive)
				}
			},
			Unmanaged.passUnretained(self).toOpaque()
		)
	}
}
