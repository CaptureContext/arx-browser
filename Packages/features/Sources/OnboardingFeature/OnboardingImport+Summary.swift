import AppKit
import AppUI
import MigrationAssistant
import MigrationAssistantFeature

extension OnboardingImport.State {
	/// What the "Make it yours" page shows for this state.
	@MainActor
	internal var summary: OnboardingImportSummary {
		.init(
			browsers: browsers,
			content: content,
			canChangeBrowser: phase == .choosing
		)
	}

	@MainActor
	private var browsers: [OnboardingImportSummary.Browser] {
		let recent: MigrationSource.ID? = OnboardingImport.preferredSource(
			in: sources,
			defaultBrowserIdentifier: nil
		)
		.flatMap { $0.lastUsed == nil ? nil : $0.id }

		let supported: [OnboardingImportSummary.Browser] = sources.map { source in
			let status: OnboardingImportSummary.Browser.Status = if
				let identifier = source.applicationIdentifier,
				identifier == defaultBrowserIdentifier
			{
				.defaultBrowser
			} else if source.id == recent {
				.usedMostRecently
			} else {
				.onThisMac
			}

			return .init(
				id: source.id.rawValue,
				name: source.name,
				status: status,
				isSelected: source.id == selectedSourceID,
				icon: OnboardingBrowserIcons.icon(for: source.applicationIdentifier)
			)
		}
		let unsupported: [OnboardingImportSummary.Browser] = unsupportedBrowsers.map { browser in
			.init(
				id: "unsupported:" + browser.id,
				name: browser.name,
				status: .unsupported,
				isSelected: false,
				icon: OnboardingBrowserIcons.icon(for: browser.applicationIdentifier)
			)
		}
		return supported + unsupported
	}

	private var content: OnboardingImportSummary.Content {
		switch phase {
		case .idle, .discovering:
			return .discovering

		case .choosing:
			guard let source = selectedSource else {
				return .noBrowsers(problem.flatMap { summaryProblem($0, browserName: "") })
			}

			guard !needsFullDiskAccess else {
				return .needsFullDiskAccess(.init(browserName: source.name, isDenied: fullDiskAccess == .denied))
			}

			return .choosing(choosing(source))

		case .importing, .cancelling:
			return .importing(
				.init(
					browserName: selectedSource?.name ?? "",
					category: progress?.category.map(OnboardingImportSummary.Category.init),
					fraction: progress?.fractionCompleted ?? 0,
					isCancelling: phase == .cancelling
				)
			)

		case .finished:
			guard let report else { return .discovering }

			return .finished(
				.init(
					browserName: selectedSource?.name ?? "",
					outcome: .init(report.outcome),
					importedCount: report.importedCount,
					reinstalls: reinstalls(report),
					extensions: extensionImport.flatMap(Self.extensionsResult),
					problem: problem.flatMap { summaryProblem($0, browserName: selectedSource?.name ?? "") }
				)
			)
		}
	}

	/// Extensions to reinstall by hand: those Arx can't install from the store, and store
	/// ones whose install failed (DEV-845). Declined and skipped ones were the user's choice.
	private func reinstalls(_ report: MigrationReport) -> [String] {
		let failed: Set<String> = .init(
			extensionImport?.items
				.filter { if case .failed = $0.outcome { true } else { false } }
				.map(\.id) ?? []
		)
		return report.categories
			.filter { $0.category == .extensions }
			.flatMap(\.issues)
			.compactMap { issue in
				guard case let .reinstallManually(value) = issue.reason else { return nil }

				let item: ExtensionImportFeature.Item = .init(extension: value)
				guard
					!value.installsFromStore
					|| failed.contains(item.id)
					|| extensionImport == nil
				else { return nil }
				return value.name
			}
	}

	private static func extensionsResult(
		_ state: ExtensionImportFeature.State
	) -> OnboardingImportSummary.Result.Extensions? {
		let items = state.items.filter(\.extension.installsFromStore)
		guard !items.isEmpty else { return nil }

		return .init(
			position: state.isRunning ? state.position?.index : nil,
			total: items.count,
			installed: items.count { $0.outcome == .installed || $0.outcome == .alreadyInstalled },
			notInstalled: items.count { $0.outcome != nil && $0.outcome != .installed && $0.outcome != .alreadyInstalled },
			canSkip: !state.isResolving
		)
	}

