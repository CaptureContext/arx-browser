import BrowserAutomationClient
import BrowserCore
import BrowserDownloadsClient
import Foundation
import MainFeature
import _ComposableArchitecture

extension AppFeature.State {
	/// Every item of a kind the grant covers, newest first, before filtering and paging.
	/// History and downloads are profile-wide, so they need a whole-profile grant; archived
	/// tabs also show for a granted original space.
	internal func automationDataItems(
		_ kind: AutomationDataRequest.Kind,
		client: AutomationClient
	) -> [AutomationDataItem] {
		func revision(_ fields: [String]) -> String {
			AutomationSecurity.digest(Data((fields + [client.grantRevision.uuidString]).joined(separator: "\u{1F}").utf8))
		}
		func sanitized(_ url: URL?) -> (String?, String?) {
			guard let url, let value = AutomationAccess.sanitizedURL(url), value.utf8.count <= 2048
			else { return (nil, nil) }
			return (value, url.host(percentEncoded: false))
		}

		let items: [AutomationDataItem]
		switch kind {
		case .history:
			items = workspace.profiles
				.filter { AutomationAccess.permitsProfile($0.id, client: client) }
				.flatMap { profile in
					(history.snapshots[profile.id]?.entries ?? []).map { entry in
						let (url, host) = sanitized(entry.url)
						return AutomationDataItem(
							id: entry.id,
							kind: .history,
							title: String(entry.title.prefix(256)),
							url: url,
							host: host,
							profileID: profile.id.rawValue,
							date: entry.lastVisited,
							revision: revision(["history", entry.id.uuidString, entry.url.absoluteString, "\(entry.lastVisited)"])
						)
					}
				}

		case .archive:
			items = workspace.archive.compactMap { entry in
				let spaceGranted = AutomationAccess.permitsSpace(entry.originalSpaceID, client: client, organization: workspace)
				guard spaceGranted || AutomationAccess.permitsProfile(entry.tab.profileID, client: client)
				else { return nil }

				let (url, host) = sanitized(entry.tab.restoration.url)
				return AutomationDataItem(
					id: entry.id.rawValue,
					kind: .archive,
					title: String(entry.tab.displayTitle.prefix(256)),
					url: url,
					host: host,
					profileID: entry.tab.profileID.rawValue,
					spaceID: spaceGranted ? entry.originalSpaceID.rawValue : nil,
					date: entry.closedAt,
					revision: revision(["archive", entry.id.rawValue.uuidString, entry.tab.restoration.url.absoluteString])
				)
			}

		case .downloads:
			items = downloads.queue.downloads.compactMap { download in
				guard
					!download.isPrivate,
					AutomationAccess.permitsProfile(download.id.profileID, client: client)
				else { return nil }

				let (url, host) = sanitized(download.url)
				return AutomationDataItem(
					id: download.id.automationID,
					kind: .downloads,
					title: String(download.filename.prefix(256)),
					url: url,
					host: host,
					profileID: download.id.profileID.rawValue,
					date: download.startedAt,
					status: download.status.rawValue,
					receivedBytes: download.receivedBytes,
					totalBytes: download.totalBytes,
					revision: revision([
						"download", download.id.guid, download.status.rawValue,
						String(download.receivedBytes), String(download.totalBytes), "\(download.isMissing)",
					])
				)
			}
		}
		return items.sorted { $0.date > $1.date }
	}

	/// A page of granted items. The cursor carries a fingerprint of the whole filtered list,
	/// so a page never mixes two versions of it: any change returns `staleCursor`.
	internal func automationData(
		_ request: AutomationDataRequest,
		client: AutomationClient
	) -> Result<AutomationDataPage, AutomationFailure> {
		do {
			try request.validate()
		} catch {
			return .failure(.invalidRequest)
		}
		guard client.allows(AutomationOperation.data(request).requiredCapabilities)
		else { return .failure(.denied) }

		let needle = request.query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
		let items = automationDataItems(request.kind, client: client).filter { item in
			needle.isEmpty
			|| item.title.lowercased().contains(needle)
			|| (item.url?.lowercased().contains(needle) ?? false)
		}
		let fingerprint = String(
			AutomationSecurity.digest(Data((items.map(\.revision) + [needle]).joined(separator: ",").utf8)).prefix(16)
		)

		let offset: Int
		if let cursor = request.cursor {
			let parts = cursor.split(separator: ":")
			guard
				parts.count == 2,
				parts[0] == fingerprint,
				let value = Int(parts[1]),
				(0..<items.count).contains(value)
			else { return .failure(.staleCursor) }
			offset = value

		} else {
			offset = 0
		}

		let end = min(items.count, offset + request.limit)
		return .success(.init(
			request: request,
			items: Array(items[offset..<end]),
			nextCursor: end < items.count ? "\(fingerprint):\(end)" : nil
		))
	}

