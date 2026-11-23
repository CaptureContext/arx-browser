/// Whether Arx follows the system's light or dark appearance or keeps one of them.
public enum AppTheme: String, CaseIterable, Codable, Sendable {
	case system
	case light
	case dark
}
