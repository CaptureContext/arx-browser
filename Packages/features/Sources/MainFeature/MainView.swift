import AppUI
import BrowserCore
import BrowserEngineClient
import BrowserSurfaceClient
import BrowserWorkspaceClient
import CommandBarFeature
import HistoryFeature
import SidebarFeature
import SwiftUI
import TabArchiveFeature
import ViewerFeature
import ViewerItemFeature
import _ComposableArchitecture

public struct MainView<DownloadsPanel: View, MediaPanel: View>: View {
	public let store: StoreOf<MainFeature>
	private let surface: BrowserSurfaceClient
	private let downloadsPanel: DownloadsPanel
	private let mediaPanel: MediaPanel

	/// The profile's chat panel, supplied by the app, which owns the chats.
	private let chatPanel: AnyView?

	/// The window's recent downloads, which the Library button fans out on hover, supplied by the app.
	private let recentDownloads: SidebarRecentDownloads?

	/// What a tab in the window plays, above the footer (DEV-906). Built by the app, which owns
	/// media; it reads media in its own view, so playback never renders the sidebar.
	private let mediaPlayer: AnyView?

	@SwiftUI.State
	private var creatingProfile: Bool

	@SwiftUI.State
	private var profileName: String

	/// Survives the Library's close, because the fade out still reads it.
	@SwiftUI.State
	private var libraryProgress: CGFloat

	@SwiftUI.State
	private var footerHintTimer: SidebarSpaceHintTimer

	@SwiftUI.State
	private var renamingSpace: Space?

	@SwiftUI.State
	private var spaceName: String

	@SwiftUI.State
	private var removingSpace: Space?

	/// Whether Delete Space asks where, and which spaces are marked for deletion (DEV-1336).
	@SharedReader(.iCloudRemoval)
	private var iCloudRemoval

	@SwiftUI.State
	private var pickingIconFor: Space.ID?

	/// Whether the icon picker or appearance panel was asked for from a column in the Library's
	/// Spaces page, which then opens it over that column's ⋯ rather than the footer's space.
	@SwiftUI.State
	private var spacePanelsInOverview: Bool

	@SwiftUI.State
	private var editingAppearanceFor: Space.ID?

	@Environment(\.showsOnlySidebar)
	private var showsOnlySidebar

	@SwiftUI.State
	private var appearancePreview: SpaceAppearancePreview?

	/// The open tab a sidebar row is dragging, so the page shows drop zones while it lasts.
	@SwiftUI.State
	private var draggedTabID: UUID?

	@SwiftUI.State
	private var pageStaging: MainPageStaging

	/// Which spaces the sidebar stands between, for the window's background to follow a swipe.
	@SwiftUI.State
	private var spaceReveal: SidebarSpaceReveal

	@Environment(\.browserChromeTint)
	private var chromeTint

	@Environment(\.browserFilmGrain)
	private var filmGrain

	@Environment(\.browserChromeAccent)
	private var chromeAccent

	@Environment(\.browserChromeMatchesSite)
	private var chromeMatchesSite

	/// The app's light or dark, outside the selected space's override that this view applies.
	@Environment(\.colorScheme)
	private var appColorScheme

	public init(
		store: StoreOf<MainFeature>,
		surface: BrowserSurfaceClient,
		chatPanel: AnyView? = nil,
		recentDownloads: SidebarRecentDownloads? = nil,
		mediaPlayer: AnyView? = nil,
		@ViewBuilder downloadsPanel: () -> DownloadsPanel,
		@ViewBuilder mediaPanel: () -> MediaPanel
	) {
		self.store = store
		self.surface = surface
		self.chatPanel = chatPanel
		self.recentDownloads = recentDownloads
		self.mediaPlayer = mediaPlayer
		self.downloadsPanel = downloadsPanel()
		self.mediaPanel = mediaPanel()
		self._libraryProgress = .init(initialValue: store.isLibraryOpen ? 1 : 0)
		self._footerHintTimer = .init(initialValue: .init())
		self._creatingProfile = .init(initialValue: false)
		self._profileName = .init(initialValue: "")
		self._spaceName = .init(initialValue: "")
		self._renamingSpace = .init(initialValue: nil)
		self._removingSpace = .init(initialValue: nil)
		self._pickingIconFor = .init(initialValue: nil)
		self._spacePanelsInOverview = .init(initialValue: false)
		self._editingAppearanceFor = .init(initialValue: nil)
		self._appearancePreview = .init(initialValue: nil)
		self._draggedTabID = .init(initialValue: nil)
		self._pageStaging = .init(initialValue: .init(store: store, surface: surface))
		self._spaceReveal = .init(initialValue: .init())
	}