	/// Clean Copy, Proxy Link and bang resolution, with the user's own rules and shortcuts,
	/// then the bundled !bang list, as the command bar resolves them.
	internal func automationLink(_ request: AutomationLinkRequest) -> Result<AutomationLinkResult, AutomationFailure> {
		do {
			try request.validate()
		} catch {
			return .failure(.invalidRequest)
		}

		switch request.kind {
		case .clean, .proxy:
			guard let url = request.url else { return .failure(.invalidRequest) }
			let item = LinkCopyItem(title: "", url: url)
			let transformation = request.kind == .clean
			? LinkTransformer.clean(item)
			: LinkTransformer.proxy(item, rules: settings.proxyLinkRules)
			let outcome: String = switch transformation.outcome {
			case .original: "original"
			case .cleaned: "cleaned"
			case .sensitiveParametersPreserved: "sensitiveParametersPreserved"
			case .noTrackingParameters: "noTrackingParameters"
			case .proxy: "proxied"
			case .noMatchingRule: "noMatchingRule"
			case .preserved: "preserved"
			}
			return .success(.init(request: request, url: transformation.output.absoluteString, outcome: outcome))

		case .bang:
			guard let query = request.query?.trimmingCharacters(in: .whitespaces), !query.isEmpty
			else { return .failure(.invalidRequest) }

			let body = query.hasPrefix("!") ? String(query.dropFirst()) : query
			let keyword = String(body.prefix(while: { !$0.isWhitespace })).lowercased()
			let rest = body.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
			guard
				let target = settings.bangs.target(for: keyword, shortcuts: settings.searchShortcuts),
				let url = try? target.destination(for: rest)
			else { return .failure(.routeUnresolved) }

			return .success(.init(request: request, url: url.absoluteString, outcome: "resolved"))
		}
	}

	/// Checks an archived-tab or download target against the grant and its current revision.
	internal func automationDataTargetValidation(
		_ command: AutomationCommand,
		client: AutomationClient
	) -> AutomationFailure? {
		let kind: AutomationDataRequest.Kind = command.action.targetKind == .archived ? .archive : .downloads
		guard client.allows(AutomationOperation.data(.init(kind: kind)).requiredCapabilities)
		else { return .denied }
		guard let item = automationDataItems(kind, client: client).first(where: { $0.id == command.targetID })
		else { return .denied }
		guard item.revision == command.expectedRevision else { return .staleTarget }

		if let destinationID = command.destinationID {
			let destination = AutomationInventoryBuilder.item(
				destinationID,
				kind: .space,
				client: client,
				organization: workspace,
				snapshots: [:]
			)
			guard
				command.action == .restoreArchived,
				let destination
			else { return .denied }
			guard destination.revision == command.destinationRevision else { return .staleTarget }
			guard destination.profileID == item.profileID
			else { return .crossProfileTransferUnsupported }
		}
		return nil
	}
}

extension BrowserAutomation {
	internal func readData(
		_ id: UUID,
		client: AutomationClient,
		state: inout State
	) -> Effect<Action> {
		guard let pending = state.automation.pending[id] else { return .none }

		let result: AutomationResult
		switch pending.request.operation {
		case let .data(request):
			switch state.automationData(request, client: client) {
			case let .success(page): result = .data(page)
			case let .failure(failure): result = .failure(failure)
			}

		case let .link(request):
			switch state.automationLink(request) {
			case let .success(link): result = .link(link)
			case let .failure(failure): result = .failure(failure)
			}

		default:
			result = .failure(.invalidRequest)
		}
		return finish(id, result: result, state: &state)
	}

