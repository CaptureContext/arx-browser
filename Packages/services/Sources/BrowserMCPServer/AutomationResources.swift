import AgentToolsClient
import BrowserAutomationClient
import BrowserCore
import Foundation
import _MCP

/// MCP resources for granted tabs and their page snapshots, with subscriptions.
///
/// Arx has no push channel to the helper, so subscriptions follow the grant poll: while
/// any are active, each poll reads the granted tabs' revisions and reports the ones that
/// changed. The digest only ever contains granted tabs, so an event cannot disclose
/// ungranted context, and a tab that leaves the grant drops its subscriptions.
internal actor AutomationResources {
	internal static let tabsURI: String = "arx://tabs"
	internal static let downloadsURI: String = "arx://downloads"

	/// Browser events for granted tabs (DEV-924), recorded while a client subscribes to it.
	internal static let eventsURI: String = "arx://events"

	/// Arx's site skills (``AgentSiteSkill``) as `arx://skills/<name>`, for agents without a skill folder.
	internal static let skillsURI: String = "arx://skills"

	private let gateway: AutomationGateway
	private var subscriptions: Set<String> = []
	private var lastDigest: AutomationChangeDigest?
	private var events: [AutomationEvent] = []
	private var nextEventSequence: UInt64 = 1
	private var notify: @Sendable (Notice) async -> Void = { _ in }

	internal init(gateway: AutomationGateway) {
		self.gateway = gateway
	}

	internal enum Notice: Equatable, Sendable {
		case updated(String)
		case listChanged
	}

	internal enum Address: Equatable, Sendable {
		case tabs
		case tab(UUID)
		case snapshot(UUID)
		case downloads

		/// `arx://events`, or `arx://events?after=N` for the events after sequence N.
		case events(after: UInt64)
		case skill(String)

		internal init?(_ uri: String) {
			if uri.hasPrefix(AutomationResources.skillsURI + "/") {
				let name = String(uri.dropFirst(AutomationResources.skillsURI.count + 1))
				guard AgentSiteSkill.named(name) != nil
				else { return nil }
				self = .skill(name)
				return
			}
			if uri == AutomationResources.downloadsURI {
				self = .downloads
				return
			}
			if uri == AutomationResources.eventsURI {
				self = .events(after: 0)
				return
			}
			if uri.hasPrefix(AutomationResources.eventsURI + "?after=") {
				guard let after = UInt64(uri.dropFirst(AutomationResources.eventsURI.count + 7))
				else { return nil }
				self = .events(after: after)
				return
			}
			guard uri.hasPrefix(AutomationResources.tabsURI) else { return nil }
			let rest = uri.dropFirst(AutomationResources.tabsURI.count)
			if rest.isEmpty {
				self = .tabs
				return
			}
			let parts = rest.split(separator: "/", omittingEmptySubsequences: false)
			guard
				parts.count >= 2,
				parts[0].isEmpty,
				let id = UUID(uuidString: String(parts[1]))
			else { return nil }

			switch parts.count {
			case 2: self = .tab(id)
			case 3 where parts[2] == "snapshot": self = .snapshot(id)
			default: return nil
			}
		}

		internal var uri: String {
			switch self {
			case .tabs: AutomationResources.tabsURI
			case let .tab(id): AutomationResources.tabsURI + "/" + id.uuidString
			case let .snapshot(id): AutomationResources.tabsURI + "/" + id.uuidString + "/snapshot"
			case .downloads: AutomationResources.downloadsURI
			case .events: AutomationResources.eventsURI
			case let .skill(name): AutomationResources.skillsURI + "/" + name
			}
		}

		internal var tabID: UUID? {
			switch self {
			case .tabs, .downloads, .events, .skill: nil
			case let .tab(id), let .snapshot(id): id
			}
		}
	}

	internal func register(on server: Server) async {
		notify = { [weak server] notice in
			switch notice {
			case let .updated(uri):
				try? await server?.notify(ResourceUpdatedNotification.message(.init(uri: uri)))

			case .listChanged:
				try? await server?.notify(ResourceListChangedNotification.message())
			}
		}
		await server.withMethodHandler(ListResources.self) { [self] parameters in
			guard parameters.cursor == nil
			else { throw MCPError.invalidParams("Resource cursor is not supported") }
			return .init(resources: try await self.list(), nextCursor: nil)
		}
		await server.withMethodHandler(ListResourceTemplates.self) { _ in
			.init(templates: Self.templates, nextCursor: nil)
		}
		await server.withMethodHandler(ReadResource.self) { [self] parameters in
			.init(contents: [try await self.read(parameters.uri)])
		}
		await server.withMethodHandler(ResourceSubscribe.self) { [self] parameters in
			try await self.subscribe(parameters.uri)
			return .init()
		}
		await server.withMethodHandler(ResourceUnsubscribe.self) { [self] parameters in
			await self.unsubscribe(parameters.uri)
			return .init()
		}
	}

	internal static var templates: [Resource.Template] {
		[
			.init(
				uriTemplate: tabsURI + "/{tabID}",
				name: "tab",
				title: "Granted tab",
				description: "One granted tab's inventory item. Subscribe to follow navigation and loading.",
				mimeType: "application/json"
			),
			.init(
				uriTemplate: tabsURI + "/{tabID}/snapshot",
				name: "tab-snapshot",
				title: "Page snapshot",
				description: "A fresh semantic snapshot of a granted tab. Needs the page content class.",
				mimeType: "application/json"
			),
		]
	}

	// MARK: - Listing and reading

	internal func list() async throws -> [Resource] {
		let grants = await gateway.grants
		guard grants.contains([.read]) else { return [] }

		let inventory = try await inventory()
		var resources: [Resource] = [
			.init(name: "tabs", uri: Self.tabsURI, title: "Granted tabs", mimeType: "application/json"),
			.init(
				name: "events",
				uri: Self.eventsURI,
				title: "Browser events",
				description: "Navigation, loads, page errors, dialogs, permission prompts and downloads in granted "
				+ "tabs. Subscribe to record and follow them; read with ?after=N for the ones after sequence N.",
				mimeType: "application/json"
			),
		]
		for skill in AgentSiteSkill.all {
			resources.append(.init(
				name: skill.name,
				uri: Address.skill(skill.name).uri,
				title: skill.name,
				description: skill.description,
				mimeType: "text/markdown"
			))
		}
		if grants.contains([.downloads]) {
			resources.append(.init(
				name: "downloads",
				uri: Self.downloadsURI,
				title: "Downloads",
				mimeType: "application/json"
			))
		}
		let tabs = inventory.items.filter { $0.kind == .tab }.prefix(200)
		for tab in tabs {
			resources.append(.init(
				name: "tab-" + tab.id.uuidString,
				uri: Address.tab(tab.id).uri,
				title: tab.title,
				mimeType: "application/json"
			))
			if grants.contains([.pageContent]) {
				resources.append(.init(
					name: "snapshot-" + tab.id.uuidString,
					uri: Address.snapshot(tab.id).uri,
					title: tab.title,
					mimeType: "application/json"
				))
			}
		}
		return resources
	}

	internal func read(_ uri: String) async throws -> Resource.Content {
		guard let address = Address(uri)
		else { throw MCPError.invalidParams("Unknown resource") }

		// A skill is Arx's own text, the same for every client, and says nothing about the user's tabs.
		if case let .skill(name) = address, let skill = AgentSiteSkill.named(name) {
			return .text(skill.text, uri: uri, mimeType: "text/markdown")
		}

		if case let .events(after) = address {
			guard await gateway.grants.contains([.read])
			else { throw MCPError.invalidParams("Unknown resource") }

			// The host's own check, now: a paused client or a sign-in privacy lock gets its error, and
			// events of tabs the grant no longer covers stay hidden.
			let digest: AutomationChangeDigest
			switch await gateway.changes() {
			case let .success(value): digest = value
			case let .failure(failure): throw MCPError.internalError(failure.rawValue)
			}
			let visible = Self.visibleEvents(events, after: after, digest: digest)
			let value: Value = .object([
				"recording": .bool(subscriptions.contains(Self.eventsURI)),
				"events": try Value(encoding: visible),
				"next": .int(Int(clamping: nextEventSequence - 1)),
			])
			let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
			return .text(text, uri: uri, mimeType: "application/json")
		}

		if address == .downloads {
			let result = await gateway.perform(.data(.init(kind: .downloads, limit: 100)))
			let value: Value = .object(["untrustedData": .bool(true), "result": try BrowserMCPServer.payload(result)])
			let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
			return .text(text, uri: uri, mimeType: "application/json")
		}

		let inventory = try await inventory()
		let value: Value
		switch address {
		case .downloads, .events, .skill:
			throw MCPError.invalidParams("Unknown resource")

		case .tabs:
			value = .object([
				"untrustedData": .bool(true),
				"items": try Value(encoding: inventory.items.filter { $0.kind == .tab }),
			])

		case let .tab(id):
			guard let item = inventory.items.first(where: { $0.kind == .tab && $0.id == id })
			else { throw MCPError.invalidParams("Unknown resource") }
			value = .object(["untrustedData": .bool(true), "item": try Value(encoding: item)])

		case let .snapshot(id):
			guard let item = inventory.items.first(where: { $0.kind == .tab && $0.id == id })
			else { throw MCPError.invalidParams("Unknown resource") }

			let result = BrowserMCPServer.validated(
				await gateway.perform(.inspect(.init(targetID: id, expectedRevision: item.revision)))
			)
			value = .object(["untrustedData": .bool(true), "result": try BrowserMCPServer.payload(result)])
		}

		let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
		guard text.utf8.count <= AutomationIPC.maximumResponseBytes - 1024
		else { throw MCPError.internalError(AutomationFailure.limitExceeded.rawValue) }
		return .text(text, uri: uri, mimeType: "application/json")
	}

	private func inventory() async throws -> AutomationInventory {
		switch await gateway.fullInventory() {
		case let .success(inventory): return inventory
		case let .failure(failure): throw MCPError.internalError(failure.rawValue)
		}
	}

	// MARK: - Subscriptions

	internal func subscribe(_ uri: String) async throws {
		guard let address = Address(uri)
		else { throw MCPError.invalidParams("Unknown resource") }

		// Skills never change while Arx runs; there's nothing to follow.
		if case .skill = address { throw MCPError.invalidParams("Unknown resource") }

		let grants = await gateway.grants
		guard grants.contains([.read]) else { throw MCPError.invalidParams("Unknown resource") }
		if case .snapshot = address, !grants.contains([.pageContent]) {
			throw MCPError.invalidParams("Unknown resource")
		}
		if address == .downloads, !grants.contains([.downloads]) {
			throw MCPError.invalidParams("Unknown resource")
		}

		let digest: AutomationChangeDigest
		switch await gateway.changes() {
		case let .success(value): digest = value
		case let .failure(failure): throw MCPError.internalError(failure.rawValue)
		}
		if let id = address.tabID, digest.tabs[id] == nil {
			throw MCPError.invalidParams("Unknown resource")
		}
		guard subscriptions.count < 256 || subscriptions.contains(address.uri)
		else { throw MCPError.invalidParams("Too many subscriptions") }

		subscriptions.insert(address.uri)
		if lastDigest == nil { lastDigest = digest }
	}

	internal func unsubscribe(_ uri: String) {
		subscriptions.remove(Address(uri)?.uri ?? uri)
		if subscriptions.isEmpty { lastDigest = nil }
	}

	internal var activeSubscriptions: Set<String> { subscriptions }

	internal func grantsChanged() async {
		// Events recorded under the old grant may name tabs the new one doesn't cover, and the new
		// grant salts addresses differently: start comparing afresh.
		events.removeAll()
		lastDigest = nil
		await notify(.listChanged)
		let grants = await gateway.grants
		if !grants.contains([.read]) {
			subscriptions.removeAll()
			lastDigest = nil
			return
		}
		subscriptions = subscriptions.filter {
			switch Address($0) {
			case .snapshot: grants.contains([.pageContent])
			case .downloads: grants.contains([.downloads])
			default: true
			}
		}
	}

	/// Reports what changed since the last poll to the matching subscriptions.
	internal func poll() async {
		guard !subscriptions.isEmpty else { return }
		guard case let .success(digest) = await gateway.changes() else { return }

		let previous = lastDigest ?? digest
		lastDigest = digest
		if subscriptions.contains(Self.eventsURI) { record(from: previous, to: digest) }
		let notices = Self.notices(from: previous, to: digest, subscriptions: subscriptions)
		for notice in notices {
			if case let .updated(uri) = notice, !subscriptions.contains(uri) { continue }
			await notify(notice)
		}

		// A tab that closed or left the grant can no longer be followed.
		subscriptions = subscriptions.filter { uri in
			guard let id = Address(uri)?.tabID else { return true }
			return digest.tabs[id] != nil
		}
		if subscriptions.isEmpty { lastDigest = nil }
	}

	/// Keeps the newest `AutomationEvent.maximumKept` events and tells the subscriber.
	private func record(
		from previous: AutomationChangeDigest,
		to current: AutomationChangeDigest
	) {
		let new = AutomationEvent.changes(from: previous, to: current, firstSequence: nextEventSequence, time: Date())
		guard !new.isEmpty else { return }

		nextEventSequence += UInt64(new.count)
		events.append(contentsOf: new)
		if events.count > AutomationEvent.maximumKept { events.removeFirst(events.count - AutomationEvent.maximumKept) }
	}

	internal var recordedEvents: [AutomationEvent] { events }

	/// The kept events after `after` that the current grant still covers: a tab's events while
	/// the tab is granted (and its closing, which names only its ID), and download changes while
	/// downloads are.
	internal static func visibleEvents(
		_ events: [AutomationEvent],
		after: UInt64,
		digest: AutomationChangeDigest
	) -> [AutomationEvent] {
		events.filter { event in
			guard event.sequence > after else { return false }
			guard let tab = event.tabID else { return digest.downloads != nil }
			return event.kind == .tabClosed || digest.tabs[tab] != nil
		}
	}

	internal static func notices(
		from previous: AutomationChangeDigest,
		to current: AutomationChangeDigest,
		subscriptions: Set<String>
	) -> [Notice] {
		var notices: [Notice] = []
		if
			subscriptions.contains(eventsURI),
			!AutomationEvent.changes(from: previous, to: current, firstSequence: 1, time: .distantPast).isEmpty
		{
			notices.append(.updated(eventsURI))
		}
		if previous.downloads != current.downloads, subscriptions.contains(downloadsURI) {
			notices.append(.updated(downloadsURI))
		}
		let changed = Set(previous.tabs.keys).union(current.tabs.keys).filter {
			previous.tabs[$0] != current.tabs[$0]
		}
		guard !changed.isEmpty else { return notices }

		if subscriptions.contains(tabsURI) { notices.append(.updated(tabsURI)) }
		for id in changed.sorted(by: { $0.uuidString < $1.uuidString }) {
			for address in [Address.tab(id), .snapshot(id)] where subscriptions.contains(address.uri) {
				notices.append(.updated(address.uri))
			}
		}
		if Set(previous.tabs.keys) != Set(current.tabs.keys) { notices.append(.listChanged) }
		return notices
	}
}
