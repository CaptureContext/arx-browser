import AppUI
import BrowserCore
import BrowserSurfaceClient
import CommandBarFeature
import SwiftUI
import ViewerItemFeature
import _ComposableArchitecture

public struct LittleArxView: View {
	public struct Destination: Identifiable {
		public let id: Space.ID
		public let profileID: Profile.ID
		public let name: String
		public let menuTitle: String
		public let icon: String?

		public init(
			id: Space.ID,
			profileID: Profile.ID,
			name: String,
			menuTitle: String,
			icon: String? = nil
		) {
			self.id = id
			self.profileID = profileID
			self.name = name
			self.menuTitle = menuTitle
			self.icon = icon
		}
	}

	private let surface: BrowserSurfaceClient
	private let profiles: IdentifiedArrayOf<Profile>
	private let destinations: [Destination]
	private let onCommandHeightChange: (CGFloat) -> Void

	/// Where a drag moves the window while it's Page PiP (DEV-1112): Page PiP's throw.
	private let pictureInPictureDragArea: AnyView

	/// Page PiP's space picker (DEV-1184), every space as its Switch to Space shortcut shows it;
	/// empty keeps the profile picker.
	private let spaceOptions: [PagePictureInPictureSpacePicker.Option]
	public let store: StoreOf<LittleArxFeature>

	@SwiftUI.State
	private var isChoosingSpace: Bool

	public init(
		store: StoreOf<LittleArxFeature>,
		surface: BrowserSurfaceClient,
		profiles: IdentifiedArrayOf<Profile>,
		onCommandHeightChange: @escaping (CGFloat) -> Void,
		destinations: [Destination],
		pictureInPictureDragArea: AnyView = AnyView(LittleWindowDragArea()),
		spaceOptions: [PagePictureInPictureSpacePicker.Option] = []
	) {
		self.store = store
		self.pictureInPictureDragArea = pictureInPictureDragArea
		self.spaceOptions = spaceOptions
		self.surface = surface
		self.profiles = profiles
		self.onCommandHeightChange = onCommandHeightChange
		self.destinations = destinations
		self._isChoosingSpace = .init(initialValue: false)
	}

	public var body: some View {
		Group {
			if store.isCommandOnly {
				CommandBarView(
					store: store.scope(state: \.commandBar, action: \.commandBar),
					style: .launcher,
					profilePicker: launcherProfilePicker,
					onClose: { store.send(.commandBar(.ui(.dismissed))) }
				)

				// The bar moves by its background (DEV-1335): the field, the rows, Close and the two
				// pills keep their clicks above it. It moves in Arx's own event loop, since a window
				// server drag cost the bar the keyboard, which closes it.
				.background { WindowBackgroundDragArea() }

				// The panel draws its own corners, and its shadow needs the room around it (DEV-1277).
				.mask { Rectangle().padding(-BrowserMetrics.LittleArx.Launcher.panelPadding) }
				.padding(BrowserMetrics.LittleArx.Launcher.panelPadding)
				.fixedSize(horizontal: false, vertical: true)
				.onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
					onCommandHeightChange($0)
				}

			} else {
				browserBody
			}
		}
		.ignoresSafeArea()

