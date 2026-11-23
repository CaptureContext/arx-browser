import AppKit
import BrowserCore
import SwiftUI

/// "Make it yours": the browsers on this Mac, what the chosen one holds with a switch per
/// category, "Keep its spaces", and inline progress and results.
///
/// "Bring from" and "Start Fresh" are in the footer, which the onboarding window draws.
/// The page holds no logic: the owner supplies a ``OnboardingImportSummary`` and handles
/// the callbacks.
public struct OnboardingImportSummaryPage: View {
	public let summary: OnboardingImportSummary
	public let selectBrowser: (String) -> Void
	public let toggleCategory: (OnboardingImportSummary.Category) -> Void
	public let setKeepsSpaces: (Bool) -> Void
	public let customize: () -> Void
	public let cancel: () -> Void

	/// Opens System Settings at Full Disk Access, for a browser that needs it (Safari).
	public let allowFullDiskAccess: () -> Void

	/// Opens Customize with Passwords and sign-ins on (DEV-842).
	public let setUpPasswords: () -> Void

	/// Leaves out the store extensions still to install (DEV-845).
	public let skipExtensions: () -> Void

	public init(
		summary: OnboardingImportSummary,
		selectBrowser: @escaping (String) -> Void,
		toggleCategory: @escaping (OnboardingImportSummary.Category) -> Void,
		setKeepsSpaces: @escaping (Bool) -> Void,
		customize: @escaping () -> Void,
		cancel: @escaping () -> Void,
		allowFullDiskAccess: @escaping () -> Void = {},
		setUpPasswords: @escaping () -> Void = {},
		skipExtensions: @escaping () -> Void = {}
	) {
		self.summary = summary
		self.selectBrowser = selectBrowser
		self.toggleCategory = toggleCategory
		self.setKeepsSpaces = setKeepsSpaces
		self.customize = customize
		self.cancel = cancel
		self.allowFullDiskAccess = allowFullDiskAccess
		self.setUpPasswords = setUpPasswords
		self.skipExtensions = skipExtensions
	}

	public var body: some View {
		// The card and its notes scroll once they outgrow the window (six rows since Passwords
		// and sign-ins), under the header and the browsers, and under the footer, fading at
		// both ends rather than cut at a line (DEV-1300).
		OnboardingScrollingPageLayout(
			title: OnboardingStep.migration.headline,
			message: OnboardingStep.migration.message
		) {
			if !summary.browsers.isEmpty {
				browsers
					.padding(.top, 24)
			}
		} content: {
			content

				// Room for the card's shadow.
				.padding(.top, 6)
				.padding(.bottom, 16)
		}
		.onChange(of: summary.announcement) { _, announcement in
			guard let announcement else { return }

			AccessibilityNotification.Announcement(announcement).post()
		}
	}

	// MARK: - Browsers

	/// Centered while they fit; scrolling sideways once there are more than the page holds.
	private var browsers: some View {
		ViewThatFits(in: .horizontal) {
			browserTiles

			ScrollView(.horizontal) {
				browserTiles
			}
			.scrollIndicators(.never)
		}
		.frame(maxWidth: .infinity)
		.frame(height: 86)
	}

	private var browserTiles: some View {
		HStack(alignment: .top, spacing: 8) {
			ForEach(summary.browsers) { browser in
				OnboardingBrowserTile(
					browser: browser,
					isEnabled: summary.canChangeBrowser
				) {
					selectBrowser(browser.id)
				}
			}
		}
		.padding(.horizontal, 4)
	}

	// MARK: - Content

	@ViewBuilder
	private var content: some View {
		switch summary.content {
		case .discovering:
			ProgressView(String.localized(.appUI.onboarding.makeItYours.discovering))
				.controlSize(.small)
				.padding(.top, 24)

		case let .noBrowsers(problem):
			VStack(spacing: 10) {
				Text(problem.map(problemText) ?? String.localized(.appUI.onboarding.makeItYours.noBrowsers))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
				customizeButton
			}
			.padding(.top, 24)

		case let .choosing(choosing):
			choosingView(choosing)

		case let .needsFullDiskAccess(access):
			fullDiskAccessView(access)

		case let .importing(importing):
			importingView(importing)

		case let .finished(result):
			resultView(result)
		}
	}

