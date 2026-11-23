import AppRelocationClient
import CustomDump
import Testing

@testable import AppFeature

/// The move-to-Applications prompts come from AppUI's catalog (DEV-1291); in English they read as
/// the client's own fallback, word for word.
internal struct AppRelocationTextsTests {
	@Test
	internal func theCatalogsEnglishIsTheFallback() {
		expectNoDifference(AppRelocationClient.Texts.localized, .untranslated)
	}
}
