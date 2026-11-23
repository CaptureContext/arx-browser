import AppKit
import BrowserCore
import Carbon
import _ComposableArchitecture

public enum GlobalShortcutEvent: Equatable, Sendable {
	case registered
	case pressed
	case unavailableLayout

	/// Another app already holds the keys (DEV-1332). Arx tries again whenever an app quits, and
	/// reports `registered` once it has them.
	case taken
	case failed(Int32)
}

public struct GlobalShortcutClient: Sendable {
	public var events: @MainActor @Sendable (BrowserCore.KeyboardShortcut) -> AsyncStream<GlobalShortcutEvent>

	public init(
		events: @escaping @MainActor @Sendable (BrowserCore.KeyboardShortcut) -> AsyncStream<GlobalShortcutEvent>
	) {
		self.events = events
	}
}

extension GlobalShortcutClient: DependencyKey {
	public static var liveValue: Self { .init(events: { NativeGlobalShortcut.shared.start($0) }) }
	public static var testValue: Self {
		.init(events: unimplemented("GlobalShortcutClient.events", placeholder: .finished))
	}
}

extension DependencyValues {
	public var globalShortcut: GlobalShortcutClient {
		get { self[GlobalShortcutClient.self] }
		set { self[GlobalShortcutClient.self] = newValue }
	}
}

/// Owns one explicit opt-in registration. No event tap or accessibility permission is used.
@MainActor
private final class NativeGlobalShortcut {
	internal static let shared: NativeGlobalShortcut = .init()

	private let signature: OSType = 0x41727847
	private var generation: UInt32 = 0
	private var binding: BrowserCore.KeyboardShortcut?
	private var continuation: AsyncStream<GlobalShortcutEvent>.Continuation?
	private var hotKey: EventHotKeyRef?
	private var handler: EventHandlerRef?
	private var layoutObserver: NSObjectProtocol?

	/// While another app holds the keys: tries again as each app quits (DEV-1332).
	private var terminationObserver: NSObjectProtocol?

	private init() {}

	internal func start(_ binding: BrowserCore.KeyboardShortcut) -> AsyncStream<GlobalShortcutEvent> {
		stop(generation)
		generation &+= 1
		let current = generation
		let (stream, continuation) = AsyncStream<GlobalShortcutEvent>.makeStream(
			bufferingPolicy: .bufferingNewest(4)
		)
		self.binding = binding
		self.continuation = continuation
		continuation.onTermination = { _ in
			Task { @MainActor in Self.shared.stop(current) }
		}
		var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		let status = InstallEventHandler(
			GetApplicationEventTarget(),
			{ _, event, _ in
				guard let event else { return OSStatus(eventNotHandledErr) }

				var identity = EventHotKeyID()
				let status = GetEventParameter(
					event,
					EventParamName(kEventParamDirectObject),
					EventParamType(typeEventHotKeyID),
					nil,
					MemoryLayout<EventHotKeyID>.size,
					nil,
					&identity
				)
				guard status == noErr else { return status }

				return MainActor.assumeIsolated { NativeGlobalShortcut.shared.pressed(identity) }
			},
			1,
			&type,
			nil,
			&handler
		)
		guard status == noErr else {
			continuation.yield(.failed(status))
			return stream
		}
		layoutObserver = DistributedNotificationCenter.default().addObserver(
			forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
			object: nil,
			queue: .main
		) { _ in MainActor.assumeIsolated { Self.shared.register() } }
		register()
		return stream
	}

	private func pressed(_ identity: EventHotKeyID) -> OSStatus {
		guard
			identity.signature == signature,
			identity.id == generation,
			hotKey != nil
		else { return OSStatus(eventNotHandledErr) }

		continuation?.yield(.pressed)
		return noErr
	}

	private func register() {
		if let hotKey { UnregisterEventHotKey(hotKey) }
		hotKey = nil
		guard let binding, let code = keyCode(for: binding.key) else {
			continuation?.yield(.unavailableLayout)
			return
		}
		var modifiers: UInt32 = 0
		if binding.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
		if binding.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
		if binding.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }
		if binding.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
		let status = RegisterEventHotKey(
			code,
			modifiers,
			EventHotKeyID(signature: signature, id: generation),
			GetApplicationEventTarget(),
			OptionBits(kEventHotKeyExclusive),
			&hotKey
		)
		if status == OSStatus(eventHotKeyExistsErr) {
			// Taken by another app. A hot key goes before the active app's own keys, but never
			// before one registered first: Arx asks again once an app quits (DEV-1332).
			waitForTermination()
			continuation?.yield(.taken)
			return
		}
		stopWaitingForTermination()
		continuation?.yield(status == noErr ? .registered : .failed(status))
	}

	private func waitForTermination() {
		guard terminationObserver == nil else { return }

		terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
			forName: NSWorkspace.didTerminateApplicationNotification,
			object: nil,
			queue: .main
		) { _ in MainActor.assumeIsolated { Self.shared.retryAfterTermination() } }
	}

	private func retryAfterTermination() {
		guard binding != nil, hotKey == nil else { return }
		register()
	}

	private func stopWaitingForTermination() {
		if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
		terminationObserver = nil
	}

	private func stop(_ expected: UInt32) {
		guard generation == expected else { return }
		if let hotKey { UnregisterEventHotKey(hotKey) }
		if let handler { RemoveEventHandler(handler) }
		if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
		stopWaitingForTermination()
		hotKey = nil
		handler = nil
		layoutObserver = nil
		binding = nil
		let previous = continuation
		continuation = nil
		previous?.finish()
	}

	/// Resolve the persisted character against the active layout; do not persist physical key codes.
	private static let namedKeyCodes: [String: UInt32] = [
		"up": 126, "down": 125, "left": 123, "right": 124, "return": 36,
		"f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
		"f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
	]

	private func keyCode(for character: String) -> UInt32? {
		// Named keys sit at the same key codes on every layout (DEV-920).
		if let code = Self.namedKeyCodes[character] { return code }
		guard
			let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
			let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
		else { return nil }

		let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
		guard let bytes = CFDataGetBytePtr(data) else { return nil }

		let layoutPointer = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
		return layoutPointer.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
			for code in UInt16(0) ..< UInt16(128) {
				var deadKey: UInt32 = 0
				var count = 0
				var characters = [UniChar](repeating: 0, count: 8)
				let status = UCKeyTranslate(
					layout,
					code,
					UInt16(kUCKeyActionDown),
					UInt32(cmdKey >> 8),
					UInt32(LMGetKbdType()),
					OptionBits(kUCKeyTranslateNoDeadKeysMask),
					&deadKey,
					characters.count,
					&count,
					&characters
				)
				let translated = String(utf16CodeUnits: characters, count: count).lowercased()
				if status == noErr, translated == character { return UInt32(code) }
			}
			return nil
		}
	}
}