	private func choosingView(_ choosing: OnboardingImportSummary.Choosing) -> some View {
		VStack(spacing: 10) {
			OnboardingImportCard {
				if choosing.fromICloud {
					fromICloudRow
				}

				if choosing.isReading {
					HStack(spacing: 8) {
						ProgressView()
							.controlSize(.small)
						Text(localized: .appUI.onboarding.makeItYours.reading(choosing.browserName))
							.foregroundStyle(.secondary)
					}
					.frame(maxWidth: .infinity, minHeight: 34)
				} else {
					ForEach(choosing.rows) { row in
						OnboardingImportCategoryRow(row: row) { toggleCategory(row.category) }
					}
				}

				if let keepsSpaces = choosing.keepsSpaces {
					keepSpacesRow(keepsSpaces)
				}

				if choosing.offersPasswords, !choosing.isReading {
					passwordsRow
				}

				if !choosing.unavailable.isEmpty {
					unavailableRow(choosing.unavailable, browserName: choosing.browserName)
				}
			}

			footnote(choosing)
		}
	}

	/// Asked in place of the categories (DEV-840): why, and the way to System Settings.
	private func fullDiskAccessView(_ access: OnboardingImportSummary.FullDiskAccess) -> some View {
		VStack(spacing: 10) {
			OnboardingImportCard {
				OnboardingImportRow(
					symbol: "lock.shield",
					title: access.isDenied
					? String.localized(.appUI.migration.fullDiskAccess.denied)
					: String.localized(.appUI.migration.fullDiskAccess.title),
					subtitle: String.localized(.appUI.migration.fullDiskAccess.message(access.browserName))
				) {
					EmptyView()
				}

				Button(String.localized(.appUI.migration.fullDiskAccess.openSettings), action: allowFullDiskAccess)
					.buttonStyle(.arxRaised(.capsule))
					.frame(maxWidth: .infinity, alignment: .trailing)
					.padding(.vertical, 8)
			}

			Text(localized: .appUI.migration.fullDiskAccess.steps)
				.font(.callout)
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
				.fixedSize(horizontal: false, vertical: true)
				.frame(width: 420)
		}
	}

	private func keepSpacesRow(_ keepsSpaces: Bool) -> some View {
		let title: String = String.localized(.appUI.onboarding.makeItYours.keepSpaces)
		return OnboardingImportRow(
			symbol: "rectangle.stack",
			title: title,
			subtitle: keepsSpaces
			? String.localized(.appUI.onboarding.makeItYours.keepSpacesOn)
			: String.localized(.appUI.onboarding.makeItYours.keepSpacesOff)
		) {
			OnboardingImportSwitch(
				title: title,
				isOn: .init(
					get: { keepsSpaces },
					set: { setKeepsSpaces($0) }
				)
			)
		}
	}

	/// The workspace came from iCloud (DEV-1215): what's left to bring is what iCloud doesn't sync.
	private var fromICloudRow: some View {
		OnboardingImportRow(
			symbol: "icloud",
			title: String.localized(.appUI.onboarding.makeItYours.fromIcloud),
			subtitle: String.localized(.appUI.onboarding.makeItYours.fromIcloudSubtitle)
		) {
			EmptyView()
		}
	}

	/// Passwords and sign-ins need macOS's prompt explained and their own choices, so the
	/// row leads to Customize instead of a switch.
	private var passwordsRow: some View {
		OnboardingImportRow(
			symbol: OnboardingImportSummary.Category.passwords.symbol,
			title: OnboardingImportSummary.Category.passwords.title,
			subtitle: String.localized(.appUI.onboarding.makeItYours.passwordsSubtitle)
		) {
			Button(String.localized(.appUI.onboarding.makeItYours.passwordsSetUp), action: setUpPasswords)
				.buttonStyle(.arxRaised(.capsule))
				.controlSize(.small)
		}
	}

