import AppKit
import BrowserCore
import SwiftUI

/// Switches tabs as the mouse button goes down (DEV-914). On by default again (DEV-994, DEV-1143):
/// a tab dragged into the page now splits with the tab shown before the press, which DEV-976 had
/// turned it off for. `ARX_SIDEBAR_PRESS_SELECTS` set to `0`, `false`, `no` or `off` turns it off;
/// then nothing registers, no monitor is installed, and rows and tiles select on the click's
/// release.
///
/// A tab row or Favorite tile under the pointer that a plain press would select registers here
/// while hovered. One local monitor sees every left mouse down before the window does: a single,
/// unmodified press on a registered target selects it at once, and the click that follows on
/// release then does nothing more. The event goes on unchanged, so drags, double-clicks,
/// ⌘-click, ⇧-click and the context menu work as before; a row that's already selected never
/// registers and still waits for release.
@MainActor
internal enum SidebarPressActivation {
	private struct Target {
		internal let id: SidebarItem.ID
		internal let activate: @MainActor () -> Void
	}

	internal static let featureFlag: String = FeatureFlag.sidebarPressSelects.name

	/// Whether a press selects. Read once, through the `FeatureFlag` registry: the environment,
	/// then Arx's defaults under the flag's name, else its default.
	/// Tests set it.
	internal static var isEnabled: Bool = FeatureFlag.sidebarPressSelects.isOn()

	/// What one value turns it to.
	internal static func isOn(read: (String) -> String?) -> Bool {
		read(featureFlag).flatMap(FeatureFlag.parse) ?? FeatureFlag.sidebarPressSelects.isOnByDefault
	}

	/// Whether the mouse monitors are installed.
	internal static var isInstalled: Bool { !monitors.isEmpty }

	private static var target: Target?

	/// The target the current press selected, until the click after it.
	private static var pressed: SidebarItem.ID?
	private static var monitors: [Any] = []

	/// The hovered row or tile, when a plain press would select it. Nothing, with the flag off.
	internal static func hover(
		_ id: SidebarItem.ID,
		activate: @escaping @MainActor () -> Void
	) {
		guard isEnabled else { return }

		installIfNeeded()
		target = .init(id: id, activate: activate)
	}

	/// The pointer left the row or tile, or it no longer selects on a press.
	internal static func leave(_ id: SidebarItem.ID) {
		guard target?.id == id else { return }
		target = nil
	}

	/// Whether the press of this click already selected `id`, so the click does nothing more.
	internal static func consume(_ id: SidebarItem.ID) -> Bool {
		guard pressed == id else { return false }
		pressed = nil
		return true
	}

	/// Selects the target under a plain press. Exposed for tests, which have no event stream.
	internal static func press(
		clickCount: Int,
		modifiers: NSEvent.ModifierFlags
	) {
		pressed = nil
		guard
			clickCount == 1,
			modifiers.isDisjoint(with: [.shift, .command, .option, .control]),
			let target
		else { return }

		target.activate()
		pressed = target.id
	}

	/// Removes the monitors and forgets the target and press. For tests, between flag settings.
	internal static func reset() {
		for monitor in monitors { NSEvent.removeMonitor(monitor) }
		monitors = []
		target = nil
		pressed = nil
	}

	private static func installIfNeeded() {
		guard monitors.isEmpty else { return }

		if let down = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in
			MainActor.assumeIsolated {
				press(clickCount: event.clickCount, modifiers: event.modifierFlags)
			}
			return event
		}) {
			monitors.append(down)
		}

		// The click's own handler runs while the button comes up; anything later is a new
		// gesture, such as Space on the keyboard, and must not be swallowed.
		if let up = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { event in
			Task { @MainActor in pressed = nil }
			return event
		}) {
			monitors.append(up)
		}
	}
}