	public var body: some View {
		// The query changes on every keystroke; only the host reads it, so the sidebar
		// and page subtree built here are not rebuilt while typing.
		MainCommandBarHost(store: store, content: chrome)

			// The footer picker's hint floats over the whole window, so the sidebar never clips it.
			.sidebarSpaceHintHost()

			// Sidebar drags draw their own preview, which changes shape with what it's over.
			.sidebarDragPreviewHost()

			// The homepage's guide names the person's own keys.
			.environment(\.browserShortcuts, store.keyboardShortcuts)

			// ⌃Tab's switcher over the whole window (DEV-544), drawn by its own view so walking it
			// renders nothing else.
			.overlay { MainTabSwitcherHost(store: store) }
			.disabled(store.isClosing || store.archive.isWorking || store.transferInProgress)
			.sheet(isPresented: Binding(
				get: { store.movePicker != nil },
				set: { if !$0 { store.send(.ui(.dismissMovePicker)) } }
			)) {
				if let picker = store.movePicker {
					TabMovePickerView(
						picker: picker,
						onChoose: { store.send(.ui(.chooseMoveDestination($0, $1))) },
						onCancel: { store.send(.ui(.dismissMovePicker)) }
					)
				}
			}
			.sheet(isPresented: Binding(
				get: { store.archive.isPresented },
				set: { if !$0 { store.send(.archive(.ui(.dismissed))) } }
			)) {
				TabArchiveView(store: store.scope(state: \.archive, action: \.archive))
					.interactiveDismissDisabled(store.archive.isWorking)
			}
			.onChange(of: store.commandBar.isPresented) { _, presented in
				guard !presented else { return }

				// An open Find bar keeps the keyboard (DEV-1222): ⌘F from the URL bar gives its
				// field focus, which closes the URL bar, and the page mustn't take it back.
				if store.viewer.item.findQuery != nil {
					store.send(.viewer(.panes(.element(id: store.viewer.activePaneID, action: .item(.ui(.findPresented))))))
				} else if let id = store.viewer.item.tab?.id {
					surface.focus(id)
				}
			}
			.sheet(isPresented: $creatingProfile) {
				ProfileCreationView(
					name: $profileName,
					onCancel: { creatingProfile = false },
					onCreate: {
						guard creatingProfile else { return }
						creatingProfile = false
						store.send(.sidebar(.ui(.createProfile(profileName))))
					}
				)
			}
			.alert(String.localized(.appUI.management.renameSpace), isPresented: isPresented($renamingSpace)) {
				TextField(String.localized(.appUI.common.name), text: $spaceName)
				Button(String.localized(.appUI.common.cancel), role: .cancel) {}
				Button(String.localized(.appUI.common.save)) {
					if let space = renamingSpace {
						update(space, name: spaceName)
					}
				}
				.disabled(spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
			.confirmationDialog(
				String.localized(.appUI.management.removeSpace),
				isPresented: isPresented($removingSpace),
				presenting: removingSpace
			) { space in
				if asksWhereToRemove(space) {
					// The safe choice is the default: the other Macs keep the space.
					Button(String.localized(.appUI.management.deleteFromThisMacOnly), role: .destructive) {
						store.send(.ui(.removeSpace(space.id, keepingElsewhere: true)))
					}
					.keyboardShortcut(.defaultAction)
					Button(String.localized(.appUI.management.removeFromIcloud), role: .destructive) {
						store.send(.ui(.removeSpace(space.id, keepingElsewhere: false)))
					}
				} else {
					Button(String.localized(.appUI.management.removeSpace), role: .destructive) {
						store.send(.ui(.changeOrganization(.removeSpace(space.id))))
					}
				}
			} message: { space in
				Text(localized: .appUI.management.removeSpaceDetail)
				if asksWhereToRemove(space) {
					Text(localized: .appUI.management.removeWhereDetail)
				}
			}
			.modifier(ProfileMoveQuestion(store: store, destination: pendingMoveDestination))
			.ignoresSafeArea()

			// An empty pane's see-through card turns with a swipe too (DEV-1310).
			.environment(\.browserPageReveal, .init(reveal: spaceReveal) { [store] id in
				store.sidebar.organization.appearance(ofSpace: .init(rawValue: id))
			})
			.appearanceOverride(
				store.sidebar.organization.appearance(ofSpace: store.sidebar.spaceID, preview: appearancePreview),
				transitionKey: store.sidebar.spaceID.rawValue,
				siteColor: MatchSiteBackground.isEnabled() ? store.siteChromeColor : nil
			)
	}

	/// The window's sidebar setting, or pinned while a page in full screen shows it (DEV-991).
	private var isSidebarPinned: Bool {
		store.sidebar.sidebarIsVisible || showsOnlySidebar
	}

	private var pendingMoveDestination: (profile: Profile, space: Space)? {
		guard
			let move = store.pendingTabMove,
			let space = move.plan.updated.spaces[id: move.plan.destination],
			let profile = move.plan.updated.profiles[id: space.profileID]
		else { return nil }
		return (profile, space)
	}

	private var chrome: some View {
		GeometryReader { _ in
			ZStack {
				// The window is see-through for it only with the flag on (DEV-1286), as it opened.
				BrowserChromeBackground(textured: true, isTranslucent: TranslucentChrome.isEnabledForThisLaunch)

					// It turns to the next space's as far as a swipe has the sidebar toward it (DEV-1310).
					.environment(\.browserChromeReveal, .init(reveal: spaceReveal) { [store] id in
						store.sidebar.organization.appearance(ofSpace: .init(rawValue: id))
					})
					.ignoresSafeArea()
				BrowserSidebarLayout(
					isPinned: isSidebarPinned,
					isSuspended: store.commandBar.isPresented,
					keepsSidebarRevealed: store.commandBar.mode == .currentTab,
					libraryProgress: $libraryProgress,
					// Not tied to being open, so the page leaves the window 1:1 with the swipe that opens the section.
					libraryFillsWindow: store.state.libraryPanel == .spaces,
					chromeIsTranslucent: TranslucentChrome.isEnabledForThisLaunch,
					width: store.sidebarWidth,
					onWidthCommitted: { store.send(.ui(.sidebarWidthCommitted($0))) }
				) {
					VStack(spacing: 0) {
						// Each space's page reads its own tabs, and only the toolbar's buttons read the
						// navigation, so neither a load nor another space's tabs re-render this.
						SidebarPager(
							spaces: store.sidebar.sidebarSpaceSummaries,
							selectedSpaceID: store.sidebar.spaceID.rawValue,
							space: { [store] in store.sidebar.sidebarSpace(.init(rawValue: $0)) },
							navigation: { navigation },
							isNewTabPending: store.commandBar.isPresented && store.commandBar.mode == .newTab,
							splitIDs: store.state.splitTabIDs,
							canClearTabs: !store.isPrivate,
							library: .init(
								isOpen: store.isLibraryOpen,
								progress: $libraryProgress,
								sections: store.state.librarySections,
								selection: store.state.libraryPanel,
								setOpen: { store.send(.ui(.libraryOpenChanged($0))) },
								select: { store.send(.ui(.librarySectionSelected($0))) }
							),
							spaceMenu: { id in
								AnyView(spaceMenuContent(id, offersManage: true))
							},
							profileMenu: canMoveSpacesBetweenProfiles ? { id in AnyView(profileMoveMenu(id)) } : nil,
							canRenameSpaces: !store.isPrivate,
							spaceCreation: spaceCreation,
							spaceReselections: store.sidebar.spaceReselections,
							reveal: spaceReveal,
							spaceAppearance: { [store] id in
								store.sidebar.organization.appearance(ofSpace: .init(rawValue: id))
							},
							onSelectSpace: { store.send(.sidebar(.ui(.spaceSelected(.init(rawValue: $0))))) },
							onRevealSpace: { [pageStaging] in pageStaging.reveal($0, isLanding: $1) },
							onAction: sidebarAction,
							onCopyURL: { store.send(.ui(.copyURL)) }
						) {
							// The footer reads the organization and its menu the page's commands, so
							// neither reaches the chrome.
							VStack(spacing: 0) {
								if let mediaPlayer {
									mediaPlayer
										.padding(.horizontal, BrowserMetrics.Sidebar.horizontalPadding)
										.padding(.bottom, 4)
								}
								MainLeaf { spaceSwitcher }
							}
						} libraryPanel: {
							switch store.state.libraryPanel {
							case .media:
								mediaPanel

							case .downloads:
								downloadsPanel

							case .spaces:
								// Every space's tabs, read apart from the window's chrome.
								MainLeaf {
									SidebarSpacesOverview(
										spaces: store.sidebar.sidebarSpaces,
										canEdit: !store.isPrivate,
										spaceMenu: { id in AnyView(spaceMenuContent(id, offersManage: false)) },
										menuAnchor: { id in AnyView(overviewMenuAnchor(id)) },
										appearance: { id in
											store.sidebar.organization.appearance(ofSpace: .init(rawValue: id), preview: appearancePreview)
										},
										globalAppearance: .init(tint: chromeTint, grain: .init(filmGrain), accent: chromeAccent, matchesSite: chromeMatchesSite),
										globalColorScheme: appColorScheme,
										profileMenu: { id in AnyView(columnProfile(id)) },
										onAction: overviewAction,
										onChangeIcon: { id, icon in
											if let space = store.sidebar.organization.spaces.first(where: { $0.id.rawValue == id }) {
												setIcon(icon, of: space)
											}
										},
										onMoveSpace: { id, before in
											store.send(.ui(.changeOrganization(.moveSpace(
												.init(rawValue: id),
												before: before.map { .init(rawValue: $0) }
											))))
										}
									)
								}

							case .history:
								HistoryPanelView(store: store.scope(state: \.historyPage, action: \.historyPage))

							case .archive:
								TabArchivePanelView(store: store.scope(state: \.archive, action: \.archive))

							case nil:
								EmptyView()
							}
						}
					}

					// Resets of pins shake their rows (DEV-1225).
					.environment(\.sidebarResetPulses, store.sidebar.resetPulses)
					.modifier(MainSiteMenuEnvironment(store: store))
				} page: {
					MainChatPanelRow(
						isOpen: store.isChatOpen && chatPanel != nil,
						width: store.chatWidth,
						onWidthCommitted: { store.send(.ui(.chatWidthCommitted($0))) }
					) {
						ViewerView(
							store: store.scope(state: \.viewer, action: \.viewer),
							surface: surface,
							draggedTabID: draggedTabID,
							dropRefusal: { id, edge in
								store.state.viewerDropRefusal(.init(rawValue: id), edge: edge, checksOwnership: false)
							},
							onDropTab: { id, edge in
								draggedTabID = nil
								store.send(.ui(.dropTabInViewer(.init(rawValue: id), edge)))
							},
							onOpenEmptyPane: { store.send(.ui(.paneCommand(.newTab, $0))) },
							onEditAddress: { store.send(.ui(.paneCommand(.address, $0))) },
							onCopyURL: { store.send(.ui(.paneCommand(.copyURL, $0))) },
							showsDeveloperHeader: store.showsDeveloperHeader,
							deviceCapture: store.deviceCaptureEnabled ? store.deviceCaptureStyle : nil,
							onDeveloperHeader: { store.send(.ui(.developerHeader($0, $1))) }
						)
						.modifier(MainSiteMenuEnvironment(store: store))
						.overlay {
							MainPageStage(staging: pageStaging)
						}

						// The window's pop-ups centre on the page, not the window (DEV-1260).
						.pagePopupArea()
					} panel: {
						chatPanel
					}
					.padding([.top, .bottom, .trailing], BrowserMetrics.PageCard.inset)
					.padding(.leading, isSidebarPinned ? 0 : BrowserMetrics.PageCard.inset)

					// Under a page in full screen, only the sidebar beside it is there to use.
					.allowsHitTesting(!showsOnlySidebar)
					.accessibilityHidden(showsOnlySidebar)
				}
				.disabled(store.commandBar.isPresented)
				.accessibilityHidden(store.commandBar.isPresented)
				.environment(\.sidebarTabDragChanged) { id in

					// A new drag, so a press that selected this tab knows which drag is its own.
					if let id, id != draggedTabID { store.send(.ui(.tabDragStarted(.init(rawValue: id)))) }
					draggedTabID = id
				}
				.environment(\.sidebarTabDroppedOutside) { id, point in
					store.send(.ui(.dropTabOutsideWindows(.init(rawValue: id), point)))
				}
				.environment(\.sidebarTabHoverChanged) { [pageStaging] in pageStaging.hover($0) }
				.onChange(of: store.sidebar.spaceID) { [pageStaging] _, id in pageStaging.spaceSelected(id) }
				.environment(\.splitPaneLimits, .init(
					horizontal: store.viewer.capacity.horizontal,
					vertical: store.viewer.capacity.vertical
				))
				Color.clear
					.allowsHitTesting(false)
					.modifier(SidebarNoticeToast(store: store))
			}
		}
	}

	private var navigation: SidebarNavigation {
		let snapshot = store.viewer.item.navigation
		let generation = store.viewer.item.generation
		let paneID = store.viewer.activePaneID
		let tabID = store.viewer.item.tab?.id
		return .init(
			canGoBack: snapshot.canGoBack,
			canGoForward: snapshot.canGoForward,
			isLoading: snapshot.isLoading,
			isAvailable: store.viewer.item.tab != nil,
			history: snapshot,
			selectHistory: { entryID in
				guard let tabID else { return }
				store.send(.viewer(.panes(.element(
					id: paneID,
					action: .item(.ui(.selectHistory(
						tabID: tabID,
						generation: generation,
						history: snapshot.history,
						entryID: entryID
					)))
				))))
			},
			back: { navigate(.back, paneID: paneID, tabID: tabID) },
			forward: { navigate(.forward, paneID: paneID, tabID: tabID) },
			reloadOrStop: { navigate(snapshot.isLoading ? .stop : .reload, paneID: paneID, tabID: tabID) }
		)
	}

	private func navigate(
		_ command: BrowserEngineClient.Command,
		paneID: UUID,
		tabID: BrowserCore.Tab.ID?
	) {
		guard let tabID else { return }
		store.send(.viewer(.command(command, in: paneID, tabID: tabID)))
	}

	private func sidebarAction(
		_ spaceID: UUID,
		_ action: SidebarAction
	) {
		if case let .moveItems(ids, target) = action {
			store.send(.sidebar(.ui(.moveItems(ids, target, .init(rawValue: spaceID)))))
			return
		}
		if case let .move(id, target) = action {
			store.send(.sidebar(.ui(.move(id, target, .init(rawValue: spaceID)))))
			return
		}
		if case .openCommandBar = action {
			store.send(.ui(.openCommand(.currentTab)))
			return
		}

		// A tab's sound belongs to the tab wherever it is, so it never switches the space (DEV-800),
		// nor does choosing its unread badges (DEV-1258) or keeping its site loaded (DEV-932).
		if action.is(\.setMuted) || action.is(\.setVolume) || action.is(\.setTabUnreadBadges)
			|| action.is(\.setSiteKeptLoaded) || action.is(\.keepAgentTab)

			// Nor does a tab's icon, which a Favorite on another space's page can change (DEV-1251).
			|| action.is(\.changeIcon) || action.is(\.dismissIconPicker) || action.is(\.setIcon)
		{
			store.send(.sidebar(.ui(.sidebar(action))))
			return
		}
		if case let .renameSpace(name) = action {
			if let space = store.sidebar.organization.spaces.first(where: { $0.id.rawValue == spaceID }) {
				update(space, name: name)
			}
			return
		}
		if store.sidebar.spaceID.rawValue != spaceID {
			store.send(.sidebar(.ui(.spaceSelected(.init(rawValue: spaceID)))))
		}
		if case let .duplicate(id) = action {
			store.send(.sidebar(.ui(.sidebar(.select(id)))))
			store.send(.ui(.duplicateTab))
			return
		}
		if case let .addSplit(.tab(id)) = action {
			store.send(.ui(.splitTab(.init(rawValue: id))))
			return
		}
		if case .clearTabs = action {
			store.send(.ui(.archiveSelectedTabs(store.sidebar.windowOpenTabs)))
			return
		}
		store.send(.sidebar(.ui(.sidebar(action))))
	}

	private var spaceSwitcher: some View {
		HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
			SidebarLibraryButton(
				isOpen: store.isLibraryOpen,
				title: BrowserCommand.toggleLibrary.title,
				// As the user bound it, so a rebound shortcut shows in the hint.
				shortcut: store.keyboardShortcuts.shortcut(for: .toggleLibrary)?.keyCaps ?? [],
				recentDownloads: store.downloadsAvailable ? recentDownloads : nil
			) {
				store.send(.ui(.libraryOpenChanged(!store.isLibraryOpen)))
			}

			// Left click belongs to the Library, so its older commands move to the secondary click.
			// Its commands follow the page's navigation, so they're read in a view of their own.
			.contextMenu { MainLeaf { libraryMenu } }
			.accessibilityHint(String.localized(.appUI.sidebar.libraryHelp))
			spaceButtons
			SidebarCreateButton(help: String.localized(.appUI.sidebar.newTab), sections: createSections)
		}

		// One hint timer for the footer, so a showing hint moves straight between the Library and the spaces.
		.environment(\.sidebarFooterHintTimer, footerHintTimer)
		.buttonStyle(.plain)
		.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize - 2, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, 14)
		.frame(height: BrowserMetrics.SpaceSwitcher.height)

		// Above the whole footer, so the Library's hint and the spaces' sit at the same height.
		.sidebarFooterHintRow()
	}

