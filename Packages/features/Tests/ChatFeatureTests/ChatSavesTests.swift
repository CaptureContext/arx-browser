import AgentClient
import CustomDump
import Foundation
import Testing
@testable import ChatFeature
import _ComposableArchitecture

/// A kept chat's saves land in the order the chat asked for them, whatever order their
/// effects run in.
@Suite
internal struct ChatSavesTests {
	private static func chat(_ title: String) -> AgentConversation {
		.init(
			id: .init(rawValue: UUID(1)),
			profileID: ChatWorld.profileID,
			provider: .claude,
			title: title,
			createdAt: .distantPast,
			updatedAt: .distantPast,
			retention: .persistent
		)
	}

	/// What the saves wrote, and a first write that waits until it's let go.
	private final class Disk: Sendable {
		let written: LockIsolated<[String]> = .init([])
		let started: AsyncStream<Void>
		let release: AsyncStream<Void>
		private let startedContinuation: AsyncStream<Void>.Continuation
		let releaseContinuation: AsyncStream<Void>.Continuation

		init() {
			(started, startedContinuation) = AsyncStream.makeStream()
			(release, releaseContinuation) = AsyncStream.makeStream()
		}

		var write: @Sendable (AgentConversation) async throws -> Void {
			{ [self] conversation in
				if conversation.title == "slow" {
					startedContinuation.yield()
					for await _ in release { break }
				}
				written.withValue { $0.append(conversation.title) }
			}
		}
	}

	@Test
	internal func aNewerSaveWaitsForTheOneBeingWritten() async {
		let saves: ChatSaves = .init()
		let disk: Disk = .init()
		let (first, second) = (saves.next(), saves.next())

		let slow = Task { await saves.save(Self.chat("slow"), serial: first, with: disk.write) }
		for await _ in disk.started { break }
		let newer = Task { await saves.save(Self.chat("newer"), serial: second, with: disk.write) }

		// The newer one can't overtake the write in progress.
		for _ in 0..<100 { await Task.yield() }
		expectNoDifference(disk.written.value, [])

		disk.releaseContinuation.yield()
		await slow.value
		await newer.value
		expectNoDifference(disk.written.value, ["slow", "newer"])
	}

	@Test
	internal func anOlderSaveThatRunsLateIsDropped() async {
		let saves: ChatSaves = .init()
		let disk: Disk = .init()
		let (older, newer) = (saves.next(), saves.next())

		await saves.save(Self.chat("newer"), serial: newer, with: disk.write)
		await saves.save(Self.chat("older"), serial: older, with: disk.write)
		expectNoDifference(disk.written.value, ["newer"])
	}

	/// A save that a newer one replaced still returns only once the newer one is written, so
	/// what runs after it finds the chat saved.
	@Test
	internal func aReplacedSaveReturnsAfterTheNewerOneIsWritten() async {
		let saves: ChatSaves = .init()
		let disk: Disk = .init()
		let (older, newer) = (saves.next(), saves.next())

		let slow = Task { await saves.save(Self.chat("slow"), serial: newer, with: disk.write) }
		for await _ in disk.started { break }
		let replaced = Task {
			await saves.save(Self.chat("older"), serial: older, with: disk.write)
			return disk.written.value
		}
		disk.releaseContinuation.yield()
		let writtenWhenReturned: [String] = await replaced.value
		expectNoDifference(writtenWhenReturned, ["slow"])
		await slow.value
	}

	@Test
	internal func savesWaitingBehindAWriteKeepOnlyTheNewest() async {
		let saves: ChatSaves = .init()
		let disk: Disk = .init()
		let serials = (saves.next(), saves.next(), saves.next())

		let slow = Task { await saves.save(Self.chat("slow"), serial: serials.0, with: disk.write) }
		for await _ in disk.started { break }
		let middle = Task { await saves.save(Self.chat("middle"), serial: serials.1, with: disk.write) }
		let last = Task { await saves.save(Self.chat("last"), serial: serials.2, with: disk.write) }

		// Once the last has come in, the middle one never writes, whenever it comes in.
		while saves.requested(Self.chat("last").id) != serials.2 { await Task.yield() }

		disk.releaseContinuation.yield()
		await slow.value
		await middle.value
		await last.value
		expectNoDifference(disk.written.value, ["slow", "last"])
	}
}
