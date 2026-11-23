import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import Observation
import SwiftUI
import _ComposableArchitecture

extension BrowserEngineClient {
	/// Settings › General › Autofill (DEV-875). Cards always ask; the reasons finish
	/// macOS's "Arx is trying to …" prompt.
	@MainActor
	internal func configureAutofill(asksBeforeFillingPasswords: Bool) {
		setAutofillAuthentication(
			asksBeforeFillingPasswords ? .ask : .fillPasswordsWithoutAsking,
			String.localized(.appUI.autofill.passwordReason),
			String.localized(.appUI.autofill.cardReason)
		)
	}

	/// Settings › General › Autofill (DEV-893): addresses and cards, for ordinary profiles.
	@MainActor
	internal func configureAutofill(_ general: GeneralPreferences) {
		configureAutofill(asksBeforeFillingPasswords: general.asksBeforeFillingPasswords)
		setAutofillProducts(general.fillsAddresses, general.fillsPaymentCards)
	}
}

extension GeneralPreferences {
	/// Settings › General › Autofill's switches, observed together.
	internal var autofillSwitches: [Bool] {
		[asksBeforeFillingPasswords, fillsAddresses, fillsPaymentCards]
	}
}

/// Draws a tab's autofill suggestions (DEV-875, DEV-893) below its focused field, in
/// whichever window shows the tab: a main window, a Split View pane, Little Arx or a
/// Peek. The engine keeps the suggestions and every value; this only shows titles and
/// sends back the chosen index. Arrow keys, Return and Escape stay with the page and
/// reach the engine natively.
@MainActor
internal final class AutofillDropdown {
	private let store: StoreOf<AppFeature>
	private let client: BrowserEngineClient
	private let view: @MainActor (BrowserCore.Tab.ID) -> NSView?
	private let model: AutofillDropdownModel = .init()
	private var task: Task<Void, Never>?
	private var panel: AutofillPanel?
	private var shown: BrowserAutofillSuggestions?
	private var observers: [any NSObjectProtocol] = []

	internal init(
		store: StoreOf<AppFeature>,
		client: BrowserEngineClient,
		view: @escaping @MainActor (BrowserCore.Tab.ID) -> NSView?
	) {
		self.store = store
		self.client = client
		self.view = view
		model.accept = { [weak self] in self?.accept($0) }
		model.hover = { [weak self] in self?.hover($0) }
	}

	internal func start() {
		guard task == nil else { return }

		let events = client.autofillEvents()
		task = Task { @MainActor [weak self] in
			for await event in events {
				guard !Task.isCancelled else { break }
				self?.receive(event)
			}
		}
	}

	internal func stop() {
		task?.cancel()
		task = nil
		dismiss()
	}

	private func receive(_ event: BrowserAutofillEvent) {
		switch event {
		case let .shown(suggestions):
			present(suggestions)

		case let .hidden(tabID, session, open):
			guard shown?.tabID == tabID, shown?.session == session else { return }
			close()
			if let open { openSettings(open, tabID: tabID) }
		}
	}

	private func present(_ suggestions: BrowserAutofillSuggestions) {
		guard
			let view = view(suggestions.tabID),
			let window = view.window,
			window.isVisible, !window.isMiniaturized,
			!view.isHiddenOrHasHiddenAncestor,
			let frame = Self.frame(for: suggestions, in: view, window: window)
		else {
			// Nowhere to show them: the page keeps its field, the engine forgets them.
			client.dismissAutofillSuggestions(suggestions.tabID, suggestions.session)
			if shown?.tabID == suggestions.tabID { close() }
			return
		}

		if let shown, shown.tabID != suggestions.tabID {
			client.dismissAutofillSuggestions(shown.tabID, shown.session)
		}
		shown = suggestions
		model.items = suggestions.items
		model.selected = suggestions.selected

		let panel = self.panel ?? makePanel()
		if panel.parent !== window {
			panel.parent?.removeChildWindow(panel)
			observe(window)
			window.addChildWindow(panel, ordered: .above)
		}
		panel.setFrame(frame, display: true)
		panel.orderFront(nil)
	}