	@ViewBuilder
	private var libraryMenu: some View {
		Button(String.localized(.appUI.sidebar.newFolder)) {
			store.send(.sidebar(.ui(.sidebar(.newFolder(nil)))))
		}
		Button(String.localized(.appUI.sidebar.newSpace)) { store.send(.sidebar(.ui(.newSpace))) }
		Divider()
		if store.mediaAvailable, !store.isPrivate {
			Button(String.localized(.appUI.media.title)) { store.send(.ui(.openLibrary(.media))) }
		}
		if store.downloadsAvailable {
			Button(String.localized(.appUI.downloads.title)) { store.send(.delegate(.command(.downloads))) }
			Divider()
		}
		Button(BrowserCommand.showHistory.title) { store.send(.ui(.openLibrary(.history))) }
			.disabled(store.isPrivate)
		Button(String.localized(.appUI.archive.title)) { store.send(.ui(.openArchive)) }
			.disabled(store.isPrivate)
		Button(String.localized(.appUI.archive.reopenLast)) { store.send(.ui(.reopenLastClosedTab)) }
			.disabled(store.isPrivate)
		Button(String.localized(.appUI.archive.selected)) { store.send(.ui(.archiveSelectedTabs([]))) }
			.disabled(!BrowserCommand.archiveSelectedTabs.isEnabled(in: store.commandContext))
		Button(String.localized(.appUI.archive.allInSpace)) {
			store.send(.ui(.archiveSelectedTabs(store.sidebar.windowOpenTabs)))
		}
		.disabled(store.isPrivate || store.sidebar.windowOpenTabs.isEmpty)
		Divider()
		Menu(String.localized(.appUI.split.title)) {
			Button(String.localized(.appUI.split.newPane)) { store.send(.ui(.splitTab(nil))) }
				.disabled(!store.state.canAddSplitPane)
			ForEach(store.state.presentableTabs) { tab in
				Button(tab.displayTitle) { store.send(.ui(.splitTab(tab.id))) }
					.disabled(!store.state.canAddSplitPane && !store.viewer.panes.contains { $0.item.tab?.id == tab.id })
			}
			Divider()
			Button(String.localized(.appUI.split.focusOther)) { store.send(.ui(.focusOtherPane)) }
				.disabled(!store.viewer.isSplit)
			Button(String.localized(.appUI.split.swap)) { store.send(.ui(.swapPanes)) }
				.disabled(!store.viewer.isSplit)
			Button(String.localized(.appUI.split.orientation)) { store.send(.ui(.toggleSplitOrientation)) }
				.disabled(!store.viewer.isSplit)
			Button(String.localized(.appUI.split.closePane)) { store.send(.ui(.closePane)) }
				.disabled(!store.viewer.isSplit)
		}
		Divider()
		Menu(String.localized(.appUI.profile.profiles)) {
			Button(String.localized(.appUI.profile.create)) {
				profileName = ""
				creatingProfile = true
			}
			.disabled(store.isPrivate)
		}
		Button(String.localized(.appUI.move.choose)) {
			store.send(.sidebar(.ui(.sidebar(.chooseMoveDestination(nil)))))
		}
		.disabled(
			(store.sidebar.selectedTab == nil && store.sidebar.moveSelection.isEmpty)
			|| store.transferInProgress
		)
	}

