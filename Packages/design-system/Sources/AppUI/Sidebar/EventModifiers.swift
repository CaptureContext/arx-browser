import AppKit

extension NSEvent {
	/// The modifier keys of the click or key press being handled, as it was made; the keyboard's
	/// state now only when no event is being handled, as for an accessibility action. Reading the
	/// keyboard's state instead turns a plain click into a ⌘-click whenever a modifier is held
	/// elsewhere, or reported stuck, as Screen Sharing can leave it.
	@MainActor
	internal static var actionModifierFlags: NSEvent.ModifierFlags {
		NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
	}
}
