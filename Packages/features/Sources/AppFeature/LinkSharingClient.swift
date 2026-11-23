import AppKit
import AppUI
import Foundation
import _ComposableArchitecture

public struct LinkSharingClient: Sendable {
	public var copy: @MainActor @Sendable (String) -> Bool
	public var share: @MainActor @Sendable ([URL], UUID?) async -> LinkShareOutcome

	/// Share… for a page with its title, or for selected text (DEV-814, DEV-818).
	public var shareContent: @MainActor @Sendable (ShareContent, UUID?) async -> LinkShareOutcome

	public init(
		copy: @escaping @MainActor @Sendable (String) -> Bool,
		share: @escaping @MainActor @Sendable ([URL], UUID?) async -> LinkShareOutcome,
		shareContent: @escaping @MainActor @Sendable (ShareContent, UUID?) async -> LinkShareOutcome = { _, _ in
			.failed(String.localized(.appUI.links.shareUnavailable))
		}
	) {
		self.copy = copy
		self.share = share
		self.shareContent = shareContent
	}
}

/// What Share… hands the share sheet: a page's address with its title as the subject Mail
/// and Messages use, or selected text (DEV-814, DEV-818).
public enum ShareContent: Equatable, Sendable {
	case page(URL, title: String)
	case text(String)
}

public enum LinkShareOutcome: Equatable, Sendable {
	case shared
	case cancelled
	case failed(String)
}

extension LinkSharingClient: DependencyKey {
	public static var liveValue: Self {
		.init(
			copy: { text in
				NSPasteboard.general.clearContents()
				return NSPasteboard.general.setString(text, forType: .string)
			},
			share: { urls, windowID in await LinkSharePicker.present(urls, windowID: windowID) },
			shareContent: { content, windowID in
				switch content {
				case let .page(url, title):
					await LinkSharePicker.present([url], subject: title.isEmpty ? nil : title, windowID: windowID)
				case let .text(text):
					await LinkSharePicker.present([text], windowID: windowID)
				}
			}
		)
	}

	public static var testValue: Self {
		.init(
			copy: unimplemented("LinkSharingClient.copy", placeholder: false),
			share: unimplemented("LinkSharingClient.share", placeholder: .cancelled),
			shareContent: unimplemented("LinkSharingClient.shareContent", placeholder: .cancelled)
		)
	}
}

extension LinkSharingClient {
	internal static func windowIdentifier(for id: UUID) -> NSUserInterfaceItemIdentifier {
		.init("browser-" + id.uuidString)
	}

	/// Where Page PiP's site menu shares from (DEV-1257): its floating window, which has no ID of its
	/// own, since it holds another window's tab.
	internal static let pagePictureInPictureWindowID: UUID = UUID(uuidString: "9E5D8C1A-4F2B-4C7E-8A31-6B0D2F9C7E14")!

	@MainActor
	internal static func presentationWindow(for id: UUID?) -> NSWindow? {
		guard let id else { return nil }
		let identifier: NSUserInterfaceItemIdentifier = id == pagePictureInPictureWindowID
		? .init(PagePictureInPicturePanel.identifier)
		: windowIdentifier(for: id)
		return NSApplication.shared.windows.first {
			$0.identifier == identifier && $0.isVisible && !$0.isMiniaturized && $0.contentView != nil
		}
	}
}

extension DependencyValues {
	public var linkSharing: LinkSharingClient {
		get { self[LinkSharingClient.self] }
		set { self[LinkSharingClient.self] = newValue }
	}
}

@MainActor
private final class LinkSharePicker: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
	private static var active: LinkSharePicker?
	private let picker: NSSharingServicePicker
	private let subject: String?
	private var continuation: CheckedContinuation<LinkShareOutcome, Never>?

	private init(
		items: [Any],
		subject: String?,
		continuation: CheckedContinuation<LinkShareOutcome, Never>
	) {
		self.picker = NSSharingServicePicker(items: items)
		self.subject = subject
		self.continuation = continuation
		super.init()
		self.picker.delegate = self
	}

	internal static func present(
		_ items: [Any],
		subject: String? = nil,
		windowID: UUID?
	) async -> LinkShareOutcome {
		guard
			active == nil,
			let view = LinkSharingClient.presentationWindow(for: windowID)?.contentView
		else {
			return .failed(String.localized(.appUI.links.shareUnavailable))
		}
		return await withCheckedContinuation { continuation in
			let presenter = LinkSharePicker(items: items, subject: subject, continuation: continuation)
			active = presenter
			presenter.picker.show(
				relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.maxY - 44, width: 1, height: 1),
				of: view,
				preferredEdge: .minY
			)
		}
	}

	internal func sharingServicePicker(
		_ sharingServicePicker: NSSharingServicePicker,
		didChoose service: NSSharingService?
	) {
		if service == nil { finish(.cancelled) }
	}

	internal func sharingServicePicker(
		_ sharingServicePicker: NSSharingServicePicker,
		delegateFor sharingService: NSSharingService
	) -> (any NSSharingServiceDelegate)? {
		// Mail and Messages take the page's title as the subject (DEV-818).
		if let subject { sharingService.subject = subject }
		return self
	}

	internal func sharingService(
		_ sharingService: NSSharingService,
		didShareItems items: [Any]
	) {
		finish(.shared)
	}

	internal func sharingService(
		_ sharingService: NSSharingService,
		didFailToShareItems items: [Any],
		error: any Error
	) {
		let error = error as NSError
		finish(error.code == NSUserCancelledError ? .cancelled : .failed(error.localizedDescription))
	}

	private func finish(_ outcome: LinkShareOutcome) {
		guard let continuation else { return }
		self.continuation = nil
		Self.active = nil
		continuation.resume(returning: outcome)
	}
}
