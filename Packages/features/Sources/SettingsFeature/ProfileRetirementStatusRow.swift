import BrowserCore

public struct ProfileRetirementStatusRow: Identifiable, Equatable, Sendable {
	public let id: Profile.ID
	public let name: String
	public let message: String
	public let canRetry: Bool

	public init(
		id: Profile.ID,
		name: String,
		message: String,
		canRetry: Bool
	) {
		self.id = id
		self.name = name
		self.message = message
		self.canRetry = canRetry
	}
}
