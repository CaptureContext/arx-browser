import AppUI
import BrowserCore
import DefaultBrowserClient
import ExtensionsFeature
import MigrationAssistant
import MigrationAssistantFeature
import OutsideAgentsFeature
import SwiftUI
import WorkspaceSync
import _ComposableArchitecture

/// The onboarding window's content: the visible page over a footer with Back,
/// progress, Skip and Continue.
///
/// Entrance and page transitions are view-local animations keyed on store values
/// that change once per page, so no animation frames go through the store.
public struct OnboardingView: View {
	public static let size: CGSize = .init(width: 760, height: 540)

	/// The transparent title bar's height, which holds the traffic lights.
	internal static let titleBarHeight: CGFloat = 28

	public let store: StoreOf<OnboardingFeature>

	@Environment(\.accessibilityReduceMotion)
	private var reduceMotion

	@SwiftUI.State
	private var hasAppeared: Bool

	/// How strongly the footer's soft edge shows, from the visible page's scrolling content.
	@SwiftUI.State
	private var footerEdge: CGFloat

	public init(store: StoreOf<OnboardingFeature>) {
		self.store = store
		self._hasAppeared = .init(initialValue: false)
		self._footerEdge = .init(initialValue: 0)
	}

	public var body: some View {
		ZStack {
			page
				.id(pageID)
				.transition(pageTransition)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.animation(pageAnimation, value: pageID)

		// A page's scrolling content runs under the footer, which sits over Arx's soft edge
		// down to the window's bottom, and takes its own clicks.
		.safeAreaInset(edge: .bottom, spacing: 0) {
			if store.showsFooter {
				footer
					.background(alignment: .bottom) {
						OnboardingFooterEdge(reveal: footerEdge)
					}
			}
		}
		.onPreferenceChange(OnboardingFooterEdgeKey.self) { footerEdge = $0 }
		.frame(width: Self.size.width, height: Self.size.height)
		.clipped()
		.scaleEffect(hasAppeared || reduceMotion ? 1 : 0.94)
		.opacity(hasAppeared ? 1 : 0)
		.onAppear {
			let animation: Animation = reduceMotion
			? .easeOut(duration: 0.25)
			: .spring(duration: 0.55, bounce: 0.2)
			withAnimation(animation) { hasAppeared = true }
		}
		.onExitCommand { store.send(.ui(.dismiss)) }
		.onChange(of: pageID) {
			AccessibilityNotification.Announcement(headline).post()
		}
	}

	/// Changes once per page, tour pages included, so each one slides in.
	private var pageID: String {
		"\(store.index)-\(store.page.tour?.index ?? 0)"
	}

	/// The visible page's headline, which VoiceOver announces when it changes.
	private var headline: String {
		store.page.tour?.page.map { TourDemo($0).headline } ?? store.step.headline
	}

	private var progress: (count: Int, current: Int)? {
		store.progress.map { ($0.count, $0.current) }
	}

	@ViewBuilder
	private var page: some View {
		switch store.page {
		case .welcome:
			if let welcome = store.scope(state: \.page.welcome, action: \.page.welcome) {
				OnboardingWelcomePage { welcome.send(.ui(.getStarted)) }
			}

		case .iCloud:
			if let page = store.scope(state: \.page.iCloud, action: \.page.iCloud) {
				OnboardingICloudPage(status: page.state.status)
					.task { page.send(.ui(.task)) }
			}

		case let .tour(tour):
			if let page = tour.page {
				OnboardingTourPage(demo: TourDemo(page))
			}

		case .placeholder:
			OnboardingPageLayout(
				title: store.step.headline,
				message: store.step.message
			) {
				OnboardingPlaceholderContent()
			}

		case .migration:
			if let page = store.scope(state: \.page.migration, action: \.page.migration) {
				OnboardingImportPage(store: page)
			}

		case .outsideAgents:
			if let page = store.scope(state: \.page.outsideAgents, action: \.page.outsideAgents) {
				OnboardingPageLayout(
					title: store.step.headline,
					message: store.step.message
				) {
					ScrollView {
						OutsideAgentsView(store: page)
							.padding(.horizontal, 4)
							.padding(.bottom, 12)
					}
					.scrollIndicators(.automatic)
					.onboardingFooterEdge()
				}
			}

		case .connectAgent:
			if let page = store.scope(state: \.page.connectAgent, action: \.page.connectAgent) {
				OnboardingPageLayout(
					title: store.step.headline,
					message: store.step.message
				) {
					OnboardingConnectAgentPage(store: page)
				}
			}

		case .defaultBrowser:
			if let page = store.scope(state: \.page.defaultBrowser, action: \.page.defaultBrowser) {
				OnboardingDefaultBrowserPage(note: page.note)
					.task { page.send(.ui(.task)) }
			}
		}
	}

	private var footer: some View {
		if let defaultBrowser = store.page.defaultBrowser {
			return defaultBrowserFooter(defaultBrowser)
		}

		if let migration = store.page.migration {
			return migrationFooter(migration)
		}

		if let connectAgent = store.page.connectAgent {
			return connectAgentFooter(connectAgent)
		}

		if let iCloud = store.page.iCloud {
			return iCloudFooter(iCloud)
		}

		let isWelcome: Bool = store.step == .welcome && store.mode == .flow
		let skipTitle: String = if isWelcome {
			String.localized(.appUI.onboarding.skipSetup)
		} else if store.page.tour != nil {
			String.localized(.appUI.onboarding.tour.skip)
		} else {
			String.localized(.appUI.onboarding.skip)
		}

		return OnboardingFooter(
			progress: progress,
			back: store.canGoBack ? { store.send(.ui(.back)) } : nil,
			skipTitle: skipTitle,
			skip: { store.send(.ui(isWelcome ? .skipSetup : .skip)) },
			// The welcome page's Get Started is its main action.
			primaryTitle: isWelcome ? nil : String.localized(.appUI.onboarding.continue),
			primary: isWelcome ? nil : { store.send(.ui(.continueSetup)) }
		)
	}

	/// Not Now and Make Default while Arx isn't the default; Continue once it is.
	private func defaultBrowserFooter(_ page: OnboardingDefaultBrowser.State) -> OnboardingFooter {
		let back: (() -> Void)? = store.canGoBack ? { store.send(.ui(.back)) } : nil

		guard page.canMakeDefault || page.isRequesting else {
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: String.localized(.appUI.onboarding.skip),
				skip: page.status == .isDefault ? nil : { store.send(.ui(.skip)) },
				primaryTitle: String.localized(.appUI.onboarding.continue),
				primary: { store.send(.ui(.continueSetup)) }
			)
		}

		return OnboardingFooter(
			progress: progress,
			back: back,
			skipTitle: String.localized(.appUI.onboarding.defaultBrowser.notNow),
			skip: { store.send(.ui(.skip)) },
			primaryTitle: String.localized(.appUI.onboarding.defaultBrowser.makeDefault),
			primary: { store.send(.page(.defaultBrowser(.ui(.makeDefault)))) },
			isEnabled: !page.isRequesting
		)
	}

