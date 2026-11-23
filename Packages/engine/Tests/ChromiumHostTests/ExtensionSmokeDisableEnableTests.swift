import CustomDump
import Foundation
import Testing

@testable import ChromiumEngine
@testable import ChromiumHost

@MainActor
internal struct ExtensionSmokeDisableEnableTests {
	@Test
	internal func refreshesAfterUnloadWhileKeepingDeliberateStaleProbe() async throws {
		let fixture = Fixture()
		try await fixture.run {
			fixture.revision = 7
		}

		expectNoDifference(fixture.inspected, [1, 7])
		expectNoDifference(fixture.mutated, [1, 1, 7])
		expectNoDifference(fixture.state, .enabled)
		expectNoDifference(fixture.phases, [
			"disable-inspect", "disable-apply", "stale-probe",
			"disabled-page-reload", "enable-refresh", "enable-apply",
		])
	}

	@Test
	internal func immediateMutationRaceIsNotSilentlyRetried() async throws {
		let fixture = Fixture()
		fixture.rejectFirstMutation = true

		await #expect(throws: ChromiumExtensionFailure.staleInventory) {
			try await fixture.run {
				Issue.record("A failed disable must not proceed to page reload")
			}
		}

		expectNoDifference(fixture.inspected, [1])
		expectNoDifference(fixture.mutated, [1])
		expectNoDifference(fixture.phases.last, "disable-apply")
	}

	@Test
	internal func staleProbeMustActuallyRejectOldAuthority() async throws {
		let fixture = Fixture()
		fixture.acceptStale = true

		await #expect(throws: ExtensionSmokeDisableEnable.Failure.staleAccepted) {
			try await fixture.run {}
		}

		expectNoDifference(fixture.inspected, [1])
		expectNoDifference(fixture.phases.last, "stale-probe")
	}

	@Test
	internal func refreshDoesNotEnableChangedPermissions() async throws {
		let fixture = Fixture()

		await #expect(throws: ExtensionSmokeDisableEnable.Failure.disabledState) {
			try await fixture.run {
				fixture.revision = 7
				fixture.reasons = [.userAction, .permissionsIncrease]
			}
		}

		expectNoDifference(fixture.mutated, [1, 1])
		expectNoDifference(fixture.state, .disabled)
		expectNoDifference(fixture.phases.last, "enable-refresh")
	}

	@Test
	internal func cancellationDuringWaitDoesNotStartAnotherMutation() async throws {
		let fixture = Fixture()

		await #expect(throws: CancellationError.self) {
			try await fixture.run { throw CancellationError() }
		}

		expectNoDifference(fixture.inspected, [1])
		expectNoDifference(fixture.mutated, [1, 1])
	}
}

@MainActor
private final class Fixture {
	fileprivate let extensionID: String = String(repeating: "a", count: 32)
	fileprivate var revision: UInt64 = 1
	fileprivate var state: ChromiumExtensionState = .enabled
	fileprivate var reasons: [ChromiumExtensionDisableReason] = []
	fileprivate var inspected: [UInt64] = []
	fileprivate var mutated: [UInt64] = []
	fileprivate var phases: [String] = []
	fileprivate var rejectFirstMutation: Bool = false
	fileprivate var acceptStale: Bool = false

	fileprivate func run(
		wait: () async throws -> Void
	) async throws {
		try await ExtensionSmokeDisableEnable.run(
			extensionID: extensionID,
			inspect: {
				self.inspected.append(self.revision)
				return self.inventory()
			},
			manage: { action, inventory in
				self.mutated.append(inventory.revision)
				if self.rejectFirstMutation { throw ChromiumExtensionFailure.staleInventory }

				guard inventory.revision == self.revision || self.acceptStale
				else { throw ChromiumExtensionFailure.staleInventory }

				self.revision += 1
				switch action {
				case .disable:
					self.state = .disabled
					self.reasons = [.userAction]

				case .enable:
					self.state = .enabled
					self.reasons = []

				case .remove, .reload, .allowInPrivate, .disallowInPrivate:
					Issue.record("Unexpected fixture action")
				}

				return self.inventory()
			},
			waitUntilUnloaded: wait,
			phase: { self.phases.append($0) }
		)
	}

	private func inventory() -> ChromiumExtensionInventory {
		let permissions: ChromiumExtensionPermissions = .init(apis: [], hosts: [])
		let extension_: ChromiumExtension = .init(
			id: extensionID,
			name: "Fixture",
			version: "1.0",
			manifestVersion: 3,
			location: .unpacked,
			fromWebStore: false,
			state: state,
			disableReasons: reasons,
			permissionsIncreased: reasons.contains(.permissionsIncrease),
			isFixture: true,
			canEnable: state == .disabled && reasons == [.userAction],
			canDisable: state == .enabled,
			canRemove: true,
			requiredPermissions: permissions,
			optionalPermissions: permissions,
			activePermissions: permissions,
			withheldPermissions: permissions
		)

		return .init(
			runtimeID: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
			profileID: nil,
			revision: revision,
			extensions: [extension_]
		)
	}
}
