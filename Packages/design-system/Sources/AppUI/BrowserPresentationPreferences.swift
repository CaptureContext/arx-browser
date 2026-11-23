import SwiftUI

extension EnvironmentValues {
	/// Whether the address bar shows the whole URL instead of the host. A profile setting;
	/// editing always shows the whole URL.
	@Entry
	public var showsFullURL: Bool = false

	/// Whether the sidebar plays a haptic as a dragged tab moves to a new place.
	@Entry
	public var reorderHapticsEnabled: Bool = true
}
