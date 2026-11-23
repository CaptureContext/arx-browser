import ChromiumBridge
import Foundation

/// ABI60 (DEV-1111). The link under the pointer in a page, as Chrome's status bubble shows
/// it, without its user name or password.
public struct ChromiumHoveredLink: Equatable, Sendable {
	/// Where a plain click on the link navigates (DEV-1118), as its frames said: the link's
	/// target, else its document's `<base target>`.
	public enum Target: Equatable, Sendable {
		/// No frame said in time, several did, or the target names a browsing context that may
		/// not exist.
		case unknown
		case mainFrame

		/// A frame inside the page: `_self` or `_parent` of a nested frame.
		case subframe

		/// `_blank`.
		case newContext
	}

	public var url: URL

	/// An http(s) link without credentials to another site than the page's (eTLD+1, private
	/// registries included). A plain click on it that navigates the main frame is offered
	/// through ``ChromiumRuntime/onCrossSiteLink``.
	public var isCrossSite: Bool
	public var target: Target

	public init(
		url: URL,
		isCrossSite: Bool,
		target: Target
	) {
		self.url = url
		self.isCrossSite = isCrossSite
		self.target = target
	}
}

extension ChromiumRuntime {
	/// ABI60 (DEV-1118): pages report hovered links through ``onLinkHover`` only while this is
	/// on, since each report runs a script in the page's frames. Off by default. Asked before the
	/// engine runs, as the app's window does at launch, it applies once the engine is ready.
	public func setLinkHoverReports(_ enabled: Bool) {
		linkHoverReports = enabled
		guard state == .running else { return }

		api.set_link_hover_reports?(enabled)
	}

	/// ABI60 (DEV-1111). A report for a document the page has left is dropped: the new
	/// document's own report follows. An address that isn't a URL reads as no link.
	internal func receiveLinkHover(
		page: UInt64,
		generation: UInt64,
		address: String?,
		flags: UInt32
	) {
		guard
			state == .running,
			let owner = pages[page],
			documentRevision(for: owner) == generation
		else { return }

		let link = address
			.flatMap { URL(string: $0, encodingInvalidCharacters: false) }
			.map { url in
				ChromiumHoveredLink(
					url: url,
					isCrossSite: flags & ARX_HOVERED_LINK_CROSS_SITE.rawValue != 0,
					target: Self.target(flags)
				)
			}
		onLinkHover?(owner, link)
	}

	private static func target(_ flags: UInt32) -> ChromiumHoveredLink.Target {
		guard flags & ARX_HOVERED_LINK_TARGET_KNOWN.rawValue != 0 else { return .unknown }
		if flags & ARX_HOVERED_LINK_NEW_CONTEXT.rawValue != 0 { return .newContext }
		if flags & ARX_HOVERED_LINK_IN_SUBFRAME.rawValue != 0 { return .subframe }
		return .mainFrame
	}
}
