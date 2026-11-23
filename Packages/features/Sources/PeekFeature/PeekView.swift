import AppUI
import BrowserCore
import BrowserSurfaceClient
import SwiftUI
import ViewerItemFeature
import _ComposableArchitecture

public struct PeekView: View {
	public let store: StoreOf<PeekFeature>
	private let surface: BrowserSurfaceClient

	@FocusState
	private var locationIsFocused: Bool

	@SwiftUI.State
	private var isEditingLocation: Bool

	public init(
		store: StoreOf<PeekFeature>,
		surface: BrowserSurfaceClient
	) {
		self.store = store
		self.surface = surface
		self._isEditingLocation = .init(initialValue: false)
	}

	public var body: some View {
		HStack(alignment: .top, spacing: BrowserMetrics.Peek.controlsSpacing) {
			page
			controls
		}
		.onChange(of: store.locationFocusRequest) { isEditingLocation = true }
		.disabled(store.phase != .idle)
		.accessibilityElement(children: .contain)
		.accessibilityLabel(String.localized(.appUI.peek.title))
	}

	/// Beside the page rather than above it, so the page keeps all of its own space.
	private var controls: some View {
		VStack(spacing: BrowserMetrics.Peek.Control.spacing) {
			control(String.localized(.appUI.peek.close), symbol: "xmark") {
				store.send(.ui(.close))
			}
			control(String.localized(.appUI.peek.openTab), symbol: "arrow.up.left.and.arrow.down.right") {
				store.send(.ui(.promote(.tab)))
			}
			control(
				store.isTemporary
				? String.localized(.appUI.peek.openLittle)
				: String.localized(.appUI.peek.existingLittleUnavailable),
				symbol: "macwindow"
			) {
				store.send(.ui(.promote(.littleArx)))
			}
			.disabled(!store.isTemporary)
			.accessibilityLabel(String.localized(.appUI.peek.openLittle))
		}
	}

	private func control(
		_ title: String,
		symbol: String,
		action: @escaping () -> Void
	) -> some View {
		Button(action: action) { Image(systemName: symbol) }
			.buttonStyle(BrowserPeekControlStyle(hint: title))
			.accessibilityLabel(title)
	}

	/// The address only takes room while it is being edited, from Peek's own location command.
	private var locationRow: some View {
		HStack(spacing: 8) {
			history(.back)
			history(.forward)
			TextField(
				String.localized(.appUI.peek.location),
				text: Binding(
					get: { store.location },
					set: { store.send(.ui(.locationChanged($0))) }
				)
			)
			.textFieldStyle(.plain)
			.focused($locationIsFocused)
			.onSubmit {
				store.send(.ui(.previewLocation))
				isEditingLocation = false
			}
			.onExitCommand { isEditingLocation = false }
			.onAppear { locationIsFocused = true }
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 8)
	}

	private var page: some View {
		VStack(spacing: 0) {
			// Only the rows above the page sit on the material (DEV-1173): the page allows vibrancy,
			// so on a material AppKit blends it into the material's gray instead of drawing it.
			if isEditingLocation || store.error != nil {
				VStack(spacing: 0) {
					if isEditingLocation { locationRow }
					if let error = store.error {
						Text(error)
							.foregroundStyle(.red)
							.padding(8)
					}
				}
				.frame(maxWidth: .infinity)
				.background(.regularMaterial)
			}
			ViewerItemView(
				store: store.scope(state: \.viewer, action: \.viewer),
				surface: surface
			)

				// Added to the host's, so a page in full screen elsewhere stays there (DEV-949).
				.transformEnvironment(\.suppressedBrowserTabs) { [phase = store.phase, tabID = store.tab.id] tabs in
					if phase == .releasing { tabs.insert(tabID) }
				}
				.environment(\.browserUnhandledEscape, unhandledEscape)
		}
		.clipShape(.rect(cornerRadius: BrowserMetrics.Peek.cornerRadius, style: .continuous))
		.overlay {
			RoundedRectangle(cornerRadius: BrowserMetrics.Peek.cornerRadius, style: .continuous)
				.strokeBorder(BrowserTheme.pageBorder, lineWidth: BrowserMetrics.PageCard.borderWidth)
				.allowsHitTesting(false)
		}
		.background {
			RoundedRectangle(cornerRadius: BrowserMetrics.Peek.cornerRadius, style: .continuous)
				.fill(BrowserTheme.page)
				.browserShadow(BrowserMetrics.Peek.shadow)
		}
	}

	private var unhandledEscape: BrowserUnhandledEscapeHandler {
		{ sourceIsCurrent in
			guard store.phase == .idle else { return false }

			let id = store.id
			let tabID = store.tab.id
			let generation = store.viewer.generation
			Task { @MainActor in
				guard
					sourceIsCurrent(),
					store.id == id,
					store.tab.id == tabID,
					store.viewer.generation == generation,
					store.phase == .idle
				else { return }

				store.send(.ui(.close))
			}
			return true
		}
	}

	private func history(
		_ direction: BrowserCore.BrowserNavigation.HistoryDirection
	) -> some View {
		let item = store.viewer
		return BrowserHistoryControl(
			navigation: item.navigation,
			direction: direction,
			navigate: { store.send(.viewer(.ui(.command(direction == .back ? .back : .forward)))) },
			select: { entryID in
				guard let tabID = item.tab?.id else { return }
				store.send(.viewer(.ui(.selectHistory(
					tabID: tabID,
					generation: item.generation,
					history: item.navigation.history,
					entryID: entryID
				))))
			}
		)
	}
}
