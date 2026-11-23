/// What the Library's rail offers.
public enum LibrarySection: Hashable, Sendable {
	case media
	case downloads

	/// The profile's browsing history by day (DEV-817).
	case history
	case spaces
	case archive
}
