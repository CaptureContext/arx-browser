import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine

/// ABI56 (DEV-963). The engine's JSON for a site permission prompt the app draws.
@Suite
internal struct ChromiumPagePermissionPromptTests {
	@Test
	internal func aLocationPromptDecodesWithItsEmbedderAndAccuracy() throws {
		let json = """
		{"token":"18446744073709551615","variant":"previouslyDenied",
		"requestingOrigin":"https://maps.example","embeddingOrigin":"https://news.example",
		"permissions":["geolocation"],"fragments":["Know your location"],"allowOnce":true,
		"geolocation":{"prompt":"upgradeToPrecise","initial":"approximate"},"quiet":false}
		"""
		let prompt = try JSONDecoder().decode(ChromiumPagePermissionPrompt.self, from: Data(json.utf8))
		expectNoDifference(
			prompt,
			ChromiumPagePermissionPrompt(
				token: .max,
				variant: .previouslyDenied,
				requestingOrigin: "https://maps.example",
				embeddingOrigin: "https://news.example",
				permissions: ["geolocation"],
				fragments: ["Know your location"],
				allowOnce: true,
				geolocation: .init(prompt: .upgradeToPrecise, initial: .approximate),
				quiet: false
			)
		)
	}

	@Test
	internal func aNotificationPromptHasNoEmbedderOrLocation() throws {
		let json = """
		{"token":"7","variant":"ask","requestingOrigin":"https://a.example","embeddingOrigin":null,
		"permissions":["notifications"],"fragments":["Show notifications"],"allowOnce":false,
		"geolocation":null,"quiet":true}
		"""
		let prompt = try JSONDecoder().decode(ChromiumPagePermissionPrompt.self, from: Data(json.utf8))
		#expect(prompt.token == 7)
		#expect(prompt.embeddingOrigin == nil)
		#expect(prompt.geolocation == nil)
		#expect(prompt.quiet)
	}

	@Test(arguments: [#""0""#, #""-1""#, #""x""#, "7", #""18446744073709551616""#])
	internal func aTokenThatIsntAPositiveDecimalStringIsRefused(_ token: String) {
		let json = """
		{"token":\(token),"variant":"ask","requestingOrigin":"https://a.example","embeddingOrigin":null,
		"permissions":["notifications"],"fragments":[""],"allowOnce":false,"geolocation":null,"quiet":false}
		"""
		#expect(throws: DecodingError.self) {
			try JSONDecoder().decode(ChromiumPagePermissionPrompt.self, from: Data(json.utf8))
		}
	}
}