	private func isPresented<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
		Binding(
			get: { value.wrappedValue != nil },
			set: { if !$0 { value.wrappedValue = nil } }
		)
	}

	private func update(
		_ space: Space,
		name: String? = nil,
		profileID: Profile.ID? = nil,
		icon: SpaceIcon? = nil
	) {
		store.send(.ui(.changeOrganization(.updateSpace(
			space.id,
			profileID: profileID ?? space.profileID,
			name: name ?? space.name,
			icon: icon ?? space.icon
		))))
	}

	/// A nil icon is the picker's reset: the space shows a dot again (DEV-1251).
	private func setIcon(
		_ icon: SpaceIcon?,
		of space: Space
	) {
		store.send(.ui(.changeOrganization(.updateSpace(
			space.id,
			profileID: space.profileID,
			name: space.name,
			icon: icon
		))))
	}

	/// Using a column keeps the Library open, even though acting on a space first selects it.
	private func overviewAction(
		_ spaceID: UUID,
		_ action: SidebarAction
	) {
		sidebarAction(spaceID, action)
		switch action {
		case .select, .selectOnPress:
			store.send(.ui(.libraryOpenChanged(false)))
		case .pressCompleted:
			// The press already selected and closed the Library; its click changes nothing more.
			break
		default:
			store.send(.ui(.libraryOpenChanged(true)))
		}
	}

	/// Swiping past the last space offers Create a Space (DEV-1109), except in a private window,
	/// whose spaces are its own.
	private var spaceCreation: SidebarSpaceCreation? {
		guard !store.isPrivate else { return nil }
		return .init(
			profiles: store.sidebar.organization.profiles.map { profile in
				.init(id: profile.id.rawValue, name: profile.name, appearance: profile.appearance)
			},
			// As the space appearance panel resolves it: the app's, not the shown space's.
			global: .init(tint: chromeTint, grain: .init(filmGrain)),
			create: { [store] name, profileID, appearance in
				store.send(.sidebar(.ui(.createSpace(name: name, profileID: .init(rawValue: profileID), appearance: appearance))))
			}
		)
	}

	private var canMoveSpacesBetweenProfiles: Bool {
		!store.isPrivate && store.sidebar.organization.profiles.count > 1
	}

	/// The capsule's menu: every other profile the current space can move to.
	@ViewBuilder
	private func profileMoveMenu(_ id: UUID) -> some View {
		if let space = store.sidebar.organization.spaces.first(where: { $0.id.rawValue == id }) {
			Section(String.localized(.appUI.sidebar.moveSpaceToProfile)) {
				ForEach(store.sidebar.organization.profiles.filter { $0.id != space.profileID }) { profile in
					Button(profile.name) {
						store.send(.ui(.moveSpaceToProfile(space.id, profile.id)))
					}
				}
			}
			.disabled(store.transferInProgress)
		}
	}

	@ViewBuilder
	private func columnProfile(_ id: UUID) -> some View {
		if let space = store.sidebar.organization.spaces.first(where: { $0.id.rawValue == id }) {
			Menu {
				profileChoices(space)
			} label: {
				SidebarProfileLabel(name: store.sidebar.organization.profiles[id: space.profileID]?.name ?? "")
			}
			.menuStyle(.button)
			.buttonStyle(.plain)
			.menuIndicator(.hidden)
			.fixedSize()
			.disabled(store.isPrivate || store.sidebar.organization.profiles.count < 2)
		}
	}

	@ViewBuilder
	private func profileChoices(_ space: Space) -> some View {
		ForEach(store.sidebar.organization.profiles) { profile in
			Toggle(profile.name, isOn: Binding(
				get: { profile.id == space.profileID },
				set: { _ in
					if profile.id != space.profileID {
						store.send(.ui(.moveSpaceToProfile(space.id, profile.id)))
					}
				}
			))
		}
	}

	@ViewBuilder
	private func spaceMenuContent(
		_ id: UUID,
		offersManage: Bool
	) -> some View {
		if let space = store.sidebar.organization.spaces.first(where: { $0.id.rawValue == id }) {
			spaceMenu(space, offersManage: offersManage)
		}
	}

	private var createSections: [[SidebarCreateItem]] {
		func shortcut(_ command: BrowserCommand) -> String? {
			CommandBarFeature.Entry.command(command, bindings: store.keyboardShortcuts).presentation.shortcut
		}
		return [
			[
				.init(
					title: BrowserCommand.newSpace.title,
					symbol: BrowserCommand.newSpace.symbol,
					shortcut: shortcut(.newSpace)
				) {
					store.send(.sidebar(.ui(.newSpace)))
				},
				.init(
					title: BrowserCommand.newFolder.title,
					symbol: "folder",
					shortcut: shortcut(.newFolder)
				) {
					store.send(.sidebar(.ui(.sidebar(.newFolder(nil)))))
				},
			],
			[
				.init(
					title: BrowserCommand.newSplit.title,
					symbol: BrowserCommand.newSplit.symbol,
					shortcut: shortcut(.newSplit),
					isEnabled: store.state.canAddSplitPane
				) {
					store.send(.ui(.splitTab(nil)))
				},
				.init(
					title: BrowserCommand.newTab.title,
					symbol: "plus.square",
					shortcut: shortcut(.newTab)
				) {
					store.send(.ui(.openCommand(.newTab)))
				},
			],
		]
	}

	@ViewBuilder
	private func spaceMenu(
		_ space: Space,
		offersManage: Bool = true
	) -> some View {
		Button(String.localized(.appUI.management.changeIcon)) {
			// The Spaces page's columns are the only menus without Manage Spaces.
			spacePanelsInOverview = !offersManage
			pickingIconFor = space.id
		}
			.disabled(store.isPrivate)
		Button(String.localized(.appUI.management.renameSpaceMenu)) {
			spaceName = space.name
			renamingSpace = space
		}
		.disabled(store.isPrivate)
		Menu(String.localized(.appUI.management.setProfile)) {
			profileChoices(space)
		}
		.disabled(store.isPrivate || store.sidebar.organization.profiles.count < 2)
		Button(String.localized(.appUI.appearance.edit)) {
			spacePanelsInOverview = !offersManage
			editingAppearanceFor = space.id
		}
			.disabled(store.isPrivate)
		Divider()
		Button(String.localized(.appUI.sidebar.newFolder)) {
			sidebarAction(space.id.rawValue, .newFolder(nil))
		}
		if offersManage, store.state.librarySections.contains(.spaces) {
			Divider()
			Button(String.localized(.appUI.management.manageSpaces)) {
				store.send(.ui(.manageSpaces))
			}
		}
		if iCloudRemoval.marked[space.id.rawValue] != nil {
			Divider()
			Button(String.localized(.appUI.management.removeHereToo), role: .destructive) {
				store.send(.ui(.changeOrganization(.removeSpace(space.id))))
			}
			.disabled(store.isPrivate || store.sidebar.organization.spaces.count == 1)
			Button(String.localized(.appUI.management.keepMarked)) {
				store.send(.ui(.keepMarkedSpace(space.id)))
			}
		}
		Divider()
		Button(String.localized(.appUI.management.removeSpace), role: .destructive) {
			removingSpace = space
		}
		.disabled(store.isPrivate || store.sidebar.organization.spaces.count == 1)
	}

	/// Whether Delete Space asks to delete `space` from this Mac only or remove it from iCloud: another
	/// Mac syncs Profiles and spaces, its profile isn't "this Mac only", and no Mac removed it from
	/// iCloud yet (DEV-1336).
	private func asksWhereToRemove(_ space: Space) -> Bool {
		iCloudRemoval.asksWhere

		// Another Mac already removed it from iCloud: deleting it here agrees.
		&& iCloudRemoval.marked[space.id.rawValue] == nil
		&& store.sidebar.organization.profiles[id: space.profileID]?.isThisMacOnly != true
	}

	/// The footer's spaces, in the Library's order: dragging one sends the same move as the Library.
	private var spaceButtons: some View {
		SidebarSpacePicker(
			spaces: spacePickerEntries,
			selectedID: store.isLibraryOpen ? nil : store.sidebar.spaceID.rawValue,
			canReorder: !store.isPrivate,
			onMove: { id, before in
				store.send(.ui(.changeOrganization(.moveSpace(
					.init(rawValue: id),
					before: before.map { .init(rawValue: $0) }
				))))
			}
		) { pickerSpace, state in
			spaceButton(.init(rawValue: pickerSpace.id), state: state)
		}
	}

	/// Each space with its icon and profile, for the picker's drag preview and hint.
	private var spacePickerEntries: [SidebarSpacePickerEntry] {
		let organization = store.sidebar.organization
		let bindings = store.keyboardShortcuts
		return organization.spaces.enumerated().map { index, space in
			SidebarSpacePickerEntry(
				id: space.id.rawValue,
				name: space.name,
				symbol: (space.icon ?? .dot).rawValue,
				profileName: organization.profiles[id: space.profileID]?.name,
				// The key that switches to this space, as the user bound it.
				shortcut: BrowserCommand.switchToSpace(index + 1)
					.flatMap { bindings.shortcut(for: $0) }?
					.keyCaps ?? []
			)
		}
	}

	/// The space's icon picker and appearance panel, where `isHere` says this anchor shows them.
	private func spacePanels(_ space: Space) -> (Bool) -> AnyView {
		{ isHere in
			AnyView(
				Color.clear
					.spaceIconPicker(
						isPresented: Binding(
							get: { isHere && pickingIconFor == space.id },
							set: { if !$0 { pickingIconFor = nil } }
						),
						selection: space.icon,
						onReset: { setIcon(nil, of: space) }
					) { setIcon($0, of: space) }

					// Movable, so the person can see what it covers while choosing (DEV-1286).
					.movableFloatingPanel(
						isPresented: Binding(
							get: { isHere && editingAppearanceFor == space.id },
							set: { isPresented in
								guard !isPresented else { return }
								editingAppearanceFor = nil
								appearancePreview = nil
							}
						),
						placement: .vertical(.top)
					) {
						SpaceAppearancePanel(
							store: store,
							spaceID: space.id,
							global: .init(tint: chromeTint, grain: .init(filmGrain), accent: chromeAccent, matchesSite: chromeMatchesSite)
						) { override in
							appearancePreview = override.map { .init(spaceID: space.id, override: $0) }
						}
					}
			)
		}
	}

	/// A column's ⋯ on the Library's Spaces page, where its menu's pickers open.
	@ViewBuilder
	private func overviewMenuAnchor(_ id: UUID) -> some View {
		if let space = store.sidebar.organization.spaces[id: .init(rawValue: id)] {
			spacePanels(space)(spacePanelsInOverview)
		}
	}

	@ViewBuilder
	private func spaceButton(
		_ id: Space.ID,
		state: SidebarSpacePickerItemState
	) -> some View {
		if let space = store.sidebar.organization.spaces[id: id] {
			SidebarSpaceButton(
				spaceID: space.id.rawValue,
				name: space.name,
				symbol: (space.icon ?? .dot).rawValue,
				isSelected: store.sidebar.spaceID == space.id && !store.isLibraryOpen,
				isCollapsed: state.isCollapsed,
				width: state.width,
				nudge: state.nudge,
				deletionHint: iCloudRemoval.marked[space.id.rawValue].map { DeletionMarkText.hint(deviceName: $0.deviceName, deletesAt: $0.deletesAt) },
				onSelect: { store.send(.sidebar(.ui(.spaceSelected(space.id)))) },
				onDropTabs: { store.send(.sidebar(.ui(.tabsDroppedOnSpace($0, space.id)))) }
			) {
				spaceMenu(space)
			}
			.modifier(SpacePanels(isPresentedHere: !spacePanelsInOverview) { spacePanels(space) })
		}
	}
}