	/// Not now and Sync with iCloud; nothing to press while the first fetch runs until it's slow,
	/// then Continue without waiting; Continue without waiting and Try again after a failure;
	/// Continue once the step decided (DEV-1215).
	private func iCloudFooter(_ page: OnboardingICloud.State) -> OnboardingFooter {
		let back: (() -> Void)? = store.canGoBack ? { store.send(.ui(.back)) } : nil
		let sync: String = String.localized(.appUI.onboarding.iCloud.sync)
		let continueWithoutWaiting: String = String.localized(.appUI.onboarding.iCloud.continueWithoutWaiting)

		switch page.phase {
		case .checking, .ready:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: String.localized(.appUI.onboarding.iCloud.notNow),
				skip: { store.send(.page(.iCloud(.ui(.notNow)))) },
				primaryTitle: sync,
				primary: { store.send(.page(.iCloud(.ui(.sync)))) },
				isPrimaryEnabled: page.phase == .ready
			)

		case .syncing where page.isSlow:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: continueWithoutWaiting,
				skip: nil,
				primaryTitle: continueWithoutWaiting,
				primary: { store.send(.page(.iCloud(.ui(.continueWithoutWaiting)))) }
			)

		case .syncing:
			// Leaving now would go on without waiting, which is offered once it's slow.
			return OnboardingFooter(
				progress: progress,
				back: nil,
				skipTitle: continueWithoutWaiting,
				skip: nil,
				primaryTitle: sync,
				primary: { store.send(.page(.iCloud(.ui(.sync)))) },
				isPrimaryEnabled: false
			)