		// The find bar's Previous and Next name the keys bound to them (DEV-1297).
		.environment(\.browserShortcuts, store.keyboardShortcuts)
		.task { store.send(.ui(.task)) }
	}

	private var browserBody: some View {
		GeometryReader { _ in
			ZStack {
				BrowserChromeBackground(textured: true).ignoresSafeArea()
				VStack(spacing: 0) {
					if store.isPictureInPicture {
						pictureInPictureHeader
					} else {
						toolbar
					}
					ViewerItemView(
						store: store.scope(state: \.viewer, action: \.viewer),
						surface: surface,
						showsLoading: false
					)

					// A card on the chrome, as the main window's page.
					.browserPageCard(cornerRadius: BrowserMetrics.LittleArx.pageCornerRadius)
					.padding([.horizontal, .bottom], BrowserMetrics.LittleArx.pageInset)
					if let error = store.error { Text(error).font(.callout).padding(8) }
				}
				.disabled(store.commandBar.isPresented || store.isPromoting || store.isSwitchingProfile)
			}

			// Page PiP is borderless, with Little Arx's corners drawn here (DEV-1112).
			.clipShape(.rect(
				cornerRadius: store.isPictureInPicture ? BrowserMetrics.LittleArx.cornerRadius : 0,
				style: .continuous
			))
		}
		.commandBarPresentation(
			isPresented: store.commandBar.isPresented,
			anchoredToURL: editsAddressInPlace,
			urlFieldText: editsAddressInPlace ? store.commandBar.query : "",
			urlFieldShowsAgentHint: editsAddressInPlace && store.commandBar.showsAgentHint,
			onDismiss: { store.send(.commandBar(.ui(.dismissed))) }
		) { maximumHeight in
			CommandBarView(
				store: store.scope(state: \.commandBar, action: \.commandBar),
				style: editsAddressInPlace ? .urlField : .palette,
				maximumResultsHeight: maximumHeight,
				onClose: { store.send(.commandBar(.ui(.dismissed))) }
			)
		}
		.overlay(alignment: .topTrailing) {
			if isChoosingSpace { spacePicker }
		}
		.ignoresSafeArea()
		.onChange(of: store.commandBar.isPresented) { _, value in
			if !value, store.peekID == nil { surface.focus(store.tab.id) }
		}
		.modifier(PromotionConfirmation(
			store: store,
			content: promotionConfirmation,
			asksInPlace: PagePictureInPictureSpacesFeatureFlag.isOn(),
			// Over the page the question took the keyboard; the page has it again (DEV-1184).
			onCancelled: { [surface, store] in
				if store.isPictureInPicture, store.peekID == nil { surface.focus(store.tab.id) }
			}
		))
	}

	/// The question before "Open in" a space of another profile (DEV-1184): where the page goes
	/// and that it reloads there without its sign-ins.
	private var promotionConfirmation: ProfileMoveConfirmation.Content? {
		guard
			let pending = store.pendingDestination,
			let destination = destinations.first(where: { $0.id == pending })
		else { return nil }

		return .init(
			subject: .tab,
			spaceName: destination.name,
			profileName: profiles[id: destination.profileID]?.name ?? ""
		)
	}

	private var toolbar: some View {
		LittleWindowHeader(
			leading: .windowControls,
			url: store.viewer.navigation.url,
			isLoading: store.viewer.navigation.isLoading,
			history: .back(store.viewer.navigation.canGoBack ? { store.send(.dispatchCommand(.goBack)) } : nil),
			onActivate: { store.send(.ui(.openCommand(.currentTab))) },
			onCopy: { store.send(.ui(.copyURL)) },
			readingMode: readingMode,
			profilePicker: { profilePicker },
			accessory: { promotionButton }
		)
		.environment(\.showsFullURL, profiles[id: store.tab.profileID]?.showsWholeURL ?? false)
	}

	/// Page PiP's header (DEV-1105) on this window (DEV-1112): Return to Tab turns it back into
	/// Little Arx, and the profile picker is Little Arx's own.
	private var pictureInPictureHeader: some View {
		PagePictureInPictureHeader(
			url: store.viewer.navigation.url,
			isLoading: store.viewer.navigation.isLoading,
			onReturnToTab: { store.send(.ui(.setPictureInPicture(false))) },
			onBack: store.viewer.navigation.canGoBack ? { store.send(.dispatchCommand(.goBack)) } : nil,
			onForward: store.viewer.navigation.canGoForward ? { store.send(.dispatchCommand(.goForward)) } : nil,
			// Its address edits as the main window's (DEV-1124).
			onActivate: PagePictureInPictureAddressFeatureFlag.isOn()
			? { store.send(.ui(.openCommand(.currentTab))) }
			: nil,
			onCopy: { store.send(.ui(.copyURL)) },
			// Floating keeps the window's page view, reader included (DEV-1028).
			readingMode: readingMode,
			profilePicker: {
				// As Page PiP's: the space it opens in, choosing one opens it there (DEV-1184).
				if PagePictureInPictureSpacesFeatureFlag.isOn(), !spaceOptions.isEmpty, store.peekID == nil {
					PagePictureInPictureSpacePicker(
						options: spaceOptions,
						currentID: store.spaceID,
						selectsCurrent: true,
						onSelect: { spaceID in
							guard let space = destinations.first(where: { $0.id == spaceID }) else { return }
							store.send(.ui(.promote(space.id, space.profileID)))
						}
					)
				} else {
					profilePicker
				}
			},
			dragArea: { pictureInPictureDragArea }
		)
		.environment(\.showsFullURL, profiles[id: store.tab.profileID]?.showsWholeURL ?? false)
	}

	/// As Page PiP, the address edits over its URL bar, as the main window's does (DEV-1124); Little
	/// Arx's own bar is a palette.
	private var editsAddressInPlace: Bool {
		store.isPictureInPicture && store.commandBar.mode == .currentTab
	}

	private var spacePicker: some View {
		ZStack(alignment: .topTrailing) {
			// Clear still has to catch the click that dismisses the list.
			Color.black.opacity(0.001)
				.contentShape(.rect)
				.onTapGesture { isChoosingSpace = false }
			LittleArxSpacePicker(
				destinations: destinations,
				currentSpaceID: store.spaceID,
				onSelect: { destination in
					isChoosingSpace = false
					store.send(.ui(.promote(destination.id, destination.profileID)))
				},
				onDismiss: { isChoosingSpace = false }
			)
			.padding(4)
		}
	}

	/// The page's reading mode, for the address bar (DEV-1028).
	private var readingMode: ReadingModeIndicator? {
		let viewer = store.viewer
		guard viewer.isReadable || viewer.reader != nil, store.state.commandContext.readingModeEnabled
		else { return nil }

		return .init(isReading: viewer.reader != nil) { [store] in store.send(.dispatchCommand(.readingMode)) }
	}

	private var profilePicker: some View {
		LittleWindowProfilePicker(
			options: profiles.map { profile in
				.init(
					id: profile.id,
					name: profile.name,
					isEnabled: destinations.contains { $0.profileID == profile.id }
				)
			},
			currentID: store.tab.profileID,
			onSelect: { store.send(.ui(.selectProfile($0))) }
		)
	}

	/// The launcher's profile picker (DEV-1331): the profile the page will open in, at the bar's
	/// bottom-left corner as Actions ⌘K's twin. Hidden with a single profile.
	private var launcherProfilePicker: CommandBarProfilePickerContent? {
		guard store.state.offersProfilePicker else { return nil }

		let current = profiles[id: store.tab.profileID]?.name ?? ""
		return .init(
			title: current,
			key: store.state.profilePickerKey,
			onToggle: { store.send(.ui(.profilePickerToggled)) },
			panel: store.profilePicker.map { picker in
				let options = launcherProfileOptions(matching: picker.query)
				return .init(
					title: current,
					query: Binding(
						get: { store.profilePicker?.query ?? "" },
						set: { store.send(.ui(.profilePickerQueryChanged($0))) }
					),
					selectedID: Binding(
						get: {
							let selected = store.profilePicker?.selectedID?.rawValue.uuidString
							return options.contains { $0.id == selected } ? selected : options.first?.id
						},
						set: { store.send(.ui(.profilePickerHighlighted($0))) }
					),
					actions: options,
					onSelect: { id in
						guard let uuid = UUID(uuidString: id) else { return }
						store.send(.ui(.launcherProfileSelected(.init(rawValue: uuid))))
					},
					onDismiss: { store.send(.ui(.profilePickerDismissed)) },
					onShortcut: { key in
						guard key == store.state.profilePickerKey else { return false }
						store.send(.ui(.profilePickerToggled))
						return true
					},
					searchPlaceholder: String.localized(.appUI.littleArx.searchProfiles),
					accessibilityLabel: String.localized(.appUI.littleArx.profile)
				)
			}
		)
	}

	/// The workspace's profiles with a space, filtered by what's typed; the current one checked.
	private func launcherProfileOptions(matching query: String) -> [CommandBarActionItem] {
		let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
		return store.launcherProfileIDs.compactMap { id -> CommandBarActionItem? in
			guard
				let profile = profiles[id: id],
				query.isEmpty || profile.name.localizedCaseInsensitiveContains(query)
			else { return nil }

			return .init(
				id: id.rawValue.uuidString,
				title: profile.name,
				symbol: id == store.tab.profileID ? "checkmark" : "person.crop.circle"
			)
		}
	}

	private var promotionButton: some View {
		let destination = destinations.first { $0.id == store.spaceID }
		return ChromeSplitButton(
			height: BrowserMetrics.LittleArx.addressHeight,
			moreHelp: String.localized(.appUI.profile.moveTitle),
			shortcut: destination.map { _ in .init("o", modifiers: .command) },
			action: destination.map { destination in
				{ store.send(.ui(.promote(destination.id, destination.profileID))) }
			},
			onMore: { isChoosingSpace.toggle() }
		) {
			if let destination {
				Text(localized: .appUI.littleArx.openIn(destination.name))
				ChromeKeyHint("⌘O")
			}
		}
	}
}