extension MainView where DownloadsPanel == EmptyView, MediaPanel == EmptyView {
	public init(
		store: StoreOf<MainFeature>,
		surface: BrowserSurfaceClient
	) {
		self.init(store: store, surface: surface) { EmptyView() } mediaPanel: { EmptyView() }
	}
}

/// Owns the command bar's presentation so per-keystroke query changes re-render only this host.
private struct MainCommandBarHost<Content: View>: View {
	internal let store: StoreOf<MainFeature>
	internal let content: Content

	internal init(
		store: StoreOf<MainFeature>,
		content: Content
	) {
		self.store = store
		self.content = content
	}

	internal var body: some View {
		content.commandBarPresentation(
			isPresented: store.commandBar.isPresented,
			anchoredToURL: store.commandBar.mode == .currentTab,
			centeredOverPane: store.commandBarEmptyPaneID != nil,
			urlFieldText: store.commandBar.query,
			urlFieldShowsAgentHint: store.commandBar.showsAgentHint,
			onDismiss: { store.send(.commandBar(.ui(.dismissed))) }
		) { maximumHeight in
			CommandBarView(
				store: store.scope(state: \.commandBar, action: \.commandBar),
				style: store.commandBar.mode == .currentTab ? .urlField : .palette,
				maximumResultsHeight: maximumHeight
			)
		}
	}
}

