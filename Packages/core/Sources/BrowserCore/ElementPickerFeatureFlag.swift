import Foundation

/// The `ARX_ELEMENT_PICKER` feature flag (DEV-1201): Hide Element opens Arx's own element picker,
/// an outline and a chip naming the element in Arx's accent, instead of uBlock Origin's picker.
/// Off, or on an engine without it, ⇧⌘H opens uBlock's picker as before. On by default, as every
/// flag is for the beta (DEV-1143). Read through the `FeatureFlag` registry: the environment
/// first, then user defaults.
public enum ElementPickerFeatureFlag {
	public static let name: String = FeatureFlag.elementPicker.name

	public static func isOn(
		environment: [String: String],
		defaults: UserDefaults = .standard
	) -> Bool {
		FeatureFlag.elementPicker.isOn(environment: environment, defaults: defaults)
	}
}
