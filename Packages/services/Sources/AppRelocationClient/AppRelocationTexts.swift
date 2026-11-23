extension AppRelocationClient {
	/// The text of the move-to-Applications prompts. Services have no string catalog, so the app
	/// passes it in from AppUI's (DEV-1291).
	public struct Texts: Equatable, Sendable {
		public var promptTitle: String
		public var promptMessage: String
		public var move: String
		public var notNow: String
		public var dontAskAgain: String
		public var failureTitle: String
		public var failureMessage: String
		public var ok: String

		public init(
			promptTitle: String,
			promptMessage: String,
			move: String,
			notNow: String,
			dontAskAgain: String,
			failureTitle: String,
			failureMessage: String,
			ok: String
		) {
			self.promptTitle = promptTitle
			self.promptMessage = promptMessage
			self.move = move
			self.notNow = notNow
			self.dontAskAgain = dontAskAgain
			self.failureTitle = failureTitle
			self.failureMessage = failureMessage
			self.ok = ok
		}

		/// English, for anything that runs before the app passes its own.
		public static let untranslated: Self = .init(
			promptTitle: "Move Arx to Applications?",
			promptMessage: "Arx works best from your Applications folder. It will move there and open again.",
			move: "Move to Applications",
			notNow: "Not Now",
			dontAskAgain: "Don't ask again",
			failureTitle: "Arx couldn't move to Applications",
			failureMessage: "Arx will keep running from where it is. You can try again from the Arx menu.",
			ok: "OK"
		)
	}
}