/// ⌃Tab's recent-tab switcher (DEV-544), once ⌃ has been held for its beat.
private struct MainTabSwitcherHost: View {
	internal let store: StoreOf<MainFeature>

	internal var body: some View {
		if let switcher = store.tabSwitcher, switcher.isShown {
			TabSwitcherView(
				rows: rows(switcher),
				selectedIndex: switcher.index,
				onHighlight: { store.send(.ui(.tabSwitcher(.highlight($0)))) },
				onChoose: { store.send(.ui(.tabSwitcher(.choose($0)))) }
			)
			.frame(maxWidth: .infinity, maxHeight: .infinity)
		}
	}

	private func rows(_ switcher: TabSwitcher) -> [TabSwitcherRow] {
		let sidebar = store.sidebar
		return switcher.tabs.compactMap { entry in
			guard let tab = sidebar.organization.tabs[id: entry.tabID] else { return nil }
			let otherSpace = entry.spaceID == sidebar.spaceID ? nil : sidebar.organization.spaces[id: entry.spaceID]
			return .init(
				id: tab.id.rawValue,
				title: tab.displayTitle,
				spaceName: otherSpace?.name,
				siteIcon: tab.isChat ? nil : .init(
					profileID: tab.profileID.rawValue,
					pageURL: tab.siteIconURL
				),
				symbol: tab.isChat ? SidebarItem.assistantSymbol : SidebarItem.siteSymbol,
				isUnloaded: sidebar.unloadedTabs.contains(tab.id)
			)
		}
	}
}