	private func unavailableRow(
		_ categories: [OnboardingImportSummary.Category],
		browserName: String
	) -> some View {
		let names: String = categories.map(\.title).formatted(.list(type: .and))

		return OnboardingImportRow(
			symbol: "clock",
			title: String.localized(.appUI.onboarding.makeItYours.notYet(names)),
			subtitle: String.localized(.appUI.onboarding.makeItYours.notYetReason(browserName)),
			isDimmed: true
		) {
			EmptyView()
		}
	}

	private func footnote(_ choosing: OnboardingImportSummary.Choosing) -> some View {
		VStack(spacing: 6) {
			if let problem = choosing.problem {
				Label {
					Text(problemText(problem))
				} icon: {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundStyle(.orange)
				}
				.font(.callout)
				.fixedSize(horizontal: false, vertical: true)
			}

			HStack(spacing: 6) {
				Text(localized: .appUI.onboarding.makeItYours.readOnly(choosing.browserName))
					.foregroundStyle(.secondary)
				Text(verbatim: "·")
					.foregroundStyle(.tertiary)
					.accessibilityHidden(true)
				customizeButton
			}
			.font(.callout)
		}
		.multilineTextAlignment(.center)
	}

	private var customizeButton: some View {
		Button(String.localized(.appUI.onboarding.makeItYours.customize), action: customize)
			.buttonStyle(.link)
			.disabled(!summary.canChangeBrowser)
	}

	private func importingView(_ importing: OnboardingImportSummary.Importing) -> some View {
		OnboardingImportCard {
			VStack(alignment: .leading, spacing: 10) {
				Text(
					importing.isCancelling
					? String.localized(.appUI.onboarding.makeItYours.cancelling)
					: importing.category.map { String.localized(.appUI.onboarding.makeItYours.bringing($0.title)) }
					?? String.localized(.appUI.onboarding.makeItYours.bringingAll(importing.browserName))
				)

				ProgressView(value: importing.fraction)
					.accessibilityLabel(Text(localized: .appUI.onboarding.makeItYours.progress))

				HStack {
					Spacer()
					Button(action: cancel) {
						ArxButtonLabel(String.localized(.appUI.onboarding.makeItYours.cancel), keyHint: .escape)
					}
					.buttonStyle(.arx(.secondary, size: .regular))
					.keyboardShortcut(.cancelAction)
					.disabled(importing.isCancelling)
				}
			}
			.padding(.vertical, 8)
		}
	}