	private func accept(_ id: BrowserAutofillItem.ID) {
		guard let shown else { return }

		if !client.acceptAutofillSuggestion(shown.tabID, shown.session, id) {
			client.dismissAutofillSuggestions(shown.tabID, shown.session)
			close()
		}
	}

	private func hover(_ id: BrowserAutofillItem.ID?) {
		guard let shown else { return }

		model.selected = id
		client.selectAutofillSuggestion(shown.tabID, shown.session, id)
	}

	/// Closes the panel and tells the engine, for the app's own reasons.
	private func dismiss() {
		if let shown { client.dismissAutofillSuggestions(shown.tabID, shown.session) }
		close()
	}

	private func close() {
		shown = nil
		model.items = []
		model.selected = nil
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		observers.removeAll()
		guard let panel else { return }

		panel.parent?.removeChildWindow(panel)
		panel.orderOut(nil)
	}

	private func makePanel() -> AutofillPanel {
		let panel = AutofillPanel(content: NSHostingView(rootView: AutofillSuggestionList(model: model)))
		self.panel = panel
		return panel
	}

	/// The window going away, moving to the back or changing size ends the suggestions,
	/// as the page losing focus does.
	private func observe(_ window: NSWindow) {
		for observer in observers { NotificationCenter.default.removeObserver(observer) }
		observers = [
			NSWindow.didResignKeyNotification,
			NSWindow.willCloseNotification,
			NSWindow.didResizeNotification,
			NSWindow.didMiniaturizeNotification,
		].map { name in
			NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
				MainActor.assumeIsolated { self?.dismiss() }
			}
		}
	}

	private func openSettings(
		_ list: BrowserAutofillList,
		tabID: BrowserCore.Tab.ID
	) {
		let profileID = client.snapshot(tabID)?.nativeProfileID
			?? store.state.workspace.tabs.first(where: { $0.id == tabID })?.profileID
		store.send(.ui(.openSettings))
		guard let profileID else { return }

		switch list {
		case .passwords:
			store.send(.settings(.ui(.showSavedPasswords(profileID))))
		case .addresses, .cards:
			store.send(.settings(.ui(.showAutofill(profileID))))
		}
	}

	/// Below the field, or above it when the screen has no room below; never off screen.
	internal static func frame(
		for suggestions: BrowserAutofillSuggestions,
		in view: NSView,
		window: NSWindow
	) -> NSRect? {
		let field = suggestions.field
		let local = view.isFlipped
		? field
		: NSRect(x: field.minX, y: view.bounds.height - field.maxY, width: field.width, height: field.height)
		guard view.bounds.intersects(local) else { return nil }

		let anchor = window.convertToScreen(view.convert(local, to: nil))
		let size = AutofillSuggestionList.size(items: suggestions.items, fieldWidth: field.width)
		var origin = NSPoint(
			x: suggestions.isRightToLeft ? anchor.maxX - size.width : anchor.minX,
			y: anchor.minY - AutofillSuggestionList.gap - size.height
		)
		if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
			if origin.y < visible.minY { origin.y = anchor.maxY + AutofillSuggestionList.gap }
			origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
			origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
		}
		return NSRect(origin: origin, size: size)
	}
}

/// Never key: typing, arrows and Return stay with the page's field.
internal final class AutofillPanel: NSPanel {
	internal init(content: NSView) {
		super.init(
			contentRect: .zero,
			styleMask: [.borderless, .nonactivatingPanel],
			backing: .buffered,
			defer: true
		)
		isReleasedWhenClosed = false
		hidesOnDeactivate = true
		hasShadow = true
		isOpaque = false
		backgroundColor = .clear
		animationBehavior = .utilityWindow
		contentView = content
		setAccessibilityLabel(String.localized(.appUI.autofill.suggestions))
	}