/// Gives the URL bar its site menu for the page in the active pane. It reads the page's
/// navigation, so it does that in its own body: a load re-renders this, not the chrome around it.
private struct MainSiteMenuEnvironment: ViewModifier {
	internal let store: StoreOf<MainFeature>

	internal func body(content: Content) -> some View {
		content
			.environment(\.siteMenu, source)
			.environment(\.pageTranslationOffer, translation)
			.environment(\.readingModeIndicator, readingMode)
			.environment(\.urlBarReservesPageButton, reservesPageButton)
	}

	/// Translation Available for the page in the active pane (DEV-996).
	private var translation: PageTranslationOfferSource? {
		guard
			!store.translationOffers.isEmpty,
			let tabID = store.state.siteMenuContext?.tabID,
			let offer = store.translationOffers[tabID]
		else { return nil }

		return .init(offer: offer) { [store] action in
			store.send(.ui(.pageTranslation(action)))
		}
	}

	/// The active page's reading mode, for the address bar (DEV-1028), when it's the page button
	/// the item chose (DEV-1254).
	private var readingMode: ReadingModeIndicator? {
		guard
			store.state.commandContext.readingModeEnabled,
			case let .readingMode(isReading) = store.viewer.item.urlBarPageButton
		else { return nil }

		return .init(isReading: isReading) { [store] in
			store.send(.ui(.paneCommand(.readingMode, store.viewer.activePaneID)))
		}
	}

