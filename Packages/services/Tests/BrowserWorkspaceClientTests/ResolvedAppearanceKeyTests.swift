import BrowserCore
import BrowserWorkspaceClient
import Combine
import ConcurrencyExtras
import Dependencies
import Foundation
import Sharing
import Testing
import _TestSupport

@Suite(.dependencies)
@MainActor
internal struct ResolvedAppearanceKeyTests {
	@Test
	internal func overridesResolveOverTheSharedDefault() async throws {
		let fixture: Fixture = .init()
		var organization = fixture.organization
		organization.profiles[0].appearance = .init(grainEnabled: false)
		organization.spaces[0].appearance = .init(tintHue: 30)
		fixture.document.update(organization: organization)

		withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			@Shared(.chromeAppearance)
			var global

			@SharedReader(.chromeAppearance(space: fixture.home))
			var home

			@SharedReader(.chromeAppearance(space: fixture.work))
			var work

			$global.withLock { $0.tint.intensity = 0.6 }

			expectEqual(home.tint, .init(hue: 30, intensity: 0.6))
			#expect(home.grain.isEnabled == false)
			// The other space has only its profile's override.
			expectEqual(work.tint, global.tint)
			#expect(work.grain.isEnabled == false)
		}
	}

	@Test
	internal func overrideEditsReachReaders() async throws {
		let fixture: Fixture = .init()

		withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			@SharedReader(.chromeAppearance(space: fixture.home))
			var home

			var organization = fixture.organization
			organization.spaces[0].appearance = .init(tintHue: 200, grainSize: 2)
			fixture.document.update(organization: organization)

			#expect(home.tint.hue == 200)
			#expect(home.grain.size == 2)

			organization.spaces[0].appearance = nil
			fixture.document.update(organization: organization)

			expectEqual(home, BrowserPreferences().chromeAppearance)
		}
	}

	@Test
	internal func editsThatLeaveTheSpaceAloneDoNotNotifyIt() async throws {
		let fixture: Fixture = .init()
		let yields: LockIsolated<Int> = .init(0)

		withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			@SharedReader(.chromeAppearance(space: fixture.home))
			var home

			let cancellable = $home.publisher.dropFirst().sink { _ in yields.withValue { $0 += 1 } }
			defer { cancellable.cancel() }

			// A tab-like edit, another space's override, and another preference domain.
			var organization = fixture.organization
			organization.spaces[0].name = "Renamed"
			organization.spaces[1].appearance = .init(tintHue: 90)
			fixture.document.update(organization: organization)
			fixture.document.updatePreferences { $0.warnsBeforeQuitting = false }
			#expect(yields.value == 0)

			organization.spaces[0].appearance = .init(tintHue: 90)
			fixture.document.update(organization: organization)
			#expect(yields.value == 1)
		}
	}

	@Test
	internal func swappingTheKeyFollowsTheShownSpace() async throws {
		let fixture: Fixture = .init()
		var organization = fixture.organization
		organization.spaces[1].appearance = .init(tintHue: 300)
		fixture.document.update(organization: organization)

		withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			@SharedReader(.chromeAppearance(space: fixture.home))
			var shown

			expectEqual(shown, BrowserPreferences().chromeAppearance)

			$shown = SharedReader(.chromeAppearance(space: fixture.work))
			#expect(shown.tint.hue == 300)
		}
	}

	@Test
	internal func spacesOutsideTheOrganizationShowTheDefault() async throws {
		let fixture: Fixture = .init()

		withDependencies {
			$0.workspaceDocument = fixture.document
		} operation: {
			@Shared(.chromeAppearance)
			var global

			@SharedReader(.chromeAppearance(space: .init(rawValue: UUID())))
			var privateSpace

			$global.withLock { $0.tint.hue = 15 }
			expectEqual(privateSpace, global)
		}
	}
}

// MARK: - Fixture

@MainActor
private struct Fixture {
	internal let organization: BrowserOrganization
	internal let document: WorkspaceDocument

	internal var home: Space.ID { organization.spaces[0].id }
	internal var work: Space.ID { organization.spaces[1].id }

	internal init() {
		let profile: Profile = .init(id: .init(rawValue: UUID()), name: "Personal")
		self.organization = .init(
			profiles: [profile],
			spaces: [
				.init(id: .init(rawValue: UUID()), profileID: profile.id, name: "Home"),
				.init(id: .init(rawValue: UUID()), profileID: profile.id, name: "Work"),
			]
		)

		// Never flushed, so nothing reaches disk.
		self.document = .init(
			client: .init(file: URL(filePath: "/dev/null/arx-unset-workspace.json")),
			organization: organization,
			preferences: .init()
		)
	}
}

private func expectEqual<Value: Equatable>(
	_ actual: Value,
	_ expected: Value,
	sourceLocation: SourceLocation = #_sourceLocation
) {
	#expect(actual == expected, sourceLocation: sourceLocation)
}
