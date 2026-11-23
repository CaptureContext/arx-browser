import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

internal struct PreviewBrowserView: View {
	private let appearance: PreviewAppearancePreferences
	internal let store: StoreOf<PreviewFeature>

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	internal init(store: StoreOf<PreviewFeature>) {
		self.appearance = .init()
		self.store = store
	}

	internal var body: some View {
		GeometryReader { _ in
			ZStack {
				PreviewWindowBackground().ignoresSafeArea()
				BrowserChromeBackground(textured: true).ignoresSafeArea()
				BrowserSidebarLayout(
					isPinned: store.sidebarIsVisible,
					isSuspended: store.commandIsPresented
				) {
					VStack(spacing: 0) {
						SidebarPager(
							spaces: store.sidebarSpaces,
							selectedSpaceID: store.spaceID.rawValue,
							onSelectSpace: { store.send(.ui(.spaceSelected(.init(rawValue: $0)))) },
							onAction: sidebarAction,
							onCopyURL: { store.send(.ui(.copyURL)) }
						) {
							spaceSwitcher
						}
					}
				} page: {
					page
						.padding([.top, .bottom, .trailing], BrowserMetrics.PageCard.inset)
						.padding(.leading, store.sidebarIsVisible ? 0 : BrowserMetrics.PageCard.inset)
				}
				.disabled(store.commandIsPresented)
				.accessibilityHidden(store.commandIsPresented)
			}
		}
		.commandBarPresentation(
			isPresented: store.commandIsPresented,
			anchoredToURL: false,
			onDismiss: { store.send(.ui(.commandDismissed)) }
		) { maximumHeight in
			CommandBar(
				results: store.commandResults,
				onQuery: { store.send(.ui(.queryChanged($0))) },
				onSelect: { store.send(.ui(.commandSelected($0))) },
				onDismiss: { store.send(.ui(.commandDismissed)) }
			)
			.transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.98)))
		}
		.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: store.commandIsPresented)
		.ignoresSafeArea()

		// Sidebar drags draw their own preview, as in the app's windows.
		.sidebarDragPreviewHost()
		.environment(\.browserFilmGrain, appearance.grain)
	}

	private func sidebarAction(
		_ spaceID: UUID,
		_ action: SidebarAction
	) {
		if store.spaceID.rawValue != spaceID {
			store.send(.ui(.spaceSelected(.init(rawValue: spaceID))))
		}
		store.send(.ui(.sidebar(action)))
	}

	private var page: some View {
		ZStack {
			BrowserTheme.page
			if let tab = store.selectedTab {
				VStack(spacing: 16) {
					Image(systemName: PreviewFixture.icon(for: tab).0)
						.font(.system(size: 34, weight: .light))
						.foregroundStyle(PreviewFixture.icon(for: tab).1.color.opacity(0.7))
					Text(tab.displayTitle)
						.font(.system(size: 23, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(0.68))
					Text(tab.restoration.url.host() ?? "")
						.font(.system(size: 12))
						.foregroundStyle(BrowserTheme.text.opacity(0.3))
				}
				.padding(32)
			}
			VStack {
				HStack {
					Spacer()
					Text(localized: .appUI.preview.title)
						.font(.system(size: 10, weight: .medium))
						.foregroundStyle(BrowserTheme.text.opacity(0.25))
				}
				.padding(16)
				Spacer()
				if let message = store.message {
					Text(message)
						.font(.system(size: 12))
						.padding(12)
						.background(.regularMaterial, in: .rect(cornerRadius: 9, style: .continuous))
						.padding(18)
				}
			}
		}
		.browserPageCard()
	}

	private var spaceSwitcher: some View {
		HStack(spacing: BrowserMetrics.SpaceSwitcher.spacing) {
			Menu {
				Button(String.localized(.appUI.sidebar.newFolder)) {
					store.send(.ui(.sidebar(.newFolder(nil))))
				}
				Button(String.localized(.appUI.preview.reset)) { store.send(.ui(.reset)) }
			} label: {
				Image(systemName: "tray.full.fill")
			}
			.menuStyle(.borderlessButton)
			.menuIndicator(.hidden)
			.fixedSize()
			.help(String.localized(.appUI.sidebar.library))
			Spacer()
			ForEach(store.organization.spaces.filter { $0.profileID == store.space.profileID }) { space in
				SidebarSpaceButton(
					name: space.name,
					symbol: space.name == "Work" ? "person.2.fill" : "moon.stars.fill",
					isSelected: store.spaceID == space.id,
					onSelect: { store.send(.ui(.spaceSelected(space.id))) },
					onDropTabs: { store.send(.ui(.tabsDroppedOnSpace($0, space.id))) }
				)
			}
			Spacer()
			SettingsLink {
				Image(systemName: "paintpalette")
					.frame(width: 26, height: 26)
			}
			.buttonStyle(.plain)
			.help(String.localized(.appUI.appearance.title))
			.accessibilityLabel(String.localized(.appUI.appearance.title))
			Button { store.send(.ui(.commandOpened)) } label: {
				Image(systemName: "plus")
					.frame(width: 26, height: 26)
			}
			.buttonStyle(.plain)
			.help(String.localized(.appUI.sidebar.newTab))
			.accessibilityLabel(String.localized(.appUI.sidebar.newTab))
		}
		.font(.system(size: BrowserMetrics.SpaceSwitcher.symbolSize - 2, weight: .medium))
		.foregroundStyle(BrowserTheme.secondary)
		.padding(.horizontal, 14)
		.frame(height: BrowserMetrics.SpaceSwitcher.height)
	}
}
