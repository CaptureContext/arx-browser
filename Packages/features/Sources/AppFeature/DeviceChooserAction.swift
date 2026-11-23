import BrowserEngineClient
import _ComposableArchitecture

@CasePathable
public enum DeviceChooserAction: Sendable {
	/// Starts listening to device requests. Sent once at launch, never in a headless run.
	case observe
	case changed(BrowserDeviceChooserEvent)
}
