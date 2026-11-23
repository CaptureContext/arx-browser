import BrowserCore
import BrowserEngineClient
import Foundation
import _ComposableArchitecture

@CasePathable
public enum CastAction: Sendable {
	/// Starts listening to Cast pickers. Sent once at launch, never in a headless run.
	case observe(menuTitle: String)

	/// Cast… for a tab, from a window's command or its sidebar's media controls.
	case open(BrowserCore.Tab.ID, windowID: UUID)
	case changed(BrowserCastPickerEvent)
}