	/// Restores an archived tab through the archive's own model transaction, opening the
	/// copy before committing. The entry leaves the archive, so a retry finds nothing to restore.
	internal func restoreArchived(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let previous = state.workspace
		let destination = command.destinationID
			.flatMap { previous.spaces[id: .init(rawValue: $0)] }
			.map(ArchiveDestination.init(space:))
		let updated: BrowserOrganization
		do {
			updated = try previous.restoringArchive([.init(rawValue: command.targetID)], to: destination, uuid: { uuid() })
		} catch TabArchiveError.missingDestination {
			// The original space is gone; the client has to name a granted one.
			return finish(id, result: .failure(.routeUnresolved), state: &state)
		} catch {
			return finish(id, result: .failure(.invalidRequest), state: &state)
		}
		guard !state.main.archive.isWorking
		else { return finish(id, result: .failure(.busy), state: &state) }

		let copies = Array(updated.tabs.filter { !previous.tabs.ids.contains($0.id) })
		state.automation.pending[id]?.executing = true
		return .run { [engine, control] send in
			do {
				for profile in Set(copies.map(\.profileID)) { try await engine.prepareProfile(profile) }
				for tab in copies {
					try Task.checkCancellation()
					try await engine.openAuthorized(tab) { control.authorize(id) }
				}
				await send(.automation(.event(.archiveRestored(id, previous, updated, copies))))
			} catch {
				for tab in copies { await engine.close(tab.id) }
				let failure = error as? AutomationFailure ?? .engineFailed
				await send(.automation(.event(.managementFailed(id, failure))))
			}
		}
		.cancellable(id: id)
	}

	internal func archiveRestored(
		_ id: UUID,
		previous: BrowserOrganization,
		updated: BrowserOrganization,
		copies: [BrowserCore.Tab],
		state: inout State
	) -> Effect<Action> {
		guard
			let pending = state.automation.pending[id],
			case let .command(command) = pending.request.operation
		else { return .run { [engine] _ in for tab in copies { await engine.close(tab.id) } } }

		let failure = state.automationValidation(pending, snapshots: pending.snapshots, now: now)
		guard failure == nil, state.workspace == previous else {
			return .merge(
				.run { [engine] _ in for tab in copies { await engine.close(tab.id) } },
				finish(id, result: .failure(failure ?? .staleTarget), state: &state)
			)
		}

		let committed = commit(updated, for: id, state: &state)
		let observed = copies.map { tab in
			Effect<Action>.run { [engine] send in
				for await navigation in await engine.events(tab.id) {
					await send(.main(.viewer(.item(.delegate(.navigation(tab.id, navigation))))))
				}
			}
			.cancellable(id: RestoredObservationID(tabID: tab.id), cancelInFlight: true)
		}
		let result = AutomationCommandResult(
			operationID: command.operationID,
			status: .acceptedLoading,
			targetID: copies.first?.id.rawValue
		)
		return .merge([committed] + observed + [finish(id, result: .command(result), state: &state)])
	}

	internal func downloadCommand(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		guard let download = state.downloads.queue.downloads.first(where: { $0.id.automationID == command.targetID })
		else { return finish(id, result: .failure(.staleTarget), state: &state) }

		state.automation.pending[id]?.executing = true
		return .run { [downloads] send in
			do {
				if command.action == .cancelDownload {
					try await downloads.cancel(download.id)
				} else {
					try await downloads.reveal(download.id)
				}

				// Downloads aren't inventory items, so the receipt names no target.
				let result = AutomationCommandResult(operationID: command.operationID, status: .committed)
				await send(.automation(.event(.finished(id, .command(result)))))
			} catch {
				await send(.automation(.event(.finished(id, .failure(.unsupported)))))
			}
		}
		.cancellable(id: id)
	}
}

extension BrowserAutomation {
	/// Starts the approved download in the target profile and answers with its automation ID
	/// once Chromium has created the item. The transfer then continues in the queue.
	internal func startDownload(
		_ id: UUID,
		command: AutomationCommand,
		state: inout State
	) -> Effect<Action> {
		let profileID = Profile.ID(rawValue: command.targetID)
		guard
			let url = command.url,
			state.workspace.profiles[id: profileID] != nil
		else { return finish(id, result: .failure(.invalidRequest), state: &state) }

		state.automation.pending[id]?.executing = true
		return .run { [downloads] send in
			let result: AutomationResult
			do {
				let download = try await downloads.start(profileID, url)
				result = .command(.init(
					operationID: command.operationID,
					status: .acceptedLoading,
					targetID: download.automationID
				))
			} catch BrowserDownloadsClient.Failure.startTimedOut {
				result = .failure(.timedOut)
			} catch BrowserDownloadsClient.Failure.couldNotStart {
				result = .failure(.engineFailed)
			} catch {
				result = .failure(.unsupported)
			}

			// The ledger already has the item; hand it to state with the result, in order.
			await send(.automation(.event(.downloadStarted(id, await downloads.snapshot(), result))))
		}
	}
}

private struct RestoredObservationID: Hashable {
	private let tabID: BrowserCore.Tab.ID

	fileprivate init(tabID: BrowserCore.Tab.ID) {
		self.tabID = tabID
	}
}