/// Little Arx's question before it opens its page in a space of another profile. With the
/// `ARX_PAGE_PIP_SPACES` feature flag (DEV-1184), it says plainly what happens, as a sheet on the
/// window, or over the page while the window is Page PiP, which has no title bar to hang a sheet
/// from. Off, it's the system's dialog, as before.
private struct PromotionConfirmation: ViewModifier {
	internal let store: StoreOf<LittleArxFeature>
	internal let content: ProfileMoveConfirmation.Content?
	internal let asksInPlace: Bool
	internal let onCancelled: () -> Void

	internal func body(content view: Content) -> some View {
		if asksInPlace {
			if store.isPictureInPicture {
				view.profileMoveConfirmationOverlay(content, onCancel: cancel, onConfirm: confirm)
			} else {
				view.profileMoveConfirmationSheet(content, onCancel: cancel, onConfirm: confirm)
			}
		} else {
			view.confirmationDialog(
				String.localized(.appUI.profile.moveTitle),
				isPresented: Binding(
					get: { store.pendingDestination != nil },
					set: { if !$0 { cancel() } }
				)
			) {
				Button(String.localized(.appUI.profile.moveConfirm), action: confirm)
			} message: { Text(localized: .appUI.profile.moveExplanation) }
		}
	}

	private func cancel() {
		store.send(.ui(.cancelPromotion))
		onCancelled()
	}

	private func confirm() {
		store.send(.ui(.confirmPromotion))
	}
}
