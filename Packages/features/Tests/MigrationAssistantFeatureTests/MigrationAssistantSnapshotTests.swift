import AppKit
import Foundation
import MigrationAssistant
import MigrationAssistantFeature
import SwiftUI
import Testing
import _ComposableArchitecture
import _TestSupport

/// Writes offscreen PNGs of the Migration Assistant's Customize view (DEV-791) at the onboarding
/// window's size, light and dark, when `ARX_DESIGN_SNAPSHOTS` names a directory: choosing a
/// source and the kinds of data with Passwords and sign-ins on, the review with the profile
/// mapping and passwords straight from the browser or from a CSV per source profile, and the
/// passwords step after the import (DEV-842).
@MainActor
@Suite(.dependencies, .enabled(if: ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"] != nil))
internal struct MigrationAssistantSnapshotTests {
	private static let size: CGSize = .init(width: 760, height: 540)

	private let destination: MigrationDestination = .init(
		profileID: .init(rawValue: UUID(1)),
		spaceID: .init(rawValue: UUID(2))
	)

	private var arc: MigrationSource {
		.init(
			id: .init(rawValue: "arc"),
			kind: .externalBrowser,
			name: "Arc",
			version: "1.98",
			categories: [.favorites, .bookmarks, .openTabs, .extensions],
			preservesOrganization: true
		)
	}

	private var chrome: MigrationSource {
		.init(
			id: .init(rawValue: "chrome"),
			kind: .externalBrowser,
			name: "Google Chrome",
			categories: [.bookmarks, .openTabs, .history]
		)
	}

	private var credentialSource: CredentialSource {
		.init(
			sourceID: arc.id,
			browserName: "Arc",
			keychainService: "Arc Safe Storage",
			isKeychainItemVerified: true,
			profiles: profiles
		)
	}

	private var profiles: [MigrationSourceProfile] {
		[.init(id: "Default", name: "Personal"), .init(id: "Profile 1", name: "Work")]
	}

	private var workProfile: MigrationAssistantFeature.SpaceOption {
		.init(profileID: .init(rawValue: UUID(7)), profileName: "Work", spaceID: .init(rawValue: UUID(8)), spaceName: "Desk")
	}

	private func credentials(
		_ mode: CredentialMigrationFeature.Mode,
		phase: CredentialMigrationFeature.Phase = .configuring
	) -> CredentialMigrationFeature.State {
		.init(
			sourceID: arc.id,
			sourceName: "Arc",
			mappedProfiles: profiles,
			phase: phase,
			source: credentialSource,
			canWrite: mode == .direct,
			mode: mode
		)
	}

	private var preview: MigrationPreview {
		MigrationPreview(
			sourceID: arc.id,
			snapshotID: "snapshot",
			destination: destination,
			categories: [
				.init(
					category: .bookmarks,
					items: (0..<3).map { index in
						.init(
							key: .init(sourceID: arc.id, category: .bookmarks, sourceItemID: "b\(index)"),
							title: "Bookmark \(index)",
							url: URL(string: "https://example.com/\(index)")!
						)
					},
					issues: [.init(sourceItemID: "bad", category: .bookmarks, reason: .invalidURL)]
				),
				.init(
					category: .openTabs,
					items: [
						.init(
							key: .init(sourceID: arc.id, category: .openTabs, sourceItemID: "t1"),
							title: "News",
							url: URL(string: "https://news.example.org")!
						),
					]
				),
			],
			profiles: profiles
		)
	}

	private func previewing(_ credentials: CredentialMigrationFeature.State?) -> MigrationAssistantFeature.State {
		.init(
			destination: destination,
			spaceOptions: [workProfile],
			mappings: [
				.init(id: "Default", sourceName: "Personal", newName: "Home"),
				.init(id: "Profile 1", sourceName: "Work", profileID: workProfile.profileID),
			],
			mapsToNewProfiles: true,
			phase: .previewing,
			sources: [arc],
			selectedSourceID: arc.id,
			selectedCategories: [.bookmarks, .openTabs],
			preview: preview,
			credentials: credentials
		)
	}

	@Test(arguments: [false, true])
	internal func selecting(dark: Bool) throws {
		let state = MigrationAssistantFeature.State(
			destination: destination,
			mapsToNewProfiles: true,
			phase: .selecting,
			sources: [arc, chrome],
			selectedSourceID: arc.id,
			selectedCategories: [.favorites, .bookmarks],
			credentials: credentials(.direct)
		)
		try write(state, name: "migration-customize-selecting", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func mapping(dark: Bool) throws {
		try write(previewing(credentials(.direct)), name: "migration-customize-mapping", dark: dark)
	}

	/// A cleared name shows the source profile's name as the labelled field's prompt (DEV-847).
	@Test(arguments: [false, true])
	internal func mappingWithEmptyName(dark: Bool) throws {
		var state = previewing(nil)
		state.mappings[id: "Default"]?.newName = ""
		try write(state, name: "migration-customize-mapping-empty-name", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func mappingWithCSVFiles(dark: Bool) throws {
		var credentials = credentials(.csv(.engineNotReady))
		credentials.csvFiles = ["Default": URL(fileURLWithPath: "/tmp/Arx Personal Passwords.csv")]
		try write(previewing(credentials), name: "migration-customize-mapping-csv", dark: dark)
	}

	@Test(arguments: [false, true])
	internal func passwordsAfterTheImport(dark: Bool) throws {
		var credentials = credentials(.direct, phase: .intro)
		credentials.targets = [
			.init(id: "Default", sourceName: "Personal", profileID: .init(rawValue: UUID(9)), profileName: "Home"),
			.init(id: "Profile 1", sourceName: "Work", profileID: workProfile.profileID, profileName: "Work"),
		]
		var state = previewing(credentials)
		state.phase = .finished
		state.report = .init(planID: .init(rawValue: UUID(0)), outcome: .completed, categories: [])
		try write(state, name: "migration-customize-passwords-intro", dark: dark)

		let inventory = CredentialInventory(
			sessionID: UUID(3),
			sourceID: arc.id,
			sourceProfileID: "Default",
			passwordCount: 42,
			sites: [
				.init(host: "github.com", passwordCount: 1, cookieCount: 6),
				.init(host: "google.com", cookieCount: 12),
				.init(host: "news.example.org", sessionOnlyCookieCount: 2),
			]
		)
		state.credentials?.phase = .choosing
		state.credentials?.inventories = [.init(inventory: inventory, selection: .all(in: inventory))]
		try write(state, name: "migration-customize-passwords-choosing", dark: dark)

		// One profile went in, the other's write failed: both are named.
		state.credentials?.phase = .finished
		state.credentials?.inventories = []
		state.credentials?.reports = [
			.init(
				id: "Default",
				report: .init(
					batchID: UUID(4),
					passwords: .init(imported: 40, conflicts: 2),
					sites: [.init(host: "github.com", result: .kept), .init(host: "google.com", result: .signInAgain(.rejected))]
				)
			),
			.init(id: "Profile 1", report: nil),
		]
		try write(state, name: "migration-customize-passwords-partly-failed", dark: dark)
	}

	private func write(
		_ state: MigrationAssistantFeature.State,
		name: String,
		dark: Bool
	) throws {
		let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ARX_DESIGN_SNAPSHOTS"]))

		// No reducer: the view's `.task` must not reach the real service.
		let store: StoreOf<MigrationAssistantFeature> = .init(initialState: state) {
			EmptyReducer()
		}
		let view = MigrationAssistantView(store: store)
			.frame(width: Self.size.width, height: Self.size.height)
		let host = NSHostingView(rootView: view)
		host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
		host.frame = .init(origin: .zero, size: Self.size)
		let window = NSWindow(
			contentRect: .init(origin: .init(x: -10_000, y: -10_000), size: Self.size),
			styleMask: [.borderless],
			backing: .buffered,
			defer: false
		)
		window.isReleasedWhenClosed = false
		window.appearance = host.appearance
		window.contentView = host
		for _ in 0..<6 {
			host.layoutSubtreeIfNeeded()
			RunLoop.main.run(until: .now.addingTimeInterval(0.05))
		}
		let representation = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
		host.cacheDisplay(in: host.bounds, to: representation)
		let data = try #require(representation.representation(using: .png, properties: [:]))
		try data.write(to: directory.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
		window.close()
	}
}
