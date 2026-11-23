import BrowserCore
import CustomDump
import Foundation
import Testing

/// Work an organization edit does that must not grow with spaces or the archive (DEV-947).
internal struct OrganizationScalingTests {
	@Test
	internal func validationChecksSelectionsWithoutSearchingPerSpace() throws {
		let organization = fixture()
		let counts = WorkProbe.Counts()
		try WorkProbe.$counts.withValue(counts) {
			try organization.validate()
		}

		expectNoDifference(counts[.tabLocationSearch], 0)
		expectNoDifference(counts[.archiveValidation], 1)
	}

	@Test
	internal func anEditThatLeavesTheArchiveAloneDoesNotCheckIt() throws {
		var organization = fixture()
		let counts = WorkProbe.Counts()
		try WorkProbe.$counts.withValue(counts) {
			try organization.update { $0.spaces[0].name = "Renamed" }
			try organization.update { $0.spaces[1].selectedTabID = $0.spaces[1].unpinnedTabs.last }
		}
		expectNoDifference(counts[.archiveValidation], 0)
		expectNoDifference(counts[.tabLocationSearch], 0)

		try WorkProbe.$counts.withValue(counts) {
			try organization.update { $0.archive.removeLast() }
		}
		expectNoDifference(counts[.archiveValidation], 1)
		expectNoDifference(organization.archive.count, 4_999)
	}

	@Test
	internal func anEditThatBreaksTheArchiveIsStillRejected() throws {
		var organization = fixture()
		let original = organization

		#expect(throws: TabArchiveError.invalidEntry) {
			try organization.update { $0.archive.append($0.archive[0]) }
		}
		#expect(throws: BrowserOrganization.ValidationError.invalidSelection(
			original.spaces[0].id,
			original.spaces[1].unpinnedTabs[0]
		)) {
			try organization.update { $0.spaces[0].selectedTabID = $0.spaces[1].unpinnedTabs[0] }
		}
		expectNoDifference(organization, original)
	}

	/// Ten spaces of a hundred open tabs, each with a selection, and 5,000 archived tabs.
	private func fixture() -> BrowserOrganization {
		let profile = Profile(id: .init(rawValue: UUID()), name: "Personal")
		let url = URL(string: "https://capturecontext.dev")!
		var tabs: [Tab] = []
		var spaces: [Space] = []
		for index in 0 ..< 10 {
			let open = (0 ..< 100).map { _ in
				Tab(id: .init(rawValue: UUID()), profileID: profile.id, restoration: .init(title: "Open", url: url))
			}
			tabs += open
			spaces.append(Space(
				id: .init(rawValue: UUID()),
				profileID: profile.id,
				name: "Space \(index)",
				unpinnedTabs: open.map(\.id),
				selectedTabID: open[50].id
			))
		}
		let archive = (0 ..< 5_000).map { index in
			ArchivedTab(
				id: .init(rawValue: UUID()),
				groupID: UUID(),
				closedAt: Date(timeIntervalSinceReferenceDate: Double(index)),
				originalSpaceID: spaces[0].id,
				originalSpaceName: "Space 0",
				originalIndex: index,
				tab: .init(id: .init(rawValue: UUID()), profileID: profile.id, restoration: .init(title: "Archived", url: url))
			)
		}
		return .init(profiles: [profile], spaces: spaces, tabs: tabs, archive: archive)
	}
}