	private func resultView(_ result: OnboardingImportSummary.Result) -> some View {
		VStack(spacing: 10) {
			OnboardingImportCard {
				HStack(alignment: .firstTextBaseline, spacing: 10) {
					Image(systemName: result.symbol)
						.foregroundStyle(result.outcome == .completed ? Color.green : Color.orange)
						.accessibilityHidden(true)
					VStack(alignment: .leading, spacing: 4) {
						Text(result.message)
							.fixedSize(horizontal: false, vertical: true)
						if result.outcome != .failed {
							Text(localized: .appUI.onboarding.makeItYours.importedCount(result.importedCount))
								.font(.callout)
								.foregroundStyle(.secondary)
						}
						if let problem = result.problem {
							Text(problemText(problem))
								.font(.callout)
								.foregroundStyle(.secondary)
						}
					}
					Spacer(minLength: 0)
				}
				.padding(.vertical, 8)
				.accessibilityElement(children: .combine)
			}

			if let extensions = result.extensions {
				extensionsRow(extensions)
			}

			if !result.reinstalls.isEmpty {
				Text(localized: .appUI.migration.reinstallExtensions(result.reinstalls.formatted(.list(type: .and))))
					.font(.callout)
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

	/// Store extensions being installed, or how that went (DEV-845).
	private func extensionsRow(_ extensions: OnboardingImportSummary.Result.Extensions) -> some View {
		OnboardingImportCard {
			HStack(spacing: 10) {
				if let position = extensions.position {
					ProgressView()
						.controlSize(.small)
					Text(localized: .appUI.onboarding.makeItYours.extensions.installing(position, extensions.total))
						.fixedSize(horizontal: false, vertical: true)
					Spacer(minLength: 0)
					Button(String.localized(.appUI.extensions.skipAll), action: skipExtensions)
						.buttonStyle(.arx(.secondary, size: .regular))
						.disabled(!extensions.canSkip)
				} else {
					Image(systemName: OnboardingImportSummary.Category.extensions.symbol)
						.foregroundStyle(.secondary)
						.accessibilityHidden(true)
					VStack(alignment: .leading, spacing: 2) {
						Text(localized: .appUI.onboarding.makeItYours.extensions.installed(extensions.installed))
						if extensions.notInstalled > 0 {
							Text(localized: .appUI.onboarding.makeItYours.extensions.notInstalled(extensions.notInstalled))
								.font(.callout)
								.foregroundStyle(.secondary)
						}
					}
				}
				Spacer(minLength: 0)
			}
			.padding(.vertical, 8)
			.accessibilityElement(children: .combine)
		}
	}

	private func problemText(_ problem: OnboardingImportSummary.Problem) -> String {
		switch problem {
		case .discoveryFailed: String.localized(.appUI.onboarding.makeItYours.problem.discoveryFailed)
		case .missingDestination: String.localized(.appUI.migration.missingDestination)
		case let .inspectionFailed(name): String.localized(.appUI.onboarding.makeItYours.problem.inspectionFailed(name))
		case let .sourceChanged(name): String.localized(.appUI.onboarding.makeItYours.problem.sourceChanged(name))
		case .importFailed: String.localized(.appUI.onboarding.makeItYours.problem.importFailed)
		}
	}
}

// MARK: - Model

/// What the "Make it yours" page shows. Built by the owner from its state.
public struct OnboardingImportSummary: Equatable {
	public var browsers: [Browser]
	public var content: Content

	/// Whether another browser can be chosen; false while importing.
	public var canChangeBrowser: Bool

	public init(
		browsers: [Browser],
		content: Content,
		canChangeBrowser: Bool = true
	) {
		self.browsers = browsers
		self.content = content
		self.canChangeBrowser = canChangeBrowser
	}

	public struct Browser: Identifiable, Equatable {
		public var id: String
		public var name: String
		public var status: Status
		public var isSelected: Bool

		/// The app's icon, when the owner could find it; a globe otherwise.
		public var icon: NSImage?

		public init(
			id: String,
			name: String,
			status: Status,
			isSelected: Bool,
			icon: NSImage? = nil
		) {
			self.id = id
			self.name = name
			self.status = status
			self.isSelected = isSelected
			self.icon = icon
		}

		public enum Status: Equatable, Sendable {
			case defaultBrowser
			case usedMostRecently
			case onThisMac

			/// Arx can't import from it yet; it can't be chosen.
			case unsupported
		}
	}

	public enum Category: Hashable, Sendable {
		case favorites
		case bookmarks
		case openTabs
		case archivedTabs
		case history
		case extensions
		case preferences
		case passwords

		public var title: String {
			switch self {
			case .favorites: String.localized(.appUI.migration.favorites)
			case .bookmarks: String.localized(.appUI.onboarding.makeItYours.category.bookmarks)
			case .openTabs: String.localized(.appUI.migration.openTabs)
			case .archivedTabs: String.localized(.appUI.migration.archivedTabs)
			case .history: String.localized(.appUI.migration.history)
			case .extensions: String.localized(.appUI.migration.extensions)
			case .preferences: String.localized(.appUI.migration.preferences)
			case .passwords: String.localized(.appUI.onboarding.makeItYours.category.passwords)
			}
		}

		fileprivate var symbol: String {
			switch self {
			case .favorites: "star"
			case .bookmarks: "pin"
			case .openTabs: "square.on.square"
			case .archivedTabs: "archivebox"
			case .history: "clock.arrow.circlepath"
			case .extensions: "puzzlepiece.extension"
			case .preferences: "gearshape"
			case .passwords: "key"
			}
		}
	}

	/// One category the chosen browser has, with its switch.
	public struct Row: Identifiable, Equatable {
		public var category: Category

		/// Items to bring.
		public var count: Int

		/// Folders that come with them, for bookmarks and pinned tabs.
		public var folders: Int

		/// Items this destination already has from an earlier import.
		public var alreadyImported: Int

		/// Extensions only: how many come from the Chrome Web Store and are installed, with
		/// the user's review of each, after the import (DEV-845).
		public var fromStore: Int
		public var isOn: Bool

		public var id: Category { category }

		public init(
			category: Category,
			count: Int,
			folders: Int = 0,
			alreadyImported: Int = 0,
			fromStore: Int = 0,
			isOn: Bool
		) {
			self.category = category
			self.count = count
			self.folders = folders
			self.alreadyImported = alreadyImported
			self.fromStore = fromStore
			self.isOn = isOn
		}
	}

	public enum Problem: Equatable, Sendable {
		case discoveryFailed
		case missingDestination
		case inspectionFailed(String)
		case sourceChanged(String)
		case importFailed
	}

	public struct Choosing: Equatable {
		public var browserName: String

		/// The chosen browser is being read; rows appear once it's done.
		public var isReading: Bool
		public var rows: [Row]

		/// "Keep its spaces", when the browser has spaces.
		public var keepsSpaces: Bool?

		/// Passwords and sign-ins can come from this browser, through Customize (DEV-842).
		public var offersPasswords: Bool

		/// Categories Arx can't bring from this browser yet.
		public var unavailable: [Category]
		public var problem: Problem?

		/// The workspace came from iCloud (DEV-1215): the card says so, and lists only what
		/// iCloud doesn't sync.
		public var fromICloud: Bool

		public init(
			browserName: String,
			isReading: Bool,
			rows: [Row],
			keepsSpaces: Bool?,
			offersPasswords: Bool = false,
			unavailable: [Category],
			problem: Problem? = nil,
			fromICloud: Bool = false
		) {
			self.browserName = browserName
			self.isReading = isReading
			self.rows = rows
			self.keepsSpaces = keepsSpaces
			self.offersPasswords = offersPasswords
			self.unavailable = unavailable
			self.problem = problem
			self.fromICloud = fromICloud
		}
	}

	public struct Importing: Equatable {
		public var browserName: String
		public var category: Category?
		public var fraction: Double
		public var isCancelling: Bool

		public init(
			browserName: String,
			category: Category?,
			fraction: Double,
			isCancelling: Bool
		) {
			self.browserName = browserName
			self.category = category
			self.fraction = fraction
			self.isCancelling = isCancelling
		}
	}

	public struct Result: Equatable {
		public enum Outcome: Equatable, Sendable {
			case completed
			case partiallyCompleted
			case failed
			case cancelled
		}

		public var browserName: String
		public var outcome: Outcome
		public var importedCount: Int

		/// Extensions to reinstall by hand.
		public var reinstalls: [String]

		/// Store extensions installed after the import (DEV-845), when there were any.
		public var extensions: Extensions?
		public var problem: Problem?

		public init(
			browserName: String,
			outcome: Outcome,
			importedCount: Int,
			reinstalls: [String] = [],
			extensions: Extensions? = nil,
			problem: Problem? = nil
		) {
			self.browserName = browserName
			self.outcome = outcome
			self.importedCount = importedCount
			self.reinstalls = reinstalls
			self.extensions = extensions
			self.problem = problem
		}

		/// Chrome Web Store extensions, installed one at a time after the user reviews each.
		public struct Extensions: Equatable, Sendable {
			/// While installing: the one under way and how many there are.
			public var position: Int?
			public var total: Int
			public var installed: Int

			/// Declined, skipped or failed.
			public var notInstalled: Int

			/// While installing, the rest can still be skipped: nothing accepted is under way.
			public var canSkip: Bool

			public init(
				position: Int? = nil,
				total: Int,
				installed: Int = 0,
				notInstalled: Int = 0,
				canSkip: Bool = true
			) {
				self.position = position
				self.total = total
				self.installed = installed
				self.notInstalled = notInstalled
				self.canSkip = canSkip
			}
		}

		fileprivate var symbol: String {
			outcome == .completed ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
		}

		fileprivate var message: String {
			switch outcome {
			case .completed: String.localized(.appUI.onboarding.makeItYours.result.completed(browserName))
			case .partiallyCompleted: String.localized(.appUI.onboarding.makeItYours.result.partial(browserName))
			case .failed: String.localized(.appUI.onboarding.makeItYours.result.failed(browserName))
			case .cancelled: String.localized(.appUI.onboarding.makeItYours.result.cancelled)
			}
		}
	}

	public enum Content: Equatable {
		case discovering

		/// No browser Arx can import from, or looking for them failed.
		case noBrowsers(Problem?)
		case choosing(Choosing)

		/// The chosen browser's data needs Full Disk Access, which Arx doesn't have yet.
		case needsFullDiskAccess(FullDiskAccess)
		case importing(Importing)
		case finished(Result)
	}

	public struct FullDiskAccess: Equatable {
		public var browserName: String

		/// Arx checked and doesn't have it; otherwise it hasn't been checked yet.
		public var isDenied: Bool

		public init(
			browserName: String,
			isDenied: Bool
		) {
			self.browserName = browserName
			self.isDenied = isDenied
		}
	}

	/// What VoiceOver says when the page's state changes in a way that isn't focused.
	fileprivate var announcement: String? {
		switch content {
		case let .finished(result): result.message
		case let .importing(importing) where importing.isCancelling: String.localized(.appUI.onboarding.makeItYours.cancelling)
		case .discovering, .noBrowsers, .choosing, .needsFullDiskAccess, .importing: nil
		}
	}
}

// MARK: - Parts

/// A rounded card holding rows separated by hairlines.
private struct OnboardingImportCard<Content: View>: View {
	internal let content: Content

	internal init(@ViewBuilder content: () -> Content) {
		self.content = content()
	}

	internal var body: some View {
		let shape: RoundedRectangle = .init(cornerRadius: 12, style: .continuous)

		VStack(spacing: 0) {
			Group(subviews: content) { subviews in
				ForEach(subviews.indices, id: \.self) { index in
					if index > 0 {
						Divider()
					}
					subviews[index]
				}
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 4)
		.frame(width: 420)
		.background(.background, in: shape)
		.overlay { shape.strokeBorder(.primary.opacity(0.08), lineWidth: 1) }
		.shadow(color: .black.opacity(0.08), radius: 10, y: 4)
	}
}

/// A row of the import card, as a settings list draws one: the symbol, the title and an optional
/// subtitle on the left, and its switch, if any, on the right, so every row's switch lines up.
private struct OnboardingImportRow<Accessory: View>: View {
	internal let symbol: String
	internal let title: String
	internal let subtitle: String?
	internal let isDimmed: Bool
	internal let accessory: Accessory

	internal init(
		symbol: String,
		title: String,
		subtitle: String? = nil,
		isDimmed: Bool = false,
		@ViewBuilder accessory: () -> Accessory
	) {
		self.symbol = symbol
		self.title = title
		self.subtitle = subtitle
		self.isDimmed = isDimmed
		self.accessory = accessory()
	}

	internal var body: some View {
		HStack(spacing: 10) {
			Image(systemName: symbol)
				.foregroundStyle(isDimmed ? .tertiary : .secondary)
				.frame(width: 18)
				.accessibilityHidden(true)

			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.foregroundStyle(isDimmed ? .secondary : .primary)
					.fixedSize(horizontal: false, vertical: true)
				if let subtitle {
					Text(subtitle)
						.font(.caption)
						.foregroundStyle(isDimmed ? .tertiary : .secondary)
						.fixedSize(horizontal: false, vertical: true)
				}
			}
			.frame(maxWidth: .infinity, alignment: .leading)

			accessory
		}
		.padding(.vertical, 8)
		.frame(minHeight: 40)
		.accessibilityElement(children: .combine)
	}
}

/// A row's switch. The row shows the title, so the switch hides its own label but keeps it for
/// VoiceOver.
private struct OnboardingImportSwitch: View {
	internal let title: String
	internal let isOn: Binding<Bool>

	internal var body: some View {
		Toggle(title, isOn: isOn)
			.toggleStyle(.switch)
			.controlSize(.small)
			.labelsHidden()
	}
}

private struct OnboardingImportCategoryRow: View {
	internal let row: OnboardingImportSummary.Row
	internal let toggle: () -> Void

	internal var body: some View {
		OnboardingImportRow(
			symbol: row.category.symbol,
			title: countText,
			subtitle: subtitle
		) {
			OnboardingImportSwitch(
				title: countText,
				isOn: .init(
					get: { row.isOn },
					set: { _ in toggle() }
				)
			)
		}
		.disabled(row.count == 0)
	}

	private var subtitle: String? {
		if row.category == .extensions, row.fromStore > 0 {
			return String.localized(.appUI.onboarding.makeItYours.extensions.fromStore(row.fromStore))
		}
		return row.alreadyImported > 0
		? String.localized(.appUI.onboarding.makeItYours.alreadyImported(row.alreadyImported))
		: nil
	}

	private var countText: String {
		switch row.category {
		case .favorites: String.localized(.appUI.onboarding.makeItYours.count.favorites(row.count))
		case .bookmarks: String.localized(.appUI.onboarding.makeItYours.count.bookmarks(row.count, row.folders))
		case .openTabs: String.localized(.appUI.onboarding.makeItYours.count.openTabs(row.count))
		case .archivedTabs: String.localized(.appUI.onboarding.makeItYours.count.archivedTabs(row.count))
		case .history: String.localized(.appUI.onboarding.makeItYours.count.history(row.count))
		case .extensions: String.localized(.appUI.onboarding.makeItYours.count.extensions(row.count))
		case .preferences, .passwords: row.category.title
		}
	}
}

private struct OnboardingBrowserTile: View {
	internal let browser: OnboardingImportSummary.Browser
	internal let isEnabled: Bool
	internal let select: () -> Void

	internal var body: some View {
		Button(action: select) {
			VStack(spacing: 4) {
				icon
					.frame(width: 40, height: 40)
					.padding(4)
					.background {
						RoundedRectangle(cornerRadius: 12, style: .continuous)
							.fill(browser.isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
					}
					.overlay {
						RoundedRectangle(cornerRadius: 12, style: .continuous)
							.strokeBorder(browser.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
					}

				Text(browser.name)
					.font(.callout.weight(browser.isSelected ? .semibold : .regular))
					.lineLimit(1)
				Text(statusText)
					.font(.caption2)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}
			.frame(width: 100)
			.opacity(browser.status == .unsupported ? 0.45 : 1)
			.contentShape(.rect)
		}
		.buttonStyle(.plain)
		.disabled(browser.status == .unsupported || !isEnabled)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(Text(verbatim: "\(browser.name), \(statusText)"))
		.accessibilityAddTraits(browser.isSelected ? [.isButton, .isSelected] : .isButton)
	}

	@ViewBuilder
	private var icon: some View {
		if let image = browser.icon {
			Image(nsImage: image)
				.resizable()
				.interpolation(.high)
		} else {
			Image(systemName: "globe")
				.font(.system(size: 26))
				.foregroundStyle(.secondary)
		}
	}

	private var statusText: String {
		switch browser.status {
		case .defaultBrowser: String.localized(.appUI.onboarding.makeItYours.status.defaultBrowser)
		case .usedMostRecently: String.localized(.appUI.onboarding.makeItYours.status.recent)
		case .onThisMac: String.localized(.appUI.onboarding.makeItYours.status.found)
		case .unsupported: String.localized(.appUI.onboarding.makeItYours.status.unsupported)
		}
	}
}
