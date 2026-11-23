@testable import AppFeature
import AppUI
import BrowserCore
import CoreGraphics
import CustomDump
import Foundation
import ImageIO
import UniformTypeIdentifiers
import MainFeature
import Testing
import _ComposableArchitecture
import _TestSupport

/// DEV-634: hover previews for sidebar tabs, favorites and folders.
extension IntegrationFeatureTests {
	@Test
	internal func folderPreviewListsEveryTabGroupedByItsFolders() {
		let folder = SidebarItem(
			id: .folder(UUID(10)),
			title: "Research",
			children: [
				.init(id: .tab(UUID(1)), title: "Overview"),
				.init(
					id: .folder(UUID(11)),
					title: "Papers",
					children: [
						.init(id: .tab(UUID(2)), title: "Attention"),
						.init(id: .folder(UUID(12)), title: "Old", children: [
							.init(id: .tab(UUID(3)), title: "Perceptrons"),
						]),
					]
				),
				.init(id: .tab(UUID(4)), title: "Notes"),
			],
			isExpanded: false
		)
		let used = Date(timeIntervalSince1970: 1_000)
		let preview = SidebarFolderPreview(
			folder: folder,
			tabs: [UUID(2): .init(title: "Attention", url: URL(string: "https://arxiv.org/abs/1706")!, lastUsed: used)]
		)

		expectNoDifference(SidebarFolderPreview.tabIDs(in: folder), [UUID(1), UUID(2), UUID(3), UUID(4)])
		expectNoDifference(
			preview.groups().map { group in group.path },
			[[], ["Papers"], ["Papers", "Old"]]
		)
		expectNoDifference(
			preview.groups().map { group in group.entries.map(\.title) },
			[["Overview", "Notes"], ["Attention"], ["Perceptrons"]]
		)
		#expect(preview.entries.first { $0.id == UUID(2) }?.preview?.lastUsed == used)
	}

	@Test
	internal func sameNamedSubfoldersStayInSeparateGroups() {
		let folder = SidebarItem(
			id: .folder(UUID(10)),
			title: "Research",
			children: [
				.init(id: .folder(UUID(11)), title: "Notes", children: [.init(id: .tab(UUID(1)), title: "First")]),
				.init(id: .folder(UUID(12)), title: "Notes", children: [.init(id: .tab(UUID(2)), title: "Second")]),
			]
		)
		let groups = SidebarFolderPreview(folder: folder, tabs: [:]).groups()
		expectNoDifference(groups.map(\.id), [[UUID(11)], [UUID(12)]])
		expectNoDifference(groups.map { $0.entries.map(\.id) }, [[UUID(1)], [UUID(2)]])
	}

	@Test
	internal func folderPreviewSearchMatchesTitlesAddressesAndFolderNames() {
		let folder = SidebarItem(
			id: .folder(UUID(10)),
			title: "Research",
			children: [
				.init(id: .tab(UUID(1)), title: "Overview"),
				.init(id: .folder(UUID(11)), title: "Papers", children: [
					.init(id: .tab(UUID(2)), title: "Attention"),
				]),
			]
		)
		let preview = SidebarFolderPreview(
			folder: folder,
			tabs: [UUID(1): .init(title: "Overview", url: URL(string: "https://capturecontext.dev/arx")!)]
		)

		expectNoDifference(preview.groups(matching: "attention").flatMap(\.entries).map(\.id), [UUID(2)])
		expectNoDifference(preview.groups(matching: "capturecontext").flatMap(\.entries).map(\.id), [UUID(1)])
		expectNoDifference(preview.groups(matching: "papers").flatMap(\.entries).map(\.id), [UUID(2)])
		expectNoDifference(preview.groups(matching: "papers overview").flatMap(\.entries).map(\.id), [])
		expectNoDifference(preview.groups(matching: "  ").flatMap(\.entries).count, 2)
	}

	@Test
	internal func tabPreviewSiteDropsWWWAndFallsBackToTheAddress() {
		#expect(SidebarTabPreview(title: "", url: URL(string: "https://www.example.com/a")!).site == "example.com")
		#expect(SidebarTabPreview(title: "", url: URL(string: "about:blank")!).site == "about:blank")
	}

