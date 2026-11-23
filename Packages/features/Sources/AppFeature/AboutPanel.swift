import AppKit

/// About Arx with the credits: the engine and package licences
/// (`THIRD_PARTY_NOTICES.md`, rendered into the app's `Credits.rtf` by `make credits`).
///
/// The standard panel would load `Credits.rtf` by itself, but imported text keeps a fixed black,
/// which is unreadable in Dark Mode. The credits are loaded here and recoloured instead.
@MainActor
internal enum AboutPanel {
	internal static func show(bundle: Bundle = .main) {
		var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
		if
			let url = bundle.url(forResource: "Credits", withExtension: "rtf"),
			let data = try? Data(contentsOf: url),
			let credits = credits(from: data)
		{ options[.credits] = credits }

		NSApplication.shared.orderFrontStandardAboutPanel(options: options)
	}

	internal static func credits(from rtf: Data) -> NSAttributedString? {
		guard let credits: NSMutableAttributedString = try? .init(
			data: rtf,
			options: [.documentType: NSAttributedString.DocumentType.rtf],
			documentAttributes: nil
		)
		else { return nil }

		let range: NSRange = .init(location: 0, length: credits.length)
		credits.removeAttribute(.foregroundColor, range: range)
		credits.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
		return credits
	}
}
