import AppKit
import BrowserCaptureClient
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChromiumEngine

extension ChromiumBrowserEngine {
	// MARK: - Link contexts

	public func linkContextView(_ context: BrowserLinkContext) -> NSView? {
		guard linkContextIsCurrent(context) else { return nil }
		return pages[context.tabID]?.view
	}

	internal func linkContextEvents() -> AsyncStream<BrowserLinkContext> {
		let events = runtime.linkContextEvents()
		return .init(bufferingPolicy: .bufferingNewest(1)) { continuation in
			let task = Task { @MainActor [weak self] in
				for await native in events {
					guard let self else { break }
					guard let context = linkContext(native) else {
						runtime.dismissLinkContext(page: native.pageID, token: native.token)
						continue
					}
					switch continuation.yield(context) {
					case let .dropped(old):
						client.dismissLinkContext(old)
					case .terminated:
						client.dismissLinkContext(context)
					default: break
					}
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	private func linkContext(_ native: ChromiumLinkContext) -> BrowserLinkContext? {
		guard
			let id = tabID(ofPage: native.pageID),
			let page = pages[id],
			let profileID = pageProfiles[id],
			let revision = sessionRevisions[id],
			runtime.linkContextIsCurrent(native, on: page)
		else { return nil }

		let context = BrowserLinkContext(
			token: native.token,
			tabID: id,
			profileID: profileID,
			sessionRevision: revision,
			documentRevision: native.documentGeneration,
			isPrivate: page.isPrivate,
			item: .init(title: native.text, url: native.url),
			x: native.x,
			y: native.y
		)
		do {
			try context.validate()
		} catch {
			return nil
		}
		return context
	}

	internal func linkContextIsCurrent(_ context: BrowserLinkContext) -> Bool {
		guard
			let page = pages[context.tabID],
			pageProfiles[context.tabID] == context.profileID,
			sessionRevisions[context.tabID] == context.sessionRevision,
			page.isPrivate == context.isPrivate,
			isVisibleForCapture(context.tabID)
		else { return false }

		let native = ChromiumLinkContext(
			pageID: page.identifier,
			token: context.token,
			documentGeneration: context.documentRevision,
			url: context.item.url,
			text: context.item.title,
			x: context.x,
			y: context.y
		)
		return runtime.linkContextIsCurrent(native, on: page)
	}

	/// DEV-890. Extensions' items for the link menu the app is showing.
	internal func appendLinkExtensionItems(
		_ context: BrowserLinkContext,
		to menu: AnyObject
	) -> Bool {
		guard linkContextIsCurrent(context), let page = pages[context.tabID]
		else { return false }

		return runtime.appendLinkExtensionItems(nativeLinkContext(context, page: page), on: page, to: menu)
	}

	private func nativeLinkContext(
		_ context: BrowserLinkContext,
		page: ChromiumPage
	) -> ChromiumLinkContext {
		ChromiumLinkContext(
			pageID: page.identifier,
			token: context.token,
			documentGeneration: context.documentRevision,
			url: context.item.url,
			text: context.item.title,
			x: context.x,
			y: context.y
		)
	}

	/// DEV-851. Download Linked File from the link's own frame with its page's referrer.
	internal func startLinkContextDownload(_ context: BrowserLinkContext) -> UInt64? {
		guard linkContextIsCurrent(context), let page = pages[context.tabID]
		else { return nil }

		return runtime.startLinkContextDownload(nativeLinkContext(context, page: page), on: page)
	}

	internal func linkContextDownload(
		_ context: BrowserLinkContext,
		request: UInt64
	) async throws -> BrowserDownload.ID {
		do {
			let guid = try await runtime.linkContextDownload(request)
			return .init(profileID: context.profileID, guid: guid)
		} catch ChromiumDownloadStartFailure.failed {
			throw BrowserDownloadsClient.Failure.couldNotStart
		} catch ChromiumDownloadStartFailure.timedOut {
			throw BrowserDownloadsClient.Failure.startTimedOut
		} catch {
			throw BrowserDownloadsClient.Failure.unavailable
		}
	}

	internal func inspectLinkContext(_ context: BrowserLinkContext) -> Bool {
		guard linkContextIsCurrent(context), let page = pages[context.tabID]
		else { return false }

		return runtime.inspectLinkContext(nativeLinkContext(context, page: page), on: page) == .opened
	}
}
