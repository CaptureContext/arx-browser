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
	// MARK: - Autofill

	/// The page view a tab's autofill suggestions are anchored in.
	public func autofillView(_ id: Tab.ID) -> NSView? {
		guard let page = pages[id], !page.isPrivate, !page.isClosed else { return nil }
		return page.view
	}

	/// This engine's ordinary tabs' suggestions; the runtime is shared, so other
	/// engines' pages are skipped.
	internal func autofillEvents() -> AsyncStream<BrowserAutofillEvent> {
		let events = runtime.autofillEvents()
		return .init { continuation in
			let task = Task { @MainActor [weak self] in

				// The tab of each page with suggestions shown, so their hide still
				// arrives after the tab closed and left `pages`.
				var shown: [UInt64: Tab.ID] = [:]
				for await event in events {
					guard let self else { break }
					let live = pages.first(where: { $0.value.identifier == event.page && !$0.value.isPrivate })?.key
					switch event {
					case .shown:
						guard let live else { continue }
						shown[event.page] = live
						continuation.yield(Self.autofillEvent(event, tab: live))
					case .hidden:
						guard let tab = live ?? shown[event.page] else { continue }
						shown[event.page] = nil
						continuation.yield(Self.autofillEvent(event, tab: tab))
					}
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	internal static func autofillEvent(
		_ event: ChromiumAutofillEvent,
		tab: Tab.ID
	) -> BrowserAutofillEvent {
		switch event {
		case let .shown(native):
			return .shown(.init(
				tabID: tab,
				session: native.session,
				field: native.field,
				isRightToLeft: native.isRightToLeft,
				selected: native.selected,
				items: native.items.map { item in
					.init(id: item.index, kind: autofillKind(item.kind), title: item.title, subtitle: item.subtitle)
				}
			))
		case let .hidden(_, session, open):
			return .hidden(tab, session: session, open: open.map(autofillList))
		}
	}

	private static func autofillKind(_ kind: ChromiumAutofillItem.Kind) -> BrowserAutofillItem.Kind {
		switch kind {
		case .password: .password
		case .address: .address
		case .card: .card
		case .text: .text
		case .undo: .undo
		case .managePasswords: .manage(.passwords)
		case .manageAddresses: .manage(.addresses)
		case .manageCards: .manage(.cards)
		}
	}

	private static func autofillList(_ list: ChromiumAutofillEvent.SettingsList) -> BrowserAutofillList {
		switch list {
		case .passwords: .passwords
		case .addresses: .addresses
		case .cards: .cards
		}
	}
}