	private func choosing(_ source: MigrationSource) -> OnboardingImportSummary.Choosing {
		let offered: [MigrationCategory] = offeredCategories(of: source)
		let rows: [OnboardingImportSummary.Row] = (preview?.categories ?? [])
			.filter { offered.contains($0.category) }
			.map { category in
				.init(
					category: .init(category.category),
					count: category.category == .preferences
					? (category.preferences == nil ? 0 : 1)
					: category.category == .extensions
					? category.reinstalls.count
					: category.tabCount,
					folders: category.items.count { $0.kind == .folder },
					alreadyImported: category.alreadyImported.count,
					fromStore: category.category == .extensions
					? category.reinstalls.count(where: \.installsFromStore)
					: 0,
					isOn: selectedCategories.contains(category.category)
				)
			}

		return .init(
			browserName: source.name,
			isReading: isInspecting || (preview == nil && problem == nil),
			rows: rows,
			keepsSpaces: source.offersLayouts && !workspaceCameFromICloud ? keepsSpaces : nil,
			offersPasswords: source.offersCredentials,
			unavailable: Self.listedCategories
				.filter { !workspaceCameFromICloud || MigrationCategory.outsideICloud.contains($0) }
				.filter { !source.categories.contains($0) }
				.map(OnboardingImportSummary.Category.init)
			+ (source.offersCredentials ? [] : [.passwords]),
			problem: problem.flatMap { summaryProblem($0, browserName: source.name) },
			fromICloud: workspaceCameFromICloud
		)
	}

	/// The categories the page always lists for a browser, so missing ones show as unavailable.
	private static let listedCategories: [MigrationCategory] = [
		.favorites,
		.bookmarks,
		.openTabs,
		.history,
		.extensions,
	]

	private func summaryProblem(
		_ problem: OnboardingImport.Problem,
		browserName: String
	) -> OnboardingImportSummary.Problem {
		switch problem {
		case .discoveryFailed: .discoveryFailed
		case .missingDestination: .missingDestination
		case .inspectionFailed: .inspectionFailed(browserName)
		case .sourceChanged: .sourceChanged(browserName)
		case .importFailed: .importFailed
		}
	}
}

extension OnboardingImportSummary.Category {
	internal init(_ category: MigrationCategory) {
		switch category {
		case .favorites: self = .favorites
		case .bookmarks: self = .bookmarks
		case .openTabs: self = .openTabs
		case .archivedTabs: self = .archivedTabs
		case .history: self = .history
		case .extensions: self = .extensions
		case .preferences: self = .preferences
		}
	}
}

extension MigrationCategory {
	/// The category a page switch stands for. Passwords have their own row, which opens
	/// Customize.
	internal init?(_ category: OnboardingImportSummary.Category) {
		switch category {
		case .favorites: self = .favorites
		case .bookmarks: self = .bookmarks
		case .openTabs: self = .openTabs
		case .archivedTabs: self = .archivedTabs
		case .history: self = .history
		case .extensions: self = .extensions
		case .preferences: self = .preferences
		case .passwords: return nil
		}
	}
}

extension OnboardingImportSummary.Result.Outcome {
	internal init(_ outcome: MigrationReport.Outcome) {
		switch outcome {
		case .completed: self = .completed
		case .partiallyCompleted: self = .partiallyCompleted
		case .failed: self = .failed
		case .cancelled: self = .cancelled
		}
	}
}

/// App icons for the browser tiles, looked up once per bundle identifier. Only the
/// app's icon is read; nothing in the browser is opened.
@MainActor
private enum OnboardingBrowserIcons {
	private static var cache: [String: NSImage?] = [:]

	internal static func icon(for identifier: String?) -> NSImage? {
		guard let identifier else { return nil }

		if let cached = cache[identifier] { return cached }

		let icon: NSImage? = NSWorkspace.shared
			.urlForApplication(withBundleIdentifier: identifier)
			.map { NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false)) }
		cache[identifier] = icon
		return icon
	}
}
