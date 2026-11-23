import BrowserCore
import Foundation

/// Runs inspection and execution over injected adapters and a destination writer.
internal actor MigrationRunner {
	private var adapters: [MigrationSourceAdapter]
	private let writer: MigrationDestinationWriter
	private var cancelledPlans: Set<MigrationPlan.ID> = []

	internal init(
		adapters: [MigrationSourceAdapter],
		writer: MigrationDestinationWriter
	) {
		self.adapters = adapters
		self.writer = writer
	}

	internal func discover() -> [MigrationSource] {
		adapters.map(\.source)
	}

	/// Offers a file the user picked, replacing an earlier file of the same source.
	internal func addFile(_ url: URL) throws -> MigrationSource {
		let adapter = try MigrationFileSources.adapter(for: url)
		adapters.removeAll { $0.source.id == adapter.source.id }
		adapters.append(adapter)
		return adapter.source
	}

	internal func receivingProfile(
		sourceProfile id: String,
		destination: MigrationDestination
	) async -> Profile? {
		guard let state = try? await writer.state() else { return nil }

		return state.organization.receivingProfile(
			forSourceProfile: id,
			destination: destination,
			ledger: state.ledger
		)
	}

	internal func inspect(
		source sourceID: MigrationSource.ID,
		categories: [MigrationCategory],
		destination: MigrationDestination
	) async throws -> MigrationPreview {
		let adapter = try adapter(for: sourceID)
		let snapshot = try await read(adapter)
		let state = try await writer.state()
		try state.organization.validateMigrationDestination(destination)

		let selected = Set(categories).intersection(adapter.source.categories).sorted()
		return .init(
			sourceID: sourceID,
			snapshotID: snapshot.id,
			destination: destination,
			categories: selected.map { category in
				Self.plan(
					category,
					snapshot: snapshot,
					sourceID: sourceID,
					destination: destination,
					state: state
				)
			},
			spaces: Self.spaces(in: snapshot.records),
			profiles: Self.profiles(in: snapshot.records, issues: snapshot.issues)
		)
	}

	internal func execute(
		_ plan: MigrationPlan,
		emit: @Sendable (MigrationEvent) -> Void
	) async throws {
		cancelledPlans.remove(plan.id)
		let adapter = try adapter(for: plan.sourceID)
		let snapshot = try await read(adapter)
		guard snapshot.id == plan.snapshotID
		else { throw MigrationFailure.sourceChanged }
		try await writer.state().organization.validateMigrationDestination(plan.destination)

		// A Cancel that came while the source and destination were read stops the run before
		// anything is written; one that came while the profiles were made counts even with no
		// categories to stop between, so nothing that follows the run (passwords) starts.
		var wasCancelled = Task.isCancelled || cancelledPlans.contains(plan.id)
		if !wasCancelled {
			await createProfiles(of: plan, source: adapter.source)
			wasCancelled = Task.isCancelled || cancelledPlans.contains(plan.id)
		}

		let total = plan.categories.count
		var results: [MigrationReport.Category] = []
		if wasCancelled {
			results = plan.categories.map { .init(category: $0, status: .notStarted) }
		}
		emit(.progress(
			.init(
				planID: plan.id,
				category: nil,
				completedCategories: 0,
				totalCategories: total
			)
		))

		for (index, category) in plan.categories.enumerated() where !wasCancelled {
			if Task.isCancelled || cancelledPlans.contains(plan.id) {
				wasCancelled = true
				results += plan.categories[index...].map { .init(category: $0, status: .notStarted) }
				break
			}

			emit(.progress(
				.init(
					planID: plan.id,
					category: category,
					completedCategories: index,
					totalCategories: total
				)
			))
			let result: MigrationReport.Category = await run(
				category,
				of: plan,
				source: adapter.source,
				snapshot: snapshot
			)
			results.append(result)
		}

		cancelledPlans.remove(plan.id)
		emit(.progress(
			.init(
				planID: plan.id,
				category: nil,
				completedCategories: results.filter { $0.status != .notStarted }.count,
				totalCategories: total
			)
		))
		emit(.finished(
			.init(
				planID: plan.id,
				outcome: Self.outcome(of: results, cancelled: wasCancelled),
				categories: results
			)
		))
	}

	internal func cancel(_ planID: MigrationPlan.ID) {
		cancelledPlans.insert(planID)
	}

	// MARK: - Helpers

	private func adapter(for sourceID: MigrationSource.ID) throws -> MigrationSourceAdapter {
		guard let adapter = adapters.first(where: { $0.source.id == sourceID })
		else { throw MigrationFailure.unknownSource }
		return adapter
	}

	private func read(_ adapter: MigrationSourceAdapter) async throws -> MigrationSnapshot {
		do {
			return try await adapter.snapshot()
		} catch let failure as MigrationFailure {
			throw failure
		} catch {
			throw MigrationFailure.unreadableSource(error.localizedDescription)
		}
	}

	/// Makes the Arx profile of each of the plan's `profiles` that has none yet, as one
	/// batch of profile records, so passwords can follow a mapping to a new profile even
	/// when no category brings anything there. A failure leaves them missing; the
	/// passwords step then reports those profiles as having no Arx profile.
	private func createProfiles(
		of plan: MigrationPlan,
		source: MigrationSource
	) async {
		guard
			!plan.profiles.isEmpty,
			let state = try? await writer.state()
		else { return }

		let missing = plan.profiles.filter { profile in
			state.organization.receivingProfile(
				forSourceProfile: profile.id,
				destination: plan.destination,
				ledger: state.ledger
			) == nil
		}
		guard !missing.isEmpty else { return }

		try? await writer.commit(
			.init(
				planID: plan.id,
				destination: plan.destination,
				sourceName: source.name,
				category: .favorites,
				items: missing.map { profile in
					.init(
						key: .init(sourceID: plan.sourceID, category: .favorites, sourceItemID: "profile:" + profile.id),
						kind: .profile,
						title: profile.name,
						url: nil,
						profile: profile
					)
				}
			)
		)
	}

	/// Plans and commits one category against the destination's current state, so a
	/// retry skips whatever an earlier attempt already committed.
	private func run(
		_ category: MigrationCategory,
		of plan: MigrationPlan,
		source: MigrationSource,
		snapshot: MigrationSnapshot
	) async -> MigrationReport.Category {
		let planned: MigrationPreview.Category
		do {
			planned = Self.plan(
				category,
				snapshot: snapshot,
				sourceID: plan.sourceID,
				destination: plan.destination,
				state: try await writer.state()
			)
		} catch {
			return .init(
				category: category,
				status: .failed,
				issues: [
					.init(
						sourceItemID: nil,
						category: category,
						reason: .commitFailed(error.localizedDescription)
					),
				]
			)
		}

		var result: MigrationReport.Category = .init(
			category: category,
			status: .committed,
			alreadyImported: planned.alreadyImported,
			issues: planned.issues
		)
		guard !planned.items.isEmpty || planned.preferences != nil else { return result }

		do {
			try await writer.commit(
				.init(
					planID: plan.id,
					destination: plan.destination,
					sourceName: source.name,
					category: category,
					items: planned.items,
					preferences: planned.preferences,
					preferencesKey: planned.preferencesKey
				)
			)
			result.imported = planned.items.map(\.key) + [planned.preferencesKey].compactMap { $0 }
		} catch {
			result.status = .failed
			result.issues.append(
				.init(
					sourceItemID: nil,
					category: category,
					reason: .commitFailed(error.localizedDescription)
				)
			)
		}
		return result
	}

	internal static func plan(
		_ category: MigrationCategory,
		snapshot: MigrationSnapshot,
		sourceID: MigrationSource.ID,
		destination: MigrationDestination,
		state: MigrationDestinationState
	) -> MigrationPreview.Category {
		var result: MigrationPreview.Category = .init(
			category: category,
			issues: snapshot.issues.filter { $0.category == category }
		)
		if category == .preferences, let preferences = snapshot.preferences {
			let key: MigrationItemKey = .init(
				sourceID: sourceID,
				category: .preferences,
				sourceItemID: MigrationBrowserSources.digest(of: preferences)
			)
			if state.ledger.hasApplied(key) {
				result.alreadyImported.append(key)
			} else {
				result.preferences = preferences
				result.preferencesKey = key
			}
		}
		var seenItems: Set<String> = []

		for record in snapshot.records where record.category == category {
			guard seenItems.insert(record.sourceItemID).inserted else {
				result.issues.append(
					.init(
						sourceItemID: record.sourceItemID,
						category: category,
						reason: .repeatedSourceItem
					)
				)
				continue
			}

			switch record.validated(from: sourceID) {
			case let .failure(issue):
				result.issues.append(issue)

			case let .success(item):
				let isImported = state.organization.hasImported(
					item,
					into: destination,
					ledger: state.ledger
				)
				if isImported {
					result.alreadyImported.append(item.key)
				} else {
					result.items.append(item)
				}
			}
		}
		return result
	}

	private static func spaces(in records: [MigrationRecord]) -> [MigrationSourceSpace] {
		var seen: Set<MigrationSourceSpace.ID> = []
		return records.compactMap(\.space).filter { seen.insert($0.id).inserted }
	}

	/// Profiles in source order: a space's, or the record's own for favorites and history.
	/// Profiles from the records, then those that only have extensions to install (DEV-845),
	/// so the user maps where those go too.
	private static func profiles(
		in records: [MigrationRecord],
		issues: [MigrationIssue] = []
	) -> [MigrationSourceProfile] {
		var seen: Set<String> = []
		let extensions: [MigrationSourceProfile] = issues.compactMap { issue in
			guard
				case let .reinstallManually(value) = issue.reason,
				value.installsFromStore
			else { return nil }
			return value.profile
		}
		return (records.compactMap { $0.space?.profile ?? $0.profile } + extensions)
			.filter { seen.insert($0.id).inserted }
	}

	private static func outcome(
		of results: [MigrationReport.Category],
		cancelled: Bool
	) -> MigrationReport.Outcome {
		if cancelled { return .cancelled }
		let committed = results.filter { $0.status == .committed }.count
		if committed == results.count { return .completed }
		return committed > 0 ? .partiallyCompleted : .failed
	}
}
