import AppKit
import SwiftUI

/// What every Arx modal shares: the window's own background, as Air Traffic Control draws it, and
/// buttons in a larger frame than a row's.
public enum ArxModalMetrics {
	/// A modal's background: the window's own, with no tint of its own.
	public static let background: Color = .init(nsColor: .windowBackgroundColor)

	/// A modal's buttons: larger than a row's, so the action row reads as the way out.
	public static let buttonSize: ArxControlSize = .large

	/// Between a modal's buttons.
	public static let buttonSpacing: CGFloat = 8

	/// Between a modal's content and its sides.
	public static let contentPadding: CGFloat = 24
}

extension View {
	/// Draws the view as an Arx modal sheet: on the modal background, which a sheet also presents
	/// behind it. Lay out the content and the button row yourself; ``ArxModalButton`` draws the
	/// buttons.
	///
	/// ```swift
	/// VStack(alignment: .leading, spacing: 16) {
	///     Text("New Rule").font(.title2.bold())
	///     fields
	///     HStack(spacing: ArxModalMetrics.buttonSpacing) {
	///         Spacer()
	///         ArxModalButton.cancel { cancel() }
	///         ArxModalButton("Save") { save() }
	///             .disabled(!isValid)
	///     }
	/// }
	/// .padding(24)
	/// .arxModalSheet()
	/// ```
	public func arxModalSheet() -> some View {
		background(ArxModalMetrics.background)
			.presentationBackground(ArxModalMetrics.background)
	}
}

/// A modal's button: an Arx button in the modal's larger frame with the key it answers to.
///
/// - Cancel (`ArxModalButton.cancel`) looks like any Settings button, shows Esc and answers
///   Escape.
/// - The primary action (Done, or a verb such as Create or Save) uses the accent, shows ↩ and
///   answers Return. Give it `role: .destructive` to fill it red instead, for an action that
///   removes something. Disabled, it drops the accent but keeps its text readable.
/// - A primary button that closes a sheet whose fields take Return, such as Done under a list
///   with fields, answers Escape instead: `key: .escape`.
/// - Any other action in the row, such as Delete, is `ArxModalButton(title, prominence:)` with
///   `key: nil`.
///
/// Every enabled one lightens on hover and darkens when pressed, as every Arx button does.
public struct ArxModalButton: View {
	/// The key a modal button answers to and shows.
	public enum Key: Hashable, Sendable {
		/// Return, the sheet's default action.
		case `return`

		/// Escape, the sheet's cancel action.
		case escape
	}

	private let title: Text
	private let role: ButtonRole?
	private let prominence: ArxButtonStyle.Prominence
	private let key: Key?
	private let action: () -> Void

	public init(
		_ title: String,
		role: ButtonRole? = nil,
		prominence: ArxButtonStyle.Prominence = .primary,
		key: Key? = .return,
		action: @escaping () -> Void
	) {
		self.title = Text(title)
		self.role = role
		self.prominence = prominence
		self.key = key
		self.action = action
	}

	/// Cancel: the regular Settings button, showing Esc and answering Escape.
	public static func cancel(
		_ title: String = String.localized(.appUI.common.cancel),
		action: @escaping () -> Void
	) -> Self {
		.init(title, prominence: .secondary, key: .escape, action: action)
	}

	public var body: some View {
		Button(role: role, action: action) {
			ArxButtonLabel(title, keyHint: keyHint)
		}
		.buttonStyle(.arxModal(prominence))
		.modifier(ArxModalKeyShortcut(key: key))
	}

	private var keyHint: ArxKeyHint? {
		switch key {
		case .return: .return
		case .escape: .escape
		case nil: nil
		}
	}
}

private struct ArxModalKeyShortcut: ViewModifier {
	internal let key: ArxModalButton.Key?

	internal func body(content: Content) -> some View {
		switch key {
		case .return: content.keyboardShortcut(.defaultAction)
		case .escape: content.keyboardShortcut(.cancelAction)
		case nil: content
		}
	}
}

/// A modal with a header bar over scrolling content (DEV-782): the content scrolls edge to edge
/// under the bar, where the system's soft scroll edge blurs it (DEV-807), with no hard clip
/// line, on the modal background. An optional footer stays pinned under the content, which
/// softens above it the same way.
///
/// ```swift
/// ArxModalScaffold {
///     ArxHeaderBar(.close { dismiss() }, title: "Site Settings", subtitle: "Profiles › Work") {
///         ArxHeaderSearch("Search sites", query: $query)
///     }
/// } content: {
///     sections
/// }
/// .frame(width: 620, height: 640)
/// ```
public struct ArxModalScaffold<Bar: View, Content: View, Footer: View>: View {
	private let contentPadding: CGFloat
	private let barTopInset: CGFloat
	private let bar: Bar
	private let content: Content
	private let footer: Footer

	/// `contentPadding` is between the content and the modal's sides and bottom.
	/// `barTopInset` moves the bar down inside its soft edge, for a window whose
	/// traffic lights sit over the modal; the edge still reaches the top.
	public init(
		contentPadding: CGFloat = ArxModalMetrics.contentPadding,
		barTopInset: CGFloat = 0,
		@ViewBuilder bar: () -> Bar,
		@ViewBuilder content: () -> Content,
		@ViewBuilder footer: () -> Footer
	) {
		self.contentPadding = contentPadding
		self.barTopInset = barTopInset
		self.bar = bar()
		self.content = content()
		self.footer = footer()
	}

	public var body: some View {
		ScrollView {
			content
				.frame(maxWidth: .infinity, alignment: .topLeading)
				.padding(.horizontal, contentPadding)
				.padding(.top, 4)
				.padding(.bottom, contentPadding)
		}
		.scrollIndicators(.automatic)
		.safeAreaBar(edge: .bottom, spacing: 0) {
			if Footer.self != EmptyView.self {
				footer
					.frame(maxWidth: .infinity, alignment: .leading)
					.padding(.horizontal, contentPadding)
					.padding(.vertical, 12)
			}
		}
		.arxScrollBar { bar.padding(.top, barTopInset) }
	}
}

extension ArxModalScaffold where Footer == EmptyView {
	public init(
		contentPadding: CGFloat = ArxModalMetrics.contentPadding,
		barTopInset: CGFloat = 0,
		@ViewBuilder bar: () -> Bar,
		@ViewBuilder content: () -> Content
	) {
		self.init(
			contentPadding: contentPadding,
			barTopInset: barTopInset,
			bar: bar,
			content: content
		) { EmptyView() }
	}
}
