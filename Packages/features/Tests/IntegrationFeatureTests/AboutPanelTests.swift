import AppKit
import Foundation
import Testing

@testable import AppFeature

@Suite(.dependencies)
@MainActor
internal struct AboutPanelTests {
	@Test
	internal func creditsKeepTheirTextAndFollowTheSystemTextColor() throws {
		let rtf: Data = .init(
			#"{\rtf1\ansi{\colortbl;\red0\green0\blue0;}\cf1 Arx credits.\par{\f0 Rou\u233?}\par}"#.utf8
		)
		let credits: NSAttributedString = try #require(AboutPanel.credits(from: rtf))

		#expect(credits.string.contains("Arx credits."))
		#expect(credits.string.contains("Roué"))
		var colors: [NSColor] = []
		credits.enumerateAttribute(
			.foregroundColor,
			in: NSRange(location: 0, length: credits.length)
		) { value, _, _ in
			if let color = value as? NSColor { colors.append(color) }
		}
		#expect(!colors.isEmpty)
		#expect(colors.allSatisfy { $0 == .labelColor })
	}
}