		case .failed:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: continueWithoutWaiting,
				skip: { store.send(.page(.iCloud(.ui(.continueWithoutWaiting)))) },
				primaryTitle: String.localized(.appUI.onboarding.iCloud.tryAgain),
				primary: { store.send(.page(.iCloud(.ui(.sync)))) }
			)

		case .finished:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: String.localized(.appUI.onboarding.skip),
				skip: nil,
				primaryTitle: String.localized(.appUI.onboarding.continue),
				primary: { store.send(.ui(.continueSetup)) }
			)
		}
	}

	/// Later and "Connect <provider>" while a provider is ready and none is connected yet;
	/// Later and Continue otherwise.
	private func connectAgentFooter(_ page: OnboardingConnectAgent.State) -> OnboardingFooter {
		let back: (() -> Void)? = store.canGoBack ? { store.send(.ui(.back)) } : nil
		let later: String = String.localized(.appUI.onboarding.connectAgent.later)

		guard page.connected == nil, let provider = page.suggestedProvider else {
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: later,
				skip: page.connected == nil ? { store.send(.ui(.skip)) } : nil,
				primaryTitle: String.localized(.appUI.onboarding.continue),
				primary: { store.send(.ui(.continueSetup)) }
			)
		}

		return OnboardingFooter(
			progress: progress,
			back: back,
			skipTitle: later,
			skip: { store.send(.ui(.skip)) },
			primaryTitle: String.localized(.appUI.onboarding.connectAgent.connectProvider(provider.title)),
			primary: { store.send(.page(.connectAgent(.ui(.connect(provider))))) }
		)
	}

	/// Start Fresh and "Bring from <browser>" while choosing, Try Again after a partial,
	/// failed or cancelled import, and Continue once it completed or nothing can be imported.
	private func migrationFooter(_ page: OnboardingImport.State) -> OnboardingFooter {
		let back: (() -> Void)? = store.canGoBack ? { store.send(.ui(.back)) } : nil
		let startFresh: String = String.localized(.appUI.onboarding.makeItYours.startFresh)

		switch page.phase {
		case .finished where page.canRetry:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: String.localized(.appUI.onboarding.continue),
				skip: { store.send(.ui(.skip)) },
				primaryTitle: String.localized(.appUI.onboarding.makeItYours.retry),
				primary: { store.send(.page(.migration(.ui(.retry)))) }
			)

		case .finished:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: startFresh,
				skip: page.isCompleted ? nil : { store.send(.ui(.skip)) },
				primaryTitle: String.localized(.appUI.onboarding.continue),
				primary: { store.send(.ui(.continueSetup)) }
			)

		case .choosing where page.selectedSource != nil:
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: startFresh,
				skip: { store.send(.ui(.skip)) },
				primaryTitle: String.localized(.appUI.onboarding.makeItYours.bring(page.selectedSource?.name ?? "")),
				primary: { store.send(.page(.migration(.ui(.bring)))) },
				isPrimaryEnabled: page.canImport
			)

		case .idle, .discovering, .choosing, .importing, .cancelling:
			// Nothing to bring yet, or an import running: Continue only, refused until it ends.
			return OnboardingFooter(
				progress: progress,
				back: back,
				skipTitle: startFresh,
				skip: nil,
				primaryTitle: String.localized(.appUI.onboarding.continue),
				primary: { store.send(.ui(.continueSetup)) },
				isEnabled: page.canClose
			)
		}
	}

	private var pageTransition: AnyTransition {
		guard !reduceMotion else { return .opacity }

		let leading: AnyTransition = .move(edge: .leading).combined(with: .opacity)
		let trailing: AnyTransition = .move(edge: .trailing).combined(with: .opacity)
		return switch store.direction {
		case .forward: .asymmetric(insertion: trailing, removal: leading)
		case .backward: .asymmetric(insertion: leading, removal: trailing)
		}
	}

	private var pageAnimation: Animation {
		reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)
	}
}

