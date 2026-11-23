/// The titles of a WebKit page's JavaScript dialog buttons. Services have no string catalog, so
/// the app passes them in from AppUI's (DEV-1291).
public struct WebKitDialogButtons: Equatable, Sendable {
	public var ok: String
	public var cancel: String

	public init(
		ok: String,
		cancel: String
	) {
		self.ok = ok
		self.cancel = cancel
	}

	/// English, for tests and anything that runs before the app sets its own.
	public static let untranslated: Self = .init(ok: "OK", cancel: "Cancel")
}
