import SwiftUI

/// Where a hovered page link goes, and what a click with the held modifier keys will do
/// (DEV-1111): the address alone for an ordinary click, or the action in words around it, such
/// as "Open github.com/… **in a new tab and go to it**".
///
/// One line. The address gives way first, truncating in the middle so its host and the end of
/// its path stay readable; the words around it never truncate.
public struct LinkStatusToast: View {
	/// The words before the address, such as "Open", or nil for the address alone.
	private let verb: String?
	private let address: String

	/// The words after the address, such as "in a new tab and go to it", or nil.
	private let action: String?

	public init(
		verb: String? = nil,
		address: String,
		action: String? = nil
	) {
		self.verb = verb
		self.address = address
		self.action = action
	}

	public var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: LinkStatusToastMetrics.cornerRadius, style: .continuous)
		HStack(alignment: .firstTextBaseline, spacing: LinkStatusToastMetrics.wordSpacing) {
			if let verb {
				Text(verbatim: verb)
					.foregroundStyle(BrowserTheme.secondary)
					.fixedSize()
					.layoutPriority(1)
			}
			Text(verbatim: address)
				.foregroundStyle(BrowserTheme.text)
				.lineLimit(1)
				.truncationMode(.middle)
			if let action {
				Text(verbatim: action)
					.fontWeight(.semibold)
					.foregroundStyle(BrowserTheme.text)
					.fixedSize()
					.layoutPriority(1)
			}
		}
		.font(.system(size: LinkStatusToastMetrics.fontSize))
		.padding(.horizontal, LinkStatusToastMetrics.horizontalPadding)
		.frame(height: LinkStatusToastMetrics.height)
		.background(.regularMaterial, in: shape)
		.overlay { shape.strokeBorder(BrowserTheme.pageBorder, lineWidth: 0.5) }
		.accessibilityElement(children: .combine)
	}
}

public enum LinkStatusToastMetrics {
	/// Between the toast and the page's bottom and side edges.
	public static let edgeInset: CGFloat = 6

	/// The toast's height; its width follows its text.
	public static let height: CGFloat = 22

	/// The widest the toast gets, as a share of the page's width.
	public static let maximumWidthFraction: CGFloat = 2 / 3

	/// The narrowest page the toast still shows in.
	public static let minimumWidth: CGFloat = 120

	/// The narrowest the toast gets when it moves beside the pointer; with less room it hides.
	public static let minimumBesidePointer: CGFloat = 80

	/// How long the pointer rests on a link before its toast shows.
	public static let showDelay: Duration = .milliseconds(200)

	/// How long the toast stays once the pointer leaves a link, so moving between two links
	/// doesn't make it blink.
	public static let hideDelay: Duration = .milliseconds(120)

	internal static let fontSize: CGFloat = 11.5
	internal static let wordSpacing: CGFloat = 3
	internal static let horizontalPadding: CGFloat = 8
	internal static let cornerRadius: CGFloat = 6
}

#Preview("Link status") {
	VStack(alignment: .leading, spacing: 8) {
		LinkStatusToast(address: "github.com/emilkowalski/skills/tree/main/skills/apple-design")
		LinkStatusToast(
			verb: "Open",
			address: "github.com/emilkowalski/skills/tree/main/skills/apple-design",
			action: "in a new tab and go to it"
		)
		.frame(maxWidth: 320, alignment: .leading)
		LinkStatusToast(verb: "Download", address: "example.com/files/report.pdf")
	}
	.padding()
}
