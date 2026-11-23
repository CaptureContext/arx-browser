import AppKit
import CoreText
import IssueReporting
import SwiftUI

/// The typeface for the lowercase "arx" wordmark.
///
/// Arx Wordmark is Comfortaa renamed, with its weight axis extended to 1000. It is licensed
/// under the SIL Open Font License 1.1; the licence ships next to the font in
/// `Resources/Fonts/ArxWordmark-OFL.txt`. Only wordmark text should use it, never body copy.
public enum ArxWordmark {
	/// The wordmark's spelling. Always lowercase.
	public static let text: String = "arx"

	/// The bundled face. Its file name matches the PostScript name so lookups by name resolve it.
	public static let resource: _FontResource = .arxWordmarkRegular

	/// The weight the wordmark is drawn at unless a caller asks otherwise.
	public static let defaultWeight: CGFloat = 700

	/// The range of the font's `wght` variation axis.
	public static let weights: ClosedRange<CGFloat> = 300...1000

	/// The OpenType tag `'wght'`.
	private static let weightAxis: Int = 0x7767_6874

	/// Registers the bundled face for this process the first time it is read.
	///
	/// Swift initializes static stored properties once and thread-safely, so concurrent first
	/// reads register the font a single time.
	private static let isRegistered: Bool = {
		let url: URL? = Bundle.module.url(
			forResource: resource.name,
			withExtension: "ttf"
		)
		guard let url else {
			reportIssue("ArxWordmark: \(resource.name).ttf is missing from the AppUI bundle.")
			return false
		}

		var error: Unmanaged<CFError>?
		let didRegister: Bool = CTFontManagerRegisterFontsForURL(
			url as CFURL,
			.process,
			&error
		)
		guard !didRegister else { return true }

		let failure: CFError? = error?.takeRetainedValue()
		let code: CFIndex? = failure.map(CFErrorGetCode)

		// Already registered in this process, for example by a host app, is not a failure.
		guard code != CTFontManagerError.alreadyRegistered.rawValue else { return true }

		reportIssue("ArxWordmark: registration failed: \(String(describing: failure)).")
		return false
	}()

	/// Makes sure the face is registered. Every accessor calls this, so hosts never need to.
	@discardableResult
	public static func register() -> Bool {
		isRegistered
	}

	/// The wordmark face at `size`, with the weight axis set to `weight` (clamped to `weights`).
	///
	/// Falls back to the rounded system font when the face cannot be registered.
	public static func ctFont(
		size: CGFloat,
		weight: CGFloat = defaultWeight
	) -> CTFont {
		guard register() else {
			let fallback: NSFont = .systemFont(
				ofSize: size,
				weight: .bold
			)
			let rounded: NSFontDescriptor = fallback.fontDescriptor.withDesign(.rounded)
			?? fallback.fontDescriptor
			let font: NSFont = NSFont(descriptor: rounded, size: size) ?? fallback
			return font as CTFont
		}

		let clampedWeight: CGFloat = min(max(weight, weights.lowerBound), weights.upperBound)
		let attributes: [CFString: Any] = [
			kCTFontNameAttribute: resource.name,
			kCTFontVariationAttribute: [weightAxis: clampedWeight],
		]
		let descriptor: CTFontDescriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
		return CTFontCreateWithFontDescriptor(descriptor, size, nil)
	}

	/// The wordmark face as an AppKit font.
	public static func nsFont(
		size: CGFloat,
		weight: CGFloat = defaultWeight
	) -> NSFont {
		ctFont(size: size, weight: weight) as NSFont
	}
}

extension Font {
	/// The Arx wordmark face. Use it only for the lowercase "arx" wordmark.
	public static func arxWordmark(
		size: CGFloat,
		weight: CGFloat = ArxWordmark.defaultWeight
	) -> Font {
		Font(ArxWordmark.ctFont(size: size, weight: weight))
	}
}