	override internal var canBecomeKey: Bool { false }
	override internal var canBecomeMain: Bool { false }
}

@MainActor
@Observable
internal final class AutofillDropdownModel {
	internal var items: [BrowserAutofillItem] = []
	internal var selected: BrowserAutofillItem.ID?

	@ObservationIgnored
	internal var accept: (BrowserAutofillItem.ID) -> Void = { _ in }

	@ObservationIgnored
	internal var hover: (BrowserAutofillItem.ID?) -> Void = { _ in }
}

internal struct AutofillSuggestionList: View {
	internal static let gap: CGFloat = 4
	private static let padding: CGFloat = 5
	private static let rowHeight: CGFloat = 28
	private static let detailedRowHeight: CGFloat = 40
	private static let divider: CGFloat = 9
	private static let visibleRows: Int = 8

	internal let model: AutofillDropdownModel

	internal var body: some View {
		let entries = model.items.filter { !$0.isManage }
		let manage = model.items.filter(\.isManage)
		VStack(spacing: 0) {
			ScrollViewReader { proxy in
				ScrollView(.vertical) {
					VStack(spacing: 0) {
						ForEach(entries) { row($0).id($0.id) }
					}
				}
				.scrollIndicators(entries.count > Self.visibleRows ? .automatic : .never)

				// The arrow keys choose natively; keep their choice in view.
				.onChange(of: model.selected) { _, selected in
					guard let selected, entries.contains(where: { $0.id == selected }) else { return }
					proxy.scrollTo(selected)
				}
			}
			if !manage.isEmpty {
				Divider().padding(.vertical, 4)
				ForEach(manage) { row($0) }
			}
		}
		.padding(Self.padding)
		.background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: 10, style: .continuous)
				.strokeBorder(.separator, lineWidth: 0.5)
		}
		.accessibilityElement(children: .contain)
		.accessibilityLabel(Text(localized: .appUI.autofill.suggestions))
	}

	private func row(_ item: BrowserAutofillItem) -> some View {
		HStack(spacing: 8) {
			Image(systemName: item.symbol)
				.foregroundStyle(.secondary)
				.frame(width: 18)
			VStack(alignment: .leading, spacing: 1) {
				Text(verbatim: item.title)
					.lineLimit(1)
				if let subtitle = item.subtitle {
					Text(verbatim: subtitle)
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
			}
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 8)
		.frame(height: item.subtitle == nil ? Self.rowHeight : Self.detailedRowHeight)
		.background(
			model.selected == item.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear),
			in: .rect(cornerRadius: 6, style: .continuous)
		)
		.contentShape(.rect)
		.onHover { model.hover($0 ? item.id : nil) }
		.onTapGesture { model.accept(item.id) }
		.accessibilityElement(children: .combine)
		.accessibilityAddTraits(.isButton)
		.accessibilityAction { model.accept(item.id) }
	}

	internal static func size(
		items: [BrowserAutofillItem],
		fieldWidth: CGFloat
	) -> CGSize {
		let entries = items.filter { !$0.isManage }
		let manage = items.filter(\.isManage)
		let height = { (item: BrowserAutofillItem) in item.subtitle == nil ? rowHeight : detailedRowHeight }
		var total = entries.prefix(visibleRows).map(height).reduce(0, +)
		if !manage.isEmpty { total += divider + manage.map(height).reduce(0, +) }
		return CGSize(
			width: min(max(fieldWidth, 240), 420),
			height: total + padding * 2
		)
	}
}

extension BrowserAutofillItem {
	internal var isManage: Bool {
		if case .manage = kind { true } else { false }
	}

	internal var symbol: String {
		switch kind {
		case .password: "key.fill"
		case .address: "house"
		case .card: "creditcard"
		case .text: "clock.arrow.circlepath"
		case .undo: "arrow.uturn.backward"
		case .manage: "gearshape"
		}
	}
}
