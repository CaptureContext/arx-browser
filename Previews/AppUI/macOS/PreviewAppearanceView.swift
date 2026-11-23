import SettingsFeature
import SwiftUI

internal struct PreviewAppearanceView: View {
	internal var body: some View { SettingsView(store: PreviewAppearancePreferences.store) }
}