	@Test
	internal func tabPreviewsUseLiveTitlesAndTheLatestUse() {
		let organization = fixture()
		var state = AppFeature.State(main: .init(organization: organization, spaceID: organization.spaces[0].id))
		let first = organization.tabs[0]
		let second = organization.tabs[1]
		let viewed = Date(timeIntervalSince1970: 2_000)
		let visited = Date(timeIntervalSince1970: 3_000)
		state.$tabsLastViewed.withLock { $0 = [first.id: viewed, second.id: visited.addingTimeInterval(100)] }
		state.history.snapshots[first.profileID] = .init(
			profileID: first.profileID,
			entries: [
				.init(id: UUID(50), url: first.restoration.url, title: "Example", lastVisited: visited),
				.init(id: UUID(51), url: URL(string: "https://elsewhere.example")!, title: "Other", lastVisited: visited.addingTimeInterval(500)),
			]
		)

		let previews = state.sidebarTabPreviews(
			in: state.main.id,
			tabIDs: [first.id.rawValue, second.id.rawValue, UUID(99)],
			isLoaded: { $0 == first.id }
		)

		expectNoDifference(previews[first.id.rawValue], .init(
			title: first.displayTitle,
			url: first.restoration.url,
			lastUsed: visited,
			isLoaded: true
		))

		// The later of the two sources wins.
		expectNoDifference(previews[second.id.rawValue]?.lastUsed, visited.addingTimeInterval(100))
		#expect(previews[second.id.rawValue]?.isLoaded == false)
		#expect(previews[UUID(99)] == nil)
		#expect(state.sidebarTabPreviews(in: UUID(98), tabIDs: [first.id.rawValue]).isEmpty)
	}

	@Test
	internal func privateWindowPreviewsShowNoLastUse() {
		let organization = fixture()
		let state = AppFeature.State(main: .init(
			organization: organization,
			spaceID: organization.spaces[0].id,
			isPrivate: true
		))
		let tab = organization.tabs[0]
		state.$tabsLastViewed.withLock { $0 = [tab.id: Date(timeIntervalSince1970: 1)] }

		let previews = state.sidebarTabPreviews(in: state.main.id, tabIDs: [tab.id.rawValue])
		#expect(previews[tab.id.rawValue]?.title == tab.displayTitle)
		#expect(previews[tab.id.rawValue]?.lastUsed == nil)
	}

	@Test
	internal func thumbnailsDecodeStraightToTheCardWidth() throws {
		let large = try png(width: 1_200, height: 800)
		let scaled = try #require(SidebarThumbnails.thumbnail(from: large, limits: .init(), maximumWidth: 528))
		#expect(scaled.width == 528)
		#expect(scaled.height == 352)

		let small = try png(width: 400, height: 300)
		let kept = try #require(SidebarThumbnails.thumbnail(from: small, limits: .init(), maximumWidth: 528))
		#expect(kept.width == 400)

		var mislabeled = large
		mislabeled.width = 1_201
		#expect(SidebarThumbnails.thumbnail(from: mislabeled, limits: .init(maximumDimension: 1_000), maximumWidth: 528) == nil)
		#expect(SidebarThumbnails.thumbnail(from: .init(png: Data("nope".utf8), width: 1, height: 1), limits: .init(), maximumWidth: 528) == nil)
	}

	@Test
	@MainActor
	internal func thumbnailCapturesQueueAndDropPicturesOfAnOldDocument() async throws {
		let image = try png(width: 800, height: 500)
		let first = BrowserCore.Tab.ID(rawValue: UUID(201))
		let second = BrowserCore.Tab.ID(rawValue: UUID(202))
		var revisions: [BrowserCore.Tab.ID: UInt64] = [first: 1, second: 1]
		var active = 0
		var overlapped = false
		var captured: [BrowserCore.Tab.ID] = []
		let clients = SidebarPreviewClients(
			snapshot: { id in
				revisions[id].map { .init(navigation: .init(), revision: $0, isVisibleForCapture: false) }
			},
			capture: .init(
				isAvailable: { true },
				offscreenIsAvailable: { true },
				captureAuthorized: { request, _ in
					active += 1
					defer { active -= 1 }
					if active > 1 { overlapped = true }
					try await Task.sleep(for: .milliseconds(20))
					captured.append(request.tabID)

					// The second tab navigates while its picture is being taken.
					if request.tabID == second { revisions[second] = 2 }
					return .init(
						request: request,
						documentID: "fixture",
						image: image,
						viewportWidth: 800,
						viewportHeight: 500,
						deviceScale: 1,
						wasLoading: false
					)
				}
			)
		)

		async let firstImage = SidebarThumbnails.shared.thumbnail(for: first, clients: clients)
		async let secondImage = SidebarThumbnails.shared.thumbnail(for: second, clients: clients)
		let (one, two) = await (firstImage, secondImage)

		#expect(!overlapped)
		#expect(Set(captured) == [first, second])
		#expect(one?.width == 528)
		#expect(two == nil)

		// A fresh look at the same document reuses the picture.
		#expect(await SidebarThumbnails.shared.thumbnail(for: first, clients: clients)?.width == 528)
		#expect(captured.count == 2)
	}

	private func png(
		width: Int,
		height: Int
	) throws -> PageCaptureImage {
		let context = try #require(CGContext(
			data: nil,
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpace(name: CGColorSpace.sRGB)!,
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		))
		let image = try #require(context.makeImage())
		let data = NSMutableData()
		let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
		CGImageDestinationAddImage(destination, image, nil)
		#expect(CGImageDestinationFinalize(destination))
		return .init(png: data as Data, width: width, height: height)
	}
}
