#if DEBUG
import BrowserCore
import BrowserPagePreviewClient
import Foundation
import _ComposableArchitecture

/// DEV-730 in the real app: a Full preview loads an unloaded tab's page off screen in its own
/// profile and takes its picture without a history visit; the picture is saved and read back;
/// clearing the profile's recent history deletes it; and a page's Open Graph picture and
/// description come from the fixture server without cookies.
///
/// `app_smoke.py` serves `hover-preview.html` (Open Graph tags) and `hover-preview.png` next to
/// `index.html`.
internal enum HoverPreviewSmoke {
	@MainActor
	internal static func run(
		store: StoreOf<AppFeature>,
		clients: SidebarPreviewClients,
		baseURL: URL
	) async throws {
		guard let profileID = store.workspace.profiles.first?.id
		else { throw Failure.missingSource }
		let started = Date()

		// Full preview of a tab that was never loaded.
		let fullURL = baseURL.appending(queryItems: [.init(name: "arx_hover_preview_smoke", value: "full")])
		let unloaded = SidebarPreviewPage(
			tab: .init(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Hover preview smoke", url: fullURL)
			),
			isPrivate: false
		)
		guard let key = unloaded.key else { throw Failure.missingSource }
		let picture = await SidebarPagePictures.shared.picture(
			of: unloaded,
			sources: .init(pageDetails: false, fullPages: true),
			clients: clients
		)
		guard let picture, picture.width > 0 else { throw Failure.noFullPreview }
		guard clients.snapshot(unloaded.tab.id) == nil else { throw Failure.tabLoaded }

		try await wait("Full preview picture was not saved") {
			await clients.pagePreviews.picture(key) != nil
		}

		// The page opened for the picture never reaches history.
		try await Task.sleep(for: .seconds(1))
		guard store.history.snapshots.values.allSatisfy({ snapshot in
			!snapshot.entries.contains { $0.url == fullURL }
		}) else { throw Failure.historyVisit }

		// With Full previews off, the saved picture answers.
		let saved = await SidebarPagePictures.shared.picture(
			of: unloaded,
			sources: .init(pageDetails: false, fullPages: false),
			clients: clients
		)
		guard saved != nil else { throw Failure.savedPictureMissing }

		// Clearing the profile's recent history deletes it.
		store.send(.settings(.delegate(.clearHistorySince(profileID, started))))
		try await wait("Clearing history did not delete the saved picture") {
			await clients.pagePreviews.picture(key) == nil
		}

		// The site's own picture and description, fetched without cookies.
		let detailsURL = baseURL.deletingLastPathComponent().appendingPathComponent("hover-preview.html")
		let published = SidebarPreviewPage(
			tab: .init(
				id: .init(rawValue: UUID()),
				profileID: profileID,
				restoration: .init(title: "Hover preview details", url: detailsURL)
			),
			isPrivate: false
		)
		guard let publishedKey = published.key else { throw Failure.missingSource }
		let image = await SidebarPagePictures.shared.picture(
			of: published,
			sources: .init(pageDetails: true, fullPages: false),
			clients: clients
		)
		let summary = await SidebarPageDetails.shared.details(for: publishedKey, clients: clients)?.description
		guard
			image != nil,
			summary == "Arx hover preview smoke description"
		else { throw Failure.noPageDetails }
		guard await clients.pagePreviews.picture(publishedKey) == nil
		else { throw Failure.publishedPictureSaved }
		SidebarPageDetails.shared.forget([profileID])

		print("ARX_HOVER_PREVIEW_SMOKE_SUCCESS")
	}

	@MainActor
	private static func wait(
		_ failure: String,
		until ready: () async -> Bool
	) async throws {
		for _ in 0..<50 {
			if await ready() { return }
			try await Task.sleep(for: .milliseconds(100))
		}
		throw Failure.timedOut(failure)
	}

	private enum Failure: Error {
		case missingSource
		case noFullPreview
		case tabLoaded
		case historyVisit
		case savedPictureMissing
		case noPageDetails
		case publishedPictureSaved
		case timedOut(String)
	}
}
#endif