	/// The address bar holds the room of the page button while the next page settles (DEV-1254).
	private var reservesPageButton: Bool {
		store.viewer.item.urlBarPageButton == .reserved
	}

	private var source: SiteMenuSource {
		var menu = store.siteMenu.menu

		// The connection follows the page while the menu is open, such as a load that fails.
		if let live = store.state.siteMenuContext, live.url == store.siteMenu.context?.url {
			menu?.connection = live.connection

			// So is the Dark page switch, once its site's change reaches the profile (DEV-1020).
			menu?.darkPage = live.darkPage
		}
		return .init(menu: menu) { [store] action in
			store.send(.ui(.siteMenu(action)))
		}
	}
}

extension EnvironmentValues {
	/// Whether only the window's sidebar is there to use, beside a page in full screen after ⌘S
	/// (DEV-991): it shows pinned whatever its own setting, and the page area under the page in
	/// full screen takes no clicks and is hidden from accessibility.
	@Entry
	public var showsOnlySidebar: Bool = false
}

/// Builds its content in its own body, so what the content reads re-renders only this view.
private struct MainLeaf<Content: View>: View {
	internal let content: () -> Content

	internal var body: some View {
		content()
	}
}

/// Hosts a space's pickers behind the view that anchors them.
private struct SpacePanels: ViewModifier {
	internal let isPresentedHere: Bool
	internal let panels: () -> (Bool) -> AnyView

	internal func body(content: Content) -> some View {
		content.background { panels()(isPresentedHere) }
	}
}

/// The window's question before a move to another profile: a drag, Move Items… or a drop on a
/// space. With the `ARX_PAGE_PIP_SPACES` feature flag (DEV-1184), a sheet that says plainly what
/// happens; Escape cancels. Off, the system's dialog, as before.
private struct ProfileMoveQuestion: ViewModifier {
	internal let store: StoreOf<MainFeature>
	internal let destination: (profile: Profile, space: Space)?

	internal func body(content: Content) -> some View {
		if PagePictureInPictureSpacesFeatureFlag.isOn() {
			content.profileMoveConfirmationSheet(
				store.pendingTabMove?.profileMoveConfirmation,
				onCancel: { store.send(.ui(.cancelProfileMove)) },
				onConfirm: { store.send(.ui(.confirmProfileMove)) }
			)
		} else {
			content.confirmationDialog(
				String.localized(.appUI.profile.moveTitle),
				isPresented: Binding(
					get: { store.pendingProfileMove != nil },
					set: { if !$0 { store.send(.ui(.cancelProfileMove)) } }
				)
			) {
				Button(String.localized(.appUI.profile.moveConfirm)) { store.send(.ui(.confirmProfileMove)) }
			} message: {
				if let destination {
					Text(
						destination.profile.name
						+ " / "
						+ destination.space.name
						+ "\n\n"
						+ String.localized(.appUI.move.identity)
					)
				}
			}
		}
	}
}