private struct OnboardingPlaceholderContent: View {
	internal var body: some View {
		RoundedRectangle(cornerRadius: 12, style: .continuous)
			.strokeBorder(.quaternary, style: .init(lineWidth: 1, dash: [5, 5]))
			.overlay {
				Text(localized: .appUI.onboarding.placeholder)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(24)
			}
			.padding(.bottom, 8)
	}
}

private struct OnboardingImportPage: View {
	internal let store: StoreOf<OnboardingImport>

	internal var body: some View {
		if let migration = store.scope(state: \.migration, action: \.migration) {
			// The header bar sits below the window's traffic lights, and its soft edge runs
			// under them to the top of the window.
			MigrationAssistantView(store: migration, barTopInset: OnboardingView.titleBarHeight)
				.frame(maxWidth: .infinity, maxHeight: .infinity)
				.background(ArxModalMetrics.background)
		} else {
			OnboardingImportSummaryPage(
				summary: store.state.summary,
				selectBrowser: { store.send(.ui(.selectSource(.init(rawValue: $0)))) },
				toggleCategory: { category in
					guard let category = MigrationCategory(category) else { return }

					store.send(.ui(.toggleCategory(category)))
				},
				setKeepsSpaces: { store.send(.ui(.setKeepsSpaces($0))) },
				customize: { store.send(.ui(.customize)) },
				cancel: { store.send(.ui(.cancel)) },
				allowFullDiskAccess: { store.send(.ui(.allowFullDiskAccess)) },
				setUpPasswords: { store.send(.ui(.setUpPasswords)) },
				skipExtensions: { store.send(.extensionImport(.ui(.skipAll))) }
			)
			.task { store.send(.ui(.task)) }

			// DEV-845: each store extension from the import gets the usual review.
			.extensionImportReview(store.scope(state: \.extensionImport, action: \.extensionImport))
		}
	}
}

extension OnboardingICloud.State {
	/// What the page says under its illustration.
	fileprivate var status: OnboardingICloudPage.Status {
		switch phase {
		case .checking, .ready:
			.none

		case let .syncing(category):
			isSlow ? .slow(category.map(OnboardingICloudPage.Stage.init)) : .syncing(category.map(OnboardingICloudPage.Stage.init))

		case let .failed(message):
			.failed(message)

		case .finished(.adopted):
			.adopted

		case .finished(.empty):
			.empty

		case .finished(.continuedWithoutWaiting):
			.continuedWithoutWaiting

		case .finished(.notNow), .finished(.unavailable):
			.notNow
		}
	}
}

extension OnboardingICloudPage.Stage {
	fileprivate init(_ category: SyncCategory) {
		switch category {
		case .organization: self = .organization
		case .preferences: self = .preferences
		case .history: self = .history
		case .archive: self = .archive
		}
	}
}

extension OnboardingDefaultBrowser.State {
	/// What the page says under its illustration.
	fileprivate var note: OnboardingDefaultBrowserPage.Note {
		switch status {
		case .isDefault:
			.isDefault

		case let .otherBrowser(name):
			outcome == .declined ? .declined : .otherBrowser(name)

		case .unavailable, nil:
			.none
		}
	}
}

extension TourDemo {
	/// The demo a tour page plays.
	fileprivate init(_ page: OnboardingTour.Page) {
		switch page {
		case .peek: self = .peek
		case .splitView: self = .splitView
		case .commandBar: self = .commandBar
		case .chats: self = .chats
		case .littleArx: self = .littleArx
		}
	}
}
