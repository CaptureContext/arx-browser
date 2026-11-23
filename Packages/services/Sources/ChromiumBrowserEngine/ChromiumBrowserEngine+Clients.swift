import AppKit
import BrowserCaptureClient
import BrowserCore
import BrowserDownloadsClient
import BrowserEngineClient
import BrowserExtensionsClient
import BrowserMediaClient
import BrowserPageInspectionClient
import BrowserPageInteractionClient
import BrowserPageWaitClient
import BrowserSurfaceClient
import BrowserSiteIconClient
import ChromiumEngine

extension ChromiumBrowserEngine {
	// MARK: - Clients

	public var client: BrowserEngineClient {
		let authorizedClose: BrowserEngineClient.AuthorizedClose?
		if enableAuthorizedClosing && runtime.supportsAuthorizedClosing {
			authorizedClose = { [self] id, revision, authorize, didClose in
				try await closeAuthorized(
					id,
					revision: revision,
					authorize: authorize,
					didClose: didClose
				)
			}

		} else {
			authorizedClose = nil
		}

		var client = BrowserEngineClient(
			status: { .ready },
			referenceSubmissionsAreSettled: { [self] id in
				pages[id].map { runtime.referenceSubmissionsAreSettled(on: $0) } ?? false
			},
			snapshot: { [self] id in
				pages[id].map { page in

					// DEV-873: read live, since the page's own report arrives after a posted task.
					// An unloaded page has no document for document-bound reads.
					let isUnloaded = runtime.isUnloaded(page)
					var navigation = snapshot(page.navigation, tab: id)
					navigation.isUnloaded = isUnloaded
					return .init(
						navigation: navigation,
						revision: sessionRevisions[id, default: 0],
						documentRevision: isUnloaded ? nil : runtime.documentRevision(for: page),
						isVisibleForCapture: isVisibleForCapture(id),
						nativePageID: page.identifier,
						nativeProfileID: pageProfiles[id]
					)
				}
			},
			openAuthorized: { [self] tab, authorize in try await open(tab, authorize: authorize) },
			commandAuthorized: { [self] id, revision, command, authorize in
				try await self.command(id, command, expectedRevision: revision, authorize: authorize)
			},
			closeAuthorized: authorizedClose,
			open: { [self] in try await open($0) },
			command: { [self] in try await command($0, $1) },
			permitsClosing: { [self] id in
				guard let page = pages[id] else { return true }

				// DEV-1009: a page that stopped answering never answers beforeunload either.
				if page.navigation.unresponsive != 0, runtime.endRenderer(page) { return true }
				return await runtime.permitsClosing(page)
			},
			close: { [self] in close($0) },
			prepareProfile: { [self] id in
				guard !retiringProfiles.contains(id), !retirementIntents.contains(id)
				else { throw ProfileRetirementFailure.busy }

				let profileKey = id.chromiumProfile(legacy: legacyProfileID)
				try await runtime.prepareProfile(profileKey)
			},
			preparePrivateProfile: { [self] profile, opener in
				guard let opener else { return try runtime.preparePrivateProfile(profile.rawValue) }
				try runtime.preparePrivateProfile(
					profile.rawValue,
					followingDownloadsOf: opener.chromiumProfile(legacy: legacyProfileID)
				)
			},
			releasePrivateProfile: { [self] in requestPrivateProfileRelease($0) },
			events: { [self] in events($0) },
			linkContexts: { [self] in linkContextEvents() },
			linkContextIsCurrent: { [self] in linkContextIsCurrent($0) },
			dismissLinkContext: { [self] in
				guard let page = pages[$0.tabID] else { return }
				runtime.dismissLinkContext(page: page.identifier, token: $0.token)
			},
			inspectLinkContext: { [self] in inspectLinkContext($0) },
			retirementIsAvailable: { [runtime] in runtime.supportsProfileRetirement },
			blockProfileRetirement: { [self] in retirementIntents.insert($0) },
			profileRetirementSnapshot: { [self] in try await retirementSnapshot() },
			retireProfile: { [self] request, authorize in
				try await retireProfile(request, authorize: authorize)
			}
		)
		client.entryChanges = { [self] in entryChanges($0) }
		client.releaseIdleProfiles = { [self] used, gracePeriod in
			releaseIdleProfiles(usedByApp: used, gracePeriod: gracePeriod)
		}
		client.appendLinkExtensionItems = { [self] in appendLinkExtensionItems($0, to: $1) }
		client.darkPagesAreAvailable = { [self] in runtime.supportsDarkPages }
		client.setDarkPages = { [self] in setDarkPages($0) }
		client.startLinkContextDownload = { [self] in startLinkContextDownload($0) }
		client.linkContextDownload = { [self] in try await linkContextDownload($0, request: $1) }
		client.pageDialog = { [self] id in
			pages[id].flatMap { $0.dialog() }.map(Self.dialog)
		}
		client.answerPageDialog = { [self] id, dialog, accept, text, authorize in
			guard
				let page = pages[id],
				let current = page.dialog(),
				String(current.token, radix: 16) == dialog.token
			else { return .stale }
			guard authorize() else { return .denied }
			do throws(ChromiumPageDialogFailure) {
				try page.answerDialog(current, accept: accept, text: text)
				return .answered
			} catch {
				switch error {
				case .stale: return .stale
				case .invalid: return .invalid
				case .unavailable: return .unavailable
				}
			}
		}
		client.setPagePromptsHosted = { [self] hosted in
			guard runtime.supportsHostedPagePrompts else { return false }

			runtime.setPagePromptsHosted(hosted)
			return true
		}
		client.pagePermissionPrompt = { [self] id, token in
			pages[id].flatMap { $0.permissionPrompt(token: token) }.map(Self.permissionPrompt)
		}
		client.answerPagePermissionPrompt = { [self] id, token, decision, accuracy in
			guard
				let page = pages[id],
				let current = page.permissionPrompt(token: token)
			else { return .stale }
			do throws(ChromiumPageDialogFailure) {
				try page.answerPermissionPrompt(
					current,
					decision: Self.decision(decision),
					accuracy: accuracy.map(Self.accuracy)
				)
				return .answered
			} catch {
				switch error {
				case .stale: return .stale
				case .invalid: return .invalid
				case .unavailable: return .unavailable
				}
			}
		}
		client.focusedLink = { [self] id in await focusedLink(id) }
		client.cloneNavigation = { [self] in cloneNavigation(from: $0, to: $1) }
		client.forgetNavigation = { [self] in forgetNavigation($0) }
		client.setSharedHistory = { [self] id, back, forward in
			guard let page = pages[id] else { return }
			runtime.setSharedHistory(page, back: back, forward: forward)
		}
		client.discardNavigation = { [self] in discardNavigation(of: $0, profile: $1) }
		client.formEdits = { [self] id in await formEdits(id) }
		client.savePageIsAvailable = { [runtime] in runtime.supportsPageMenu }
		client.savePage = { [self] id, url, format in
			guard let page = pages[id] else { throw BrowserEngineClient.Failure.missingSession }
			let kind: ChromiumSavePageKind = switch format {
			case .complete: .complete
			case .htmlOnly: .htmlOnly
			case .webArchive: .webArchive
			}
			try runtime.savePage(page, to: url, kind: kind)
		}
		client.documentType = { [self] id in
			guard let page = pages[id] else { return nil }
			return switch runtime.documentType(of: page) {
			case .web: .web
			case .pdf: .pdf
			case nil: nil
			}
		}
		client.externalLinkIsCurrent = { [self] id, token in
			guard let page = pages[id] else { return false }
			return runtime.isExternalLinkCurrent(page, token: token)
		}
		client.tabUnloadingIsAvailable = { [runtime] in runtime.supportsPageUnloading }
		client.unloadTab = { [self] id, reason in unloadTab(id, reason: reason) }
		client.tabHoldsUnsavedInput = { [self] id in tabHoldsUnsavedInput(id) }
		client.endPictureInPicture = { [self] id in
			if let page = pages[id] { runtime.endPictureInPicture(page) }
		}
		client.extensionActionsAreAvailable = { [runtime] in runtime.supportsExtensionActions }
		client.runExtensionAction = { [self] id, extensionID, point throws(BrowserExtensionActionFailure) in
			guard let page = pages[id] else { throw .unavailable }
			do throws(ChromiumExtensionActionFailure) {
				return switch try runtime.runExtensionAction(extensionID, on: page, at: point) {
				case .popup: .popup
				case .clicked: .clicked
				}
			} catch {
				switch error {
				case .unavailable: throw .unavailable
				case .invalid: throw .invalid
				case .refused: throw .refused
				}
			}
		}
		client.extensionActionIcon = { [self] id, extensionID, scale in
			guard let page = pages[id] else { return nil }
			return runtime.extensionActionIcon(extensionID, on: page, scale: scale)
		}
		client.setExtensionPopupWindows = { [runtime] windows in
			runtime.setExtensionPopupWindows(windows.map(Self.extensionPopupWindows))
		}
		client.elementHidingIsAvailable = { [runtime] in runtime.supportsElementHiding }
		client.startElementPicker = { [self] id in
			guard let page = pages[id] else { return false }
			return runtime.startElementPicker(on: page)
		}
		client.hiddenElements = { [self] id in
			guard let page = pages[id] else { return nil }
			return await runtime.hiddenElements(on: page).map { BrowserHiddenElements(sites: $0.sites) }
		}
		client.showHiddenElement = { [self] id, filter in
			guard let page = pages[id] else { return false }
			return runtime.showHiddenElement(filter, on: page)
		}
		client.elementPickerIsAvailable = { [runtime] in runtime.supportsElementPicker }
		client.pickElement = { [self] id, accent in
			guard let page = pages[id] else { return .unavailable }
			let style = ChromiumElementPicker.Style(
				accent: .init(red: accent.red, green: accent.green, blue: accent.blue),
				onAccent: Self.onAccent(accent),
				zoom: runtime.pageZoom(page) ?? 1,
				reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
			)
			return switch await runtime.pickElement(on: page, style: style) {
			case .unavailable: .unavailable
			case .closed: .closed
			case let .hidden(filter): .hidden(filter: filter)
			case let .refused(filter): .refused(filter: filter)
			}
		}
		client.hideElements = { [self] id, accent, cursor in
			AsyncStream { continuation in
				guard let page = pages[id] else {
					continuation.yield(.unavailable)
					continuation.finish()
					return
				}

				let style = ChromiumElementPicker.Style(
					accent: .init(red: accent.red, green: accent.green, blue: accent.blue),
					onAccent: Self.onAccent(accent),
					zoom: runtime.pageZoom(page) ?? 1,
					reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
					keepsOpen: true
				)
				let task = Task { @MainActor [runtime] in
					let opened = await runtime.hideElements(on: page, style: style, cursor: cursor()) { event in
						continuation.yield(Self.hidingEvent(event))
					}
					if !opened { continuation.yield(.unavailable) }
					continuation.finish()
				}
				continuation.onTermination = { _ in task.cancel() }
			}
		}
		client.elementHidingCommand = { [self] id, command in
			guard let page = pages[id] else { return false }
			let engineCommand: ChromiumElementPicker.HidingCommand = switch command {
			case let .unhide(filter): .unhide(filter)
			case let .describe(filters): .describe(filters)
			case let .listOpen(isOpen): .listOpen(isOpen)
			case .close: .close
			}
			return runtime.sendHidingCommand(engineCommand, on: page)
		}
		client.pageZoom = { [self] id in pages[id].flatMap { runtime.pageZoom($0) } }
		client.processTable = { [self] in
			guard runtime.supportsProcesses else { return nil }

			var tabs: [UInt64: Tab.ID] = [:]
			for (tab, page) in pages { tabs[page.identifier] = tab }
			var owners: [Int32: [BrowserProcess.Owner]] = [:]
			for process in runtime.processes() {
				switch process.owner {
				case let .page(page):
					guard let tab = tabs[page] else { continue }
					owners[process.pid, default: []].append(process.isPrivate ? .privateTab(tab) : .tab(tab))

				case let .extensionID(id):
					let owner: BrowserProcess.Owner = .extensionID(id)
					if owners[process.pid]?.contains(owner) != true { owners[process.pid, default: []].append(owner) }
				}
			}
			return BrowserProcessSampler.sample(owners: owners)
		}
		client.endProcess = { [self] pid in runtime.endProcess(pid) }
		client.setPageZoom = { [self] id, factor in pages[id].flatMap { runtime.setPageZoom($0, factor) } }
		client.developerTierIsAvailable = { [self] in runtime.supportsDeveloperTier }
		client.networkDetailsAreAvailable = { [self] in runtime.supportsNetworkCapture }
		client.setNetworkCapture = { [self] id, enabled in
			guard let page = pages[id] else { return !enabled }
			return runtime.setNetworkCapture(page, enabled: enabled)
		}
		client.readNetworkCapture = { [self] id, after, limit, bodyBytes in
			pages[id].flatMap { runtime.readNetworkCapture($0, after: after, limit: limit, bodyBytes: bodyBytes) }
		}
		client.passwordsAreAvailable = { [self] in runtime.supportsPasswords }
		client.savedAccounts = { [self] id throws(BrowserPasswordFailure) in
			guard let page = pages[id] else { throw .stale(filled: false) }
			guard !page.isPrivate, runtime.supportsPasswords else { throw .unavailable }
			do {
				let listed = try await runtime.signInCredentials(page)
				return .init(
					document: listed.document,
					origin: listed.origin,
					accounts: listed.credentials.map { .init(id: $0.id, username: $0.username, hasForm: $0.hasForm) }
				)
			} catch let failure as ChromiumSignInFailure {
				throw Self.passwordFailure(failure)
			} catch {
				throw .unavailable
			}
		}
		client.signInWithPassword = { [self] id, document, frame, account, authorize throws(BrowserPasswordFailure) in
			guard let page = pages[id] else { throw .stale(filled: false) }
			guard !page.isPrivate, runtime.supportsPasswords else { throw .unavailable }
			guard authorize() else { throw .denied }
			do {
				let result = try await runtime.signIn(page, document: document, frame: frame, credential: account)
				let outcome: AutomationPasswordSignInResult.Outcome = switch result.outcome {
				case .signedIn: .signedIn
				case .needsUser: .needsUser
				case .failed: .failed
				}
				return .init(
					outcome: outcome,
					reason: Self.signInReason(result.reason),
					filled: result.filled,
					passwordVisible: result.passwordVisible
				)
			} catch let failure as ChromiumSignInFailure {
				throw Self.passwordFailure(failure)
			} catch {
				throw .unavailable
			}
		}
		client.passwordSaveOffers = { [self] in passwordSaveOffers() }
		client.answerPasswordSave = { [self] id, token, answer in
			guard let page = pages[id] else { return false }
			let native: ChromiumPasswordSaveAnswer = switch answer {
			case .save: .save
			case .never: .never
			case .notNow: .notNow
			}
			return runtime.answerPasswordSave(page, token: token, answer: native)
		}
		client.autofillEvents = { [self] in autofillEvents() }
		client.acceptAutofillSuggestion = { [self] id, session, item in
			guard let page = pages[id], !page.isPrivate else { return false }
			return runtime.acceptAutofillSuggestion(page, session: session, index: item)
		}
		client.selectAutofillSuggestion = { [self] id, session, item in
			guard let page = pages[id] else { return }
			runtime.selectAutofillSuggestion(page, session: session, index: item)
		}
		client.dismissAutofillSuggestions = { [self] id, session in
			guard let page = pages[id] else { return }
			runtime.dismissAutofillSuggestions(page, session: session)
		}
		client.setAutofillAuthentication = { [runtime] mode, passwordReason, cardReason in
			let native: ChromiumAutofillAuthentication = switch mode {
			case .ask: .askDeviceOwner
			case .fillPasswordsWithoutAsking: .fillPasswordsWithoutAsking
			}
			runtime.setAutofillAuthentication(native, passwordReason: passwordReason, cardReason: cardReason)
		}
		client.setAutofillProducts = { [runtime] addresses, cards in
			runtime.setAutofillProducts(addresses: addresses, cards: cards)
		}
		client.autofillDataIsAvailable = { [runtime] in runtime.supportsAutofillData }
		client.autofillListing = { [self] id throws(BrowserAutofillDataFailure) in
			let profile = try await autofillDataProfile(id)
			do throws(ChromiumAutofillDataFailure) {
				return Self.autofillListing(try await runtime.autofillListing(profile: profile))
			} catch {
				throw Self.autofillDataFailure(error)
			}
		}
		client.saveAutofillAddress = { [self] id, address throws(BrowserAutofillDataFailure) in
			let profile = try await autofillDataProfile(id)
			let native = ChromiumAutofillAddress(
				id: address.id.isEmpty ? nil : address.id,
				name: address.name,
				organization: address.organization,
				street: address.street,
				city: address.city,
				state: address.state,
				zip: address.zip,
				country: address.country,
				phone: address.phone,
				email: address.email
			)
			do throws(ChromiumAutofillDataFailure) {
				return Self.autofillListing(try await runtime.saveAutofillAddress(profile: profile, native))
			} catch {
				throw Self.autofillDataFailure(error)
			}
		}
		client.saveAutofillCard = { [self] edit throws(BrowserAutofillDataFailure) in
			let profile = try await autofillDataProfile(edit.profileID)
			let field = edit.numberField.flatMap(BrowserPasswordFields.field)
			guard edit.numberField == nil || field != nil else { throw .invalid }
			do throws(ChromiumAutofillDataFailure) {
				return Self.autofillListing(try await runtime.saveAutofillCard(
					profile: profile,
					.init(id: edit.id, name: edit.name, nickname: edit.nickname, month: edit.month, year: edit.year),
					numberField: field
				))
			} catch {
				throw Self.autofillDataFailure(error)
			}
		}
		client.removeAutofillData = { [self] id, item throws(BrowserAutofillDataFailure) in
			let profile = try await autofillDataProfile(id)
			do throws(ChromiumAutofillDataFailure) {
				return Self.autofillListing(try await runtime.removeAutofillData(profile: profile, id: item))
			} catch {
				throw Self.autofillDataFailure(error)
			}
		}
		client.siteSettingsAreAvailable = { [runtime] in runtime.supportsSiteSettings }
		client.siteSettings = { [self] id throws(SiteSettingsFailure) in
			let profile = try await siteSettingsProfile(id)
			do {
				return Self.siteSettings(try await runtime.siteSettingsList(profile: profile))
			} catch {
				throw Self.siteSettingsFailure(error)
			}
		}
		client.changeSiteSettings = { [self] id, edit throws(SiteSettingsFailure) in
			try edit.validate()
			let profile = try await siteSettingsProfile(id)
			do {
				switch edit {
				case let .setPermission(origin, permission, setting):
					guard let native = ChromiumSitePermission(rawValue: permission.rawValue)
					else { throw SiteSettingsFailure.invalid }

					return Self.siteSettings(try await runtime.setSitePermission(
						profile: profile,
						origin: origin,
						permission: native,
						setting: setting.flatMap { ChromiumSitePermissionSetting(rawValue: $0.rawValue) }
					))

				case let .setZoom(host, factor):
					return Self.siteSettings(try await runtime.setSiteZoom(profile: profile, host: host, factor: factor))

				case let .setContentBlocking(origin, isOn):
					// DEV-884: an Ads ALLOW rule turns blocking off; removing it turns it back on,
					// with any wider rule that still covers the site, such as `[*.]example.com`.
					var settings = Self.siteSettings(try await runtime.setSitePermission(
						profile: profile,
						origin: origin,
						permission: .ads,
						setting: isOn ? nil : .allow
					))
					if isOn {
						for rule in settings.contentBlockingRules(covering: origin) where rule != origin {
							settings = Self.siteSettings(try await runtime.setSitePermission(
								profile: profile,
								origin: rule,
								permission: .ads,
								setting: nil
							))
						}
					}
					return settings
				}
			} catch {
				throw Self.siteSettingsFailure(error)
			}
		}
		client.siteSettingsChanges = { [self] in siteSettingsChanges() }
		client.profileDataIsAvailable = { [runtime] in runtime.supportsProfileData }
		client.countBrowsingData = { [self] id, kinds, since throws(ProfileDataFailure) in
			let profile = try await profileDataProfile(id)
			do {
				return Self.browsingDataCounts(try await runtime.countBrowsingData(
					profile: profile,
					kinds: Self.chromiumKinds(kinds),
					since: since
				))
			} catch {
				throw Self.profileDataFailure(error)
			}
		}
		client.clearBrowsingData = { [self] id, kinds, since throws(ProfileDataFailure) in
			let profile = try await profileDataProfile(id)
			do {
				let failed = try await runtime.clearBrowsingData(
					profile: profile,
					kinds: Self.chromiumKinds(kinds),
					since: since
				)
				return Set(failed.compactMap { BrowsingDataKind(rawValue: $0.rawValue) })
			} catch {
				throw Self.profileDataFailure(error)
			}
		}
		client.siteDataIsAvailable = { [runtime] in runtime.supportsSiteData }
		client.siteDataScope = { [self] id, url throws(ProfileDataFailure) in
			let profile = try await profileDataProfile(id)
			do {
				return try await runtime.siteDataScope(profile: profile, url: url)
			} catch {
				throw Self.profileDataFailure(error)
			}
		}
		client.clearSiteData = { [self] id, url, kinds throws(ProfileDataFailure) in
			let profile = try await profileDataProfile(id)
			do {
				let cleared = try await runtime.clearSiteData(
					profile: profile,
					url: url,
					kinds: Self.chromiumKinds(kinds)
				)
				return Set(cleared.failed.compactMap { BrowsingDataKind(rawValue: $0.rawValue) })
			} catch {
				throw Self.profileDataFailure(error)
			}
		}
		client.downloadSettings = { [self] id throws(ProfileDataFailure) in
			let profile = try await profileDataProfile(id)
			do {
				return Self.downloadSettings(try await runtime.downloadSettings(profile: profile))
			} catch {
				throw Self.profileDataFailure(error)
			}
		}
		client.changeDownloadSettings = { [self] id, directory, ask throws(ProfileDataFailure) in
			let profile = try await profileDataProfile(id)
			do {
				return Self.downloadSettings(try await runtime.setDownloadSettings(
					profile: profile,
					directory: directory?.path(percentEncoded: false),
					ask: ask
				))
			} catch {
				throw Self.profileDataFailure(error)
			}
		}
		client.savedPasswordsAreAvailable = { [runtime] in runtime.supportsSavedPasswords }
		client.savedPasswords = { [self] id throws(BrowserSavedPasswordFailure) in
			let profile = try await savedPasswordProfile(id)
			do {
				return Self.savedPasswordList(try await runtime.savedPasswordList(profile: profile))
			} catch {
				throw Self.savedPasswordFailure(error)
			}
		}
		client.savePassword = { [self] edit throws(BrowserSavedPasswordFailure) in
			let profile = try await savedPasswordProfile(edit.profileID)
			let field = edit.passwordField.flatMap(BrowserPasswordFields.field)
			guard edit.passwordField == nil || field != nil else { throw .stale }
			let listing: String?
			let credential: UInt32
			let url: String?
			switch edit.target {
			case let .new(address):
				listing = nil
				credential = 0
				url = address
			case let .existing(token, id):
				listing = token
				credential = id
				url = nil
			}
			do {
				return Self.savedPasswordList(try await runtime.savePassword(
					profile: profile,
					listing: listing,
					credential: credential,
					url: url,
					username: edit.username,
					passwordField: field
				))
			} catch {
				throw Self.savedPasswordFailure(error)
			}
		}
		client.removeSavedPassword = { [self] id, listing, credential throws(BrowserSavedPasswordFailure) in
			let profile = try await savedPasswordProfile(id)
			do {
				return Self.savedPasswordList(try await runtime.removeSavedPassword(
					profile: profile,
					listing: listing,
					credential: credential
				))
			} catch {
				throw Self.savedPasswordFailure(error)
			}
		}
		client.revealSavedPassword = { [self] id, listing, credential, reason, reveal throws(BrowserSavedPasswordFailure) in
			let profile = try await savedPasswordProfile(id)
			let mode: ChromiumPasswordReveal
			switch reveal {
			case .copy:
				mode = .copy
			case let .show(fieldID):
				guard let field = BrowserPasswordFields.field(fieldID) else { throw .stale }
				mode = .show(field)
			}
			do {
				try await runtime.revealSavedPassword(
					profile: profile,
					listing: listing,
					credential: credential,
					reason: reason,
					mode: mode
				)
			} catch {
				throw Self.savedPasswordFailure(error)
			}
		}
		client.importPasswords = { [self] id, file throws(BrowserSavedPasswordFailure) in
			let profile = try await savedPasswordProfile(id)
			do {
				let summary = try await runtime.importPasswords(profile: profile, file: file)
				return .init(
					imported: summary.imported,
					conflicts: summary.conflicts.map(Self.importRow),
					conflictCount: summary.conflictCount,
					skipped: summary.skipped.map(Self.importRow),
					skippedCount: summary.skippedCount
				)
			} catch {
				throw Self.savedPasswordFailure(error)
			}
		}
		client.credentialImportIsAvailable = { [runtime] in runtime.supportsCredentialImport }
		client.importPasswordRecords = { [self] id, records throws(BrowserCredentialImportFailure) in
			typealias Adapter = ChromiumCredentialImportAdapter
			let profile = try await credentialImportProfile(id)
			let result: Adapter.Chunked<BrowserImportedPassword, ChromiumPasswordRecordImport>
			do {
				result = try await Adapter.inChunks(records, of: Adapter.passwordChunk) { chunk in
					try await runtime.importPasswordRecords(profile: profile, records: chunk.map(Adapter.password))
				} rollback: { summary in
					await Adapter.rollBack {
						try await undoCredentials(profile, passwords: summary.imported + summary.unconfirmed, cookies: [])
					}
				}
			} catch {
				throw Adapter.failure(error)
			}
			let summaries = result.parts
			return .init(
				imported: summaries.flatMap(\.imported).map(Adapter.passwordKey),
				unconfirmed: summaries.flatMap(\.unconfirmed).map(Adapter.passwordKey),
				conflicts: summaries.reduce(0) { $0 + $1.conflicts },
				// Rows of chunks that failed or were rolled back aren't stored.
				skipped: summaries.reduce(0) { $0 + $1.skipped } + result.omitted.count
			)
		}
		client.importCookies = { [self] id, cookies throws(BrowserCredentialImportFailure) in
			typealias Adapter = ChromiumCredentialImportAdapter
			let profile = try await credentialImportProfile(id)
			let result: Adapter.Chunked<BrowserImportedCookie, ChromiumCookieImport>
			do {
				result = try await Adapter.inChunks(cookies, of: Adapter.cookieChunk) { chunk in
					try await runtime.importCookies(profile: profile, cookies: chunk.map(Adapter.cookie))
				} rollback: { write in
					await Adapter.rollBack {
						try await undoCredentials(profile, passwords: [], cookies: write.accepted + write.unconfirmed)
					}
				}
			} catch {
				throw Adapter.failure(error)
			}
			let writes = result.parts
			return .init(
				accepted: writes.flatMap(\.accepted).map(Adapter.cookieKey),
				existing: writes.flatMap(\.existing).map(Adapter.cookieKey),
				// Cookies of chunks that failed or were rolled back aren't set.
				rejected: writes.flatMap(\.rejected).map(Adapter.cookieKey) + result.omitted.map(Adapter.cookieKey),
				unconfirmed: writes.flatMap(\.unconfirmed).map(Adapter.cookieKey)
			)
		}
		client.checkCookies = { [self] id, keys throws(BrowserCredentialImportFailure) in
			typealias Adapter = ChromiumCredentialImportAdapter
			let profile = try await credentialImportProfile(id)
			var present: Set<BrowserCookieKey> = []
			do {
				for batch in Adapter.keyBatches(keys.map(Adapter.cookieKey), count: Adapter.cookieChunk) {
					let found = try await runtime.checkCookies(profile: profile, keys: batch)
					present.formUnion(found.map(Adapter.cookieKey))
				}
			} catch {
				throw Adapter.failure(error)
			}
			return present
		}
		client.undoCredentialImport = { [self] id, passwords, cookies throws(BrowserCredentialImportFailure) in
			typealias Adapter = ChromiumCredentialImportAdapter
			let profile = try await credentialImportProfile(id)
			do {
				return try await undoCredentials(
					profile,
					passwords: passwords.map(Adapter.passwordKey),
					cookies: cookies.map(Adapter.cookieKey)
				)
			} catch {
				throw Adapter.failure(error)
			}
		}

		// DEV-1009.
		client.waitForPage = { [self] id in pages[id].map { runtime.waitForPage($0) } ?? false }
		client.endRenderer = { [self] id in pages[id].map { endRenderer(id, $0) } ?? false }
		client.pingPage = { [self] id, timeout in
			guard let page = pages[id] else { return nil }
			return await runtime.pingPage(page, timeoutMilliseconds: timeout)
		}
		client.evaluateScript = { [self] id, script, maximumBytes, timeout, authorize throws(BrowserDeveloperFailure) in
			guard let page = pages[id] else { throw .stale }
			guard !page.isPrivate, runtime.supportsDeveloperTier else { throw .unavailable }
			guard authorize() else { throw .denied }
			do {
				let value = try await runtime.evaluateScript(
					page,
					source: script,
					maximumBytes: maximumBytes,
					timeoutMilliseconds: timeout
				)
				return switch value {
				case let .json(text): .value(text)
				case .undefined: .undefined
				case let .unserializable(detail): .unserializable(detail)
				}
			} catch let failure as ChromiumDeveloperFailure {
				switch failure {
				case let .exception(error): return .exception(name: error.name, message: error.message)
				case let .syntax(error): return .syntaxError(name: error.name, message: error.message, line: error.line)
				default: throw Self.developerFailure(failure)
				}
			} catch {
				throw .failed
			}
		}
		client.evaluateTranslationScript = { [self] id, script, maximumBytes, timeout throws(BrowserDeveloperFailure) in
			guard let page = pages[id] else { throw .stale }
			guard runtime.supportsTranslationScripts else { throw .unavailable }
			do {
				let value = try await runtime.evaluateTranslationScript(
					page,
					source: script,
					maximumBytes: maximumBytes,
					timeoutMilliseconds: timeout
				)
				return switch value {
				case let .json(text): .value(text)
				case .undefined: .undefined
				case let .unserializable(detail): .unserializable(detail)
				}
			} catch let failure as ChromiumDeveloperFailure {
				switch failure {
				case let .exception(error): return .exception(name: error.name, message: error.message)
				case let .syntax(error): return .syntaxError(name: error.name, message: error.message, line: error.line)
				default: throw Self.developerFailure(failure)
				}
			} catch {
				throw .failed
			}
		}
		client.setDeveloperLog = { [self] id, enabled in
			guard let page = pages[id] else { return !enabled }
			return runtime.setDeveloperLog(page, enabled: enabled)
		}
		client.readDeveloperLog = { [self] id, kind, after, limit throws(BrowserDeveloperFailure) in
			guard let page = pages[id] else { throw .stale }
			guard !page.isPrivate, runtime.supportsDeveloperTier else { throw .unavailable }
			do {
				let log = try await runtime.developerLog(
					page,
					kind: kind == .console ? .console : .network,
					after: after,
					limit: limit
				)
				return try Self.developerLog(log, kind: kind)
			} catch let failure as ChromiumDeveloperFailure {
				throw Self.developerFailure(failure)
			} catch let failure as BrowserDeveloperFailure {
				throw failure
			} catch {
				throw .failed
			}
		}
		return client
	}

	/// Prepares an ordinary, non-retiring profile for Settings and returns its
	/// engine key (nil for the configured default).
	/// Undoes in batches native takes, by count and by encoded size, so a batch
	/// with long cookie names or paths can always be undone. Undo is idempotent,
	/// so a retry after a failed batch is safe.
	private func undoCredentials(
		_ profile: UUID?,
		passwords: [ChromiumPasswordKey],
		cookies: [ChromiumCookieKey]
	) async throws(ChromiumCredentialImportFailure) -> Int {
		typealias Adapter = ChromiumCredentialImportAdapter
		var removed = 0
		for batch in Adapter.keyBatches(passwords, count: Adapter.passwordChunk) {
			removed += try await runtime.undoCredentialImport(profile: profile, passwords: batch, cookies: [])
		}
		for batch in Adapter.keyBatches(cookies, count: Adapter.cookieChunk) {
			removed += try await runtime.undoCredentialImport(profile: profile, passwords: [], cookies: batch)
		}
		return removed
	}

	/// Prepares an ordinary, non-retiring profile for the migration assistant's
	/// credential import (ABI46) and returns its engine key (nil for the default).
	private func credentialImportProfile(_ id: Profile.ID) async throws(BrowserCredentialImportFailure) -> UUID? {
		guard
			runtime.supportsCredentialImport,
			!retiringProfiles.contains(id),
			!retirementIntents.contains(id)
		else { throw .unavailable }

		let profile = id.chromiumProfile(legacy: legacyProfileID)
		do {
			try await runtime.prepareProfile(profile)
		} catch {
			throw .unavailable
		}
		return profile
	}

	private func autofillDataProfile(_ id: Profile.ID) async throws(BrowserAutofillDataFailure) -> UUID? {
		guard
			runtime.supportsAutofillData,
			!retiringProfiles.contains(id),
			!retirementIntents.contains(id)
		else { throw .unavailable }

		let profile = id.chromiumProfile(legacy: legacyProfileID)
		do {
			try await runtime.prepareProfile(profile)
		} catch {
			throw .unavailable
		}
		return profile
	}

	/// The app's popup windows, as the engine takes them (DEV-1316).
	internal static func extensionPopupWindows(
		_ windows: BrowserExtensionPopupWindows
	) -> ChromiumExtensionPopupWindows {
		let closing: ChromiumExtensionPopupClosing = switch windows.closing {
		case .unlessMoved: .unlessMoved
		case .onFocusLoss: .onFocusLoss
		case .staysOpen: .staysOpen
		}
		return .init(closing: closing, makeWindow: windows.makeWindow, resizeWindow: windows.resizeWindow)
	}

	internal static func autofillListing(_ native: ChromiumAutofillListing) -> BrowserAutofillListing {
		.init(
			addresses: native.addresses.map { address in
				.init(
					id: address.id ?? "",
					name: address.name,
					organization: address.organization,
					street: address.street,
					city: address.city,
					state: address.state,
					zip: address.zip,
					country: address.country,
					phone: address.phone,
					email: address.email
				)
			},
			cards: native.cards.map { card in
				.init(
					id: card.id,
					name: card.name,
					network: card.network,
					lastFour: card.lastFour,
					month: card.month,
					year: card.year,
					nickname: card.nickname
				)
			}
		)
	}

	private static func autofillDataFailure(_ failure: ChromiumAutofillDataFailure) -> BrowserAutofillDataFailure {
		switch failure {
		case .unavailable: .unavailable
		case .invalid: .invalid
		case .notFound: .notFound
		case .busy: .busy
		case .disabled: .disabled
		}
	}

	private func savedPasswordProfile(_ id: Profile.ID) async throws(BrowserSavedPasswordFailure) -> UUID? {
		guard
			runtime.supportsSavedPasswords,
			!retiringProfiles.contains(id),
			!retirementIntents.contains(id)
		else { throw .unavailable }

		let profile = id.chromiumProfile(legacy: legacyProfileID)
		do {
			try await runtime.prepareProfile(profile)
		} catch {
			throw .unavailable
		}
		return profile
	}

	/// Prepares an ordinary, non-retiring profile for Settings' site settings and
	/// returns its engine key (nil for the configured default).
	private func siteSettingsProfile(_ id: Profile.ID) async throws(SiteSettingsFailure) -> UUID? {
		guard
			runtime.supportsSiteSettings,
			!retiringProfiles.contains(id),
			!retirementIntents.contains(id)
		else { throw .unavailable }

		let profile = id.chromiumProfile(legacy: legacyProfileID)
		do {
			try await runtime.prepareProfile(profile)
		} catch {
			throw .unavailable
		}
		return profile
	}

	/// Prepares an ordinary, non-retiring profile for Clear Browsing Data and its
	/// downloads folder, and returns its engine key (nil for the configured default).
	private func profileDataProfile(_ id: Profile.ID) async throws(ProfileDataFailure) -> UUID? {
		guard
			runtime.supportsProfileData,
			!retiringProfiles.contains(id),
			!retirementIntents.contains(id)
		else { throw .unavailable }

		let profile = id.chromiumProfile(legacy: legacyProfileID)
		do {
			try await runtime.prepareProfile(profile)
		} catch {
			throw .unavailable
		}
		return profile
	}

	internal static func chromiumKinds(_ kinds: Set<BrowsingDataKind>) -> Set<ChromiumBrowsingDataKind> {
		Set(kinds.compactMap { ChromiumBrowsingDataKind(rawValue: $0.rawValue) })
	}

	internal static func browsingDataCounts(_ counts: ChromiumBrowsingDataCounts) -> BrowsingDataCounts {
		.init(
			cookieSites: counts.cookies?.sites,
			cacheBytes: counts.cache.map { Int64(clamping: Int(exactly: $0.bytes.rounded()) ?? 0) },
			cacheIsUpperBound: counts.cache?.upperLimit ?? false,
			autofill: counts.autofill.map { .init(entries: $0.entries, addresses: $0.addresses, cards: $0.cards) },
			siteSettingsSites: counts.siteSettings?.sites
		)
	}

	internal static func downloadSettings(_ settings: ChromiumDownloadSettings) -> DownloadSettings {
		.init(
			directory: URL(filePath: settings.directory, directoryHint: .isDirectory),
			asksWhereToSave: settings.ask,
			defaultDirectory: URL(filePath: settings.defaultDirectory, directoryHint: .isDirectory),
			isManaged: settings.managed
		)
	}

	internal static func profileDataFailure(_ error: any Error) -> ProfileDataFailure {
		if let failure = error as? ProfileDataFailure { return failure }
		guard let failure = error as? ChromiumProfileDataFailure
		else { return .failed }

		return switch failure {
		case .unavailable: .unavailable
		case .invalid: .invalid
		case .busy: .busy
		case .managed: .managed
		case .failed: .failed
		}
	}

	private func siteSettingsChanges() -> AsyncStream<Profile.ID> {
		let changes = runtime.siteSettingsChanges()
		return .init(bufferingPolicy: .bufferingNewest(64)) { continuation in
			let task = Task { [legacyProfileID] in
				for await profile in changes {
					continuation.yield(Profile.ID.chromium(profile, legacy: legacyProfileID))
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Unknown names from a newer engine are left out rather than guessed.
	internal static func siteSettings(_ listing: ChromiumSiteSettings) -> SiteSettings {
		.init(
			defaults: SitePermission.allCases.compactMap { permission in
				guard
					let name = listing.permissions.defaults[permission.rawValue],
					let setting = SitePermissionSetting(rawValue: name)
				else { return nil }

				return .init(
					permission: permission,
					setting: setting,
					isManaged: listing.permissions.managedDefaults.contains(permission.rawValue)
				)
			},
			exceptions: listing.permissions.sites.compactMap { site in
				guard
					let permission = SitePermission(rawValue: site.permission),
					let setting = SitePermissionSetting(rawValue: site.setting)
				else { return nil }

				return .init(origin: site.origin, permission: permission, setting: setting, isManaged: site.managed)
			},
			defaultZoom: listing.zoom.default,
			zoom: listing.zoom.sites.map { .init(host: $0.host, factor: $0.factor) },
			isTruncated: listing.truncated,
			// DEV-884: engines that know the Ads setting list its default.
			contentBlockingIsAvailable: listing.permissions.defaults[ChromiumSitePermission.ads.rawValue] != nil,
			// Only rules the engine applies as listed, so the site menu shows what uBlock does.
			contentBlockingOff: Self.contentBlockingOff(
				listing.permissions.sites,
				defaultIsManaged: listing.permissions.managedDefaults.contains(ChromiumSitePermission.ads.rawValue)
			),
			contentBlockingManaged: listing.permissions.sites.compactMap { site in
				site.permission == ChromiumSitePermission.ads.rawValue && site.setting == "block" && site.managed
				? site.origin : nil
			},
			// The same rules uBlock gets (wildcard carve-outs included), the managed ones.
			contentBlockingManagedOff: Self.contentBlockingOff(listing.permissions.sites).filter { origin in
				listing.permissions.sites.contains {
					$0.permission == ChromiumSitePermission.ads.rawValue && $0.setting == "allow"
					&& $0.managed && $0.origin == origin
				}
			},
			contentBlockingDefaultIsManaged: listing.permissions.managedDefaults.contains(ChromiumSitePermission.ads.rawValue)
		)
	}

	/// DEV-884. The Ads ALLOW rules content_blocking_bridge hands uBlock: exact origins, and
	/// `[*.]host` rules with no BLOCK on that host or inside it, which a hostname directive
	/// couldn't leave out.
	/// Under a managed Ads default only managed site rules still count, as in Chromium.
	internal static func contentBlockingOff(
		_ sites: [ChromiumSiteSettings.Site],
		defaultIsManaged: Bool = false
	) -> [String] {
		let ads = sites.filter {
			$0.permission == ChromiumSitePermission.ads.rawValue && (!defaultIsManaged || $0.managed)
		}
		let blocked = ads.filter { $0.setting == "block" }.compactMap { contentBlockingHost($0.origin) }
		return ads.compactMap { site in
			guard
				site.setting == "allow",
				SiteSettings.isContentBlockingRule(site.origin)
			else { return nil }
			guard site.origin.hasPrefix("[*.]") else { return site.origin }

			let host = String(site.origin.dropFirst(4))
			return blocked.contains { $0 == host || $0.hasSuffix("." + host) } ? nil : site.origin
		}
	}

	/// The host of a listed origin or pattern: `https://a.example:8443` and `[*.]a.example` give
	/// `a.example`.
	private static func contentBlockingHost(_ origin: String) -> String? {
		var rest = Substring(origin.lowercased())
		if let range = rest.range(of: "://") { rest = rest[range.upperBound...] }
		if rest.hasPrefix("[*.]") { rest = rest.dropFirst(4) }
		if let slash = rest.firstIndex(of: "/") { rest = rest[..<slash] }
		if !rest.hasPrefix("["), let colon = rest.lastIndex(of: ":") { rest = rest[..<colon] }
		return rest.isEmpty ? nil : String(rest)
	}

	internal static func siteSettingsFailure(_ error: any Error) -> SiteSettingsFailure {
		if let failure = error as? SiteSettingsFailure { return failure }
		guard let failure = error as? ChromiumSiteSettingsFailure
		else { return .failed }

		return switch failure {
		case .unavailable: .unavailable
		case .invalid: .invalid
		case .managed: .managed
		case .failed: .failed
		}
	}

	internal static func savedPasswordList(_ list: ChromiumSavedPasswordList) -> BrowserSavedPasswordList {
		.init(
			listing: list.listing,
			passwords: list.passwords.map {
				.init(id: $0.id, site: $0.site, origin: $0.origin, username: $0.username)
			},
			neverSaved: list.blocked.map { .init(id: $0.id, site: $0.site, origin: $0.origin) }
		)
	}

	internal static func importRow(_ row: ChromiumPasswordImport.Row) -> BrowserPasswordImportSummary.Row {
		.init(
			site: row.site,
			username: row.username,
			reason: row.reason.map { BrowserPasswordImportSummary.Row.Reason(rawValue: $0) ?? .unknown }
		)
	}

	internal static func savedPasswordFailure(_ error: any Error) -> BrowserSavedPasswordFailure {
		guard let failure = error as? ChromiumSavedPasswordFailure
		else { return .failed }

		return switch failure {
		case .unavailable: .unavailable
		case .invalid(reason: "format"): .badFormat
		case .invalid(reason: "tooLarge"): .fileTooLarge
		case .invalid(reason: "tooMany"): .tooManyPasswords
		case .invalid: .invalid
		case .stale: .stale
		case .notFound: .notFound
		case .exists: .exists
		case .denied: .denied
		case .busy: .busy
		case .failed(reason: "io"): .unreadableFile
		case .failed: .failed
		}
	}

	private static func passwordFailure(_ failure: ChromiumSignInFailure) -> BrowserPasswordFailure {
		switch failure {
		case .unavailable: .unavailable
		case let .staleDocument(filled): .stale(filled: filled)
		case .busy: .busy
		case .invalidRequest: .invalid
		case let .timedOut(filled): .timedOut(filled: filled)
		}
	}

	/// Native's fixed reasons; anything else is reported as unsupported.
	private static func signInReason(_ reason: String) -> AutomationPasswordSignInResult.Reason {
		switch reason {
		case "signedIn": .signedIn
		case "twoFactor": .twoFactor
		case "reauthentication": .reauthentication
		case "rejected": .rejected
		case "noForm": .noForm
		case "credential": .noSavedPassword
		case "frame": .frame
		case "navigation": .navigation
		case "submit": .submit
		case "timeout": .timedOut
		default: .unsupported
		}
	}

	/// Save offers for this engine's ordinary tabs, by tab.
	private func passwordSaveOffers() -> AsyncStream<BrowserPasswordSaveOffer> {
		let offers = runtime.passwordSaveOffers()
		return .init { continuation in
			let task = Task { @MainActor [weak self] in
				for await offer in offers {
					guard let self else { break }

					// The runtime is shared: another profile's engine owns its own tabs' offers.
					guard let tab = tabID(ofPage: offer.page), pages[tab]?.isPrivate == false
					else { continue }
					continuation.yield(.init(
						tabID: tab,
						token: offer.token,
						origin: offer.origin,
						username: offer.username,
						isUpdate: offer.isUpdate
					))
				}
				continuation.finish()
			}
			continuation.onTermination = { _ in task.cancel() }
		}
	}

	/// Text on the element picker's accent chip (DEV-1201): white or near black, whichever reads
	/// better, as Arx's own text on an accent fill does.
	/// Hide Element's mode's events as the client tells them (DEV-1298).
	private static func hidingEvent(_ event: ChromiumElementPicker.HidingEvent) -> BrowserElementHidingEvent {
		func element(_ description: ChromiumElementPicker.Description) -> BrowserHiddenElementDescription {
			.init(label: description.label, kind: .init(script: description.kind))
		}
		return switch event {
		case .opened: .opened
		case let .hidden(filter, description): .hidden(filter: filter, element: element(description))
		case let .refused(filter): .refused(filter: filter)
		case let .target(box): .target(box)
		case let .described(found): .described(found.mapValues { $0.map(element) })
		case let .shown(filter, isVisible): .shown(filter: filter, isVisible: isVisible)
		case let .key(key):
			switch key {
			case .escape: .key(.escape)
			case .return: .key(.return)
			case .undo: .key(.undo)
			case .up: .key(.up)
			case .down: .key(.down)
			case .delete: .key(.delete)
			}
		}
	}

	private static func onAccent(_ accent: ChromePalette.RGB) -> ChromiumElementPicker.Style.Color {
		let white = ChromePalette.RGB(red: 1, green: 1, blue: 1)
		let dark = ChromePalette.RGB(red: 0.08, green: 0.08, blue: 0.1)
		let text = accent.contrast(with: white) >= accent.contrast(with: dark) ? white : dark
		return .init(red: text.red, green: text.green, blue: text.blue)
	}

	private static func developerFailure(_ failure: ChromiumDeveloperFailure) -> BrowserDeveloperFailure {
		switch failure {
		case .unavailable: .unavailable
		case .unsupportedDocument: .unsupported
		case .staleDocument: .stale
		case .limitExceeded: .limitExceeded
		case .busy: .busy
		case .timedOut: .timedOut
		case .invalidRequest: .invalid
		case .failed, .exception, .syntax: .failed
		}
	}

	/// Native entries become typed console or network entries; any that don't fit fail the read.
	private static func developerLog(
		_ log: ChromiumDeveloperLog,
		kind: BrowserDeveloperLogKind
	) throws(BrowserDeveloperFailure) -> BrowserDeveloperLog {
		var result = BrowserDeveloperLog(capturing: log.capturing, next: log.next, dropped: log.dropped)
		for entry in log.entries {
			switch kind {
			case .console:
				guard
					let level = entry.level.flatMap(AutomationConsoleEntry.Level.init(rawValue:)),
					let message = entry.message
				else { throw .failed }

				result.console.append(.init(
					sequence: entry.sequence,
					level: level,
					message: message,
					source: entry.source,
					line: entry.line,
					mainFrame: entry.mainFrame,
					time: entry.time
				))

			case .network:
				guard
					let method = entry.method,
					let url = entry.url,
					let type = entry.type
				else { throw .failed }

				result.network.append(.init(
					sequence: entry.sequence,
					method: method,
					url: url,
					status: entry.status,
					type: type,
					mimeType: entry.mimeType,
					cached: entry.cached,
					bytes: entry.bytes,
					error: entry.error,
					mainFrame: entry.mainFrame,
					time: entry.time
				))
			}
		}
		return result
	}

	private static func permissionPrompt(_ prompt: ChromiumPagePermissionPrompt) -> BrowserPagePermissionPrompt {
		.init(
			token: prompt.token,
			variant: prompt.variant == .previouslyDenied ? .previouslyDenied : .ask,
			requestingOrigin: prompt.requestingOrigin,
			embeddingOrigin: prompt.embeddingOrigin,
			permissions: prompt.permissions,
			fragments: prompt.fragments,
			allowOnce: prompt.allowOnce,
			location: prompt.geolocation.map { geolocation in
				let choice: BrowserPagePermissionPrompt.LocationChoice = switch geolocation.prompt {
				case .default: .either
				case .approximateOnly: .approximateOnly
				case .upgradeToPrecise: .upgradeToPrecise
				}
				return .init(choice: choice, initial: geolocation.initial == .precise ? .precise : .approximate)
			},
			quiet: prompt.quiet
		)
	}

	private static func decision(_ decision: BrowserPagePermissionDecision) -> ChromiumPagePermissionDecision {
		switch decision {
		case .allow: .allow
		case .allowOnce: .allowOnce
		case .block: .block
		case .dismiss: .dismiss
		}
	}

	private static func accuracy(_ accuracy: BrowserPagePermissionPrompt.Accuracy) -> ChromiumPagePermissionAccuracy {
		switch accuracy {
		case .approximate: .approximate
		case .precise: .precise
		}
	}

	private static func dialog(_ dialog: ChromiumPageDialog) -> BrowserPageDialog {
		let kind: BrowserPageDialog.Kind = switch dialog.kind {
		case .alert: .alert
		case .confirm: .confirm
		case .prompt: .prompt
		case .beforeUnload: .beforeUnload
		case .permission: .permission
		}
		return .init(
			token: String(dialog.token, radix: 16),
			kind: kind,
			message: dialog.message,
			defaultPrompt: dialog.kind == .prompt ? dialog.defaultPrompt : nil,
			origin: dialog.kind == .permission ? dialog.origin : nil
		)
	}


	/// Retained for the application's lifetime, independently of utility panels and browser windows.
	public func downloads(
		metadataFile: URL,
		organization: BrowserOrganization = .init()
	) -> BrowserDownloadsClient {
		if let downloadsService { return downloadsService.client }

		let service = ChromiumDownloads(
			runtime: runtime,
			legacyProfileID: legacyProfileID,
			file: metadataFile,
			organization: organization,
			sourceTab: { [weak self] page in self?.downloadSourceTabs[page] },
			tabDownloadChanged: { [weak self] download in self?.tabDownloadChanged(download) }
		)

		downloadsService = service
		return service.client
	}

	/// The transfer a tab's navigation became, while it has no page of its own (DEV-1116).
	internal func pageDownload(
		_ value: ChromiumPage.Navigation,
		tab: Tab.ID
	) -> BrowserNavigation.Download? {
		guard let download = pageDownloads[tab]?.download else { return nil }
		guard let page = pages[tab], hasNoPage(page, value) else {
			pageDownloads[tab] = nil
			return nil
		}

		return download
	}

	/// Whether the tab has no page of its own. A page this engine opened still at the
	/// `about:blank` it starts at has none: that document is the engine's, not the tab's. Else
	/// the engine says so itself (ABI48's document type is none while the last committed entry
	/// is Chromium's initial one), so a current history entry carrying the address a
	/// navigation became a download from doesn't make it a page. An engine without that answer
	/// falls back to the history.
	internal func hasNoPage(
		_ page: ChromiumPage,
		_ navigation: ChromiumPage.Navigation
	) -> Bool {
		if blankStartPages.contains(page.identifier), Self.isStillAtItsStart(navigation.history.map(\.url)) {
			return true
		}
		let current = navigation.history.first(where: \.isCurrent)?.url
		guard runtime.supportsDocumentTypes else { return Self.hasNoPage(current: current) }
		return Self.hasNoPage(committed: runtime.documentType(of: page) != nil, current: current)
	}

	/// A new tab, or one whose navigation became a download: nothing committed, so nothing to
	/// keep showing, whatever address its current entry has. An `about:blank` document counts
	/// as a page, since a site can write one, as a popup it fills in; Chromium keeps that
	/// document on the initial entry, so it isn't committed either (DEV-1116).
	nonisolated internal static func hasNoPage(
		committed: Bool,
		current: URL?
	) -> Bool {
		!committed && current?.absoluteString != "about:blank"
	}

	/// A page that has committed only the `about:blank` it was created at: `makePage` creates
	/// every fresh page there, and Chromium commits it as an ordinary entry, so a tab whose only
	/// navigation became a download keeps just that one (DEV-1116).
	nonisolated internal static func isStillAtItsStart(_ history: [URL]) -> Bool {
		history.count == 1 && history[0].absoluteString == "about:blank"
	}

	/// Without the engine's answer: a new tab's first entry has no address, so it isn't in
	/// `history`. The address alone can't tell: Chromium keeps an aborted address visible in
	/// an untouched blank tab, and a pending one shows before it commits.
	nonisolated internal static func hasNoPage(current: URL?) -> Bool {
		current == nil
	}

	/// A transfer a tab's page started changed (DEV-1116). A tab showing a page keeps it, as
	/// Chrome and Safari do; one with nothing to show shows the newest transfer instead.
	private func tabDownloadChanged(_ download: BrowserDownload) {
		guard
			let id = download.sourceTabID,
			let page = pages[id],
			hasNoPage(page, page.navigation)
		else { return }

		let value = BrowserNavigation.Download(id: download.id, filename: download.filename)
		if let current = pageDownloads[id] {
			guard current.download != value else { return }

			// An older transfer's progress never takes the place of a newer one.
			guard current.download.id == download.id || download.startedAt >= current.startedAt
			else { return }
		}

		pageDownloads[id] = (value, download.startedAt)
		sessionRevisions[id, default: 0] &+= 1
		let snapshot = self.snapshot(page.navigation, tab: id)
		for observer in observers[id, default: [:]].values {
			observer.yield(snapshot)
		}
	}

	/// Stable before runtime startup; queries and observation activate only once ready.
	/// With a `storeDirectory`, icons persist per profile there and stand in for pages that
	/// aren't loaded (DEV-809).
	public func siteIcons(
		organization: BrowserOrganization,
		storeDirectory: URL? = nil
	) -> BrowserSiteIconClient {
		if let siteIconService { return siteIconService.client }
		let stored = storeDirectory.map { BrowserSiteIconStore(directory: $0) }
		stored?.retain(
			Self.siteIconKeys(organization),
			in: Set(organization.profiles.map(\.id))
		)
		let service = ChromiumSiteIconService(
			profiles: Set(organization.profiles.map(\.id)),
			isRunning: { [runtime] in runtime.state == .running },
			configure: { [runtime, legacyProfileID] profiles in
				let profileKeys = Set(profiles.map { $0.chromiumProfile(legacy: legacyProfileID) })
				runtime.configureSiteIconProfiles(profileKeys)
			},
			lookupIcon: { [weak self, runtime, legacyProfileID, stored] key, mayFetch in
				let profile = key.profileID.chromiumProfile(legacy: legacyProfileID)

				// DEV-880: while its profile isn't loaded, a page shows the icon it showed last, or
				// none. Asking Chromium would load the whole profile for an icon; the sidebar pager
				// keeps other spaces' tabs mounted. Once the profile loads, they're read again.
				if runtime.supportsProfileRelease, !runtime.isPreparedOrdinaryProfile(profile) {
					self?.deferredSiteIconProfiles.insert(key.profileID)
					return stored?.icon(for: key).map { ChromiumSiteIconAnswer(png: $0, iconURL: nil) }
				}
				do {
					return try await runtime.siteIcon(
						pageURL: key.pageURL,
						profileID: profile,
						mayFetch: mayFetch
					).map { ChromiumSiteIconAnswer(png: $0.png, iconURL: $0.iconURL) }
				} catch ChromiumSiteIconFailure.discarded {
					// The icon Chromium had fetched for the page was another host's (DEV-1108):
					// the copy kept for unloaded tabs goes too, and the row shows none.
					stored?.forget(key)
					return nil
				}
			},
			changes: { [weak self] in self?.siteIconChanges() ?? .finished },
			stored: stored,
			setFetch: { [runtime] in runtime.setSiteIconFetch(enabled: $0) }
		)
		siteIconService = service
		return service.client
	}

	/// The pages the sidebar asks icons for: where each open or archived tab is now, and a
	/// saved tab's saved destination, which it shows again once closed (DEV-1294).
	internal static func siteIconKeys(_ organization: BrowserOrganization) -> Set<BrowserSiteIconKey> {
		let tabs = Array(organization.tabs) + organization.archive.map(\.tab)
		return Set(tabs.flatMap { tab in
			tab.siteIconURLs.map { BrowserSiteIconKey(profileID: tab.profileID, pageURL: $0) }
		})
	}

	/// DEV-880. A profile whose icons were answered from storage loaded: they're read again.
	internal func refreshDeferredSiteIcons(_ profile: UUID?) {
		let profileID = Profile.ID.chromium(profile, legacy: legacyProfileID)
		guard deferredSiteIconProfiles.remove(profileID) != nil else { return }

		for continuation in siteIconRefreshes.values {
			// Every page of the profile, as DEV-940's profile-wide changes are.
			continuation.yield(.init(profileID: profileID, pageURLs: nil) { [runtime] in
				runtime.isPreparedOrdinaryProfile(profile)
			})
		}
	}

	internal func siteIconChanges() -> AsyncStream<ChromiumSiteIconInvalidation> {
		let changes = runtime.siteIconChanges()
		return .init(bufferingPolicy: .bufferingNewest(256)) { continuation in
			let refreshes = UUID()
			siteIconRefreshes[refreshes] = continuation
			let task = Task { [runtime, legacyProfileID] in
				for await change in changes {
					guard !Task.isCancelled else { break }
					let profileID = Profile.ID.chromium(change.profileID, legacy: legacyProfileID)
					continuation.yieldKeepingRefreshes(.init(
						profileID: profileID,
						pageURLs: change.isProfileWide ? nil : Set(change.pageURLs),
						iconURLs: change.iconURL.map { [$0] } ?? []
					) {
						runtime.isCurrentSiteIconChange(change)
					})
				}
				continuation.finish()
			}
			continuation.onTermination = { [weak self] _ in
				task.cancel()
				Task { @MainActor [weak self] in self?.siteIconRefreshes[refreshes] = nil }
			}
		}
	}

	/// Explicitly composed only after ABI6 video fixtures pass. The default dependency stays unavailable.
	public func media() throws -> BrowserMediaClient {
		guard runtime.state == .running
		else { throw ChromiumMediaFailure.unavailable }
		if let mediaService { return mediaService.client }

		let service = ChromiumMediaAdapter(
			isCurrent: { [weak self] pageID, sourceID in
				guard
					let self,
					let page = self.pages[sourceID.tabID],
					page.identifier == pageID,
					self.pageProfiles[sourceID.tabID] == sourceID.profileID,
					!page.isPrivate
				else { return false }

				return self.runtime.isMediaSourceCurrent(page, generation: sourceID.generation)
			}
		) { [weak self] pageID, request, action in
			guard
				let self,
				let page = self.pages[request.sourceID.tabID],
				page.identifier == pageID,
				self.pageProfiles[request.sourceID.tabID] == request.sourceID.profileID,
				!page.isPrivate
			else { throw ChromiumMediaFailure.staleSource }

			if action == .seek {
				guard let position = request.position
				else { throw ChromiumMediaFailure.unsupportedAction }

				try await self.runtime.seekMedia(
					page,
					generation: request.sourceID.generation,
					revision: request.expectedRevision,
					to: position
				)
			} else {
				try await self.runtime.performMedia(
					page,
					generation: request.sourceID.generation,
					revision: request.expectedRevision,
					action: action
				)
			}
		} position: { [weak self] pageID in
			guard
				let self,
				let page = self.pages.values.first(where: { $0.identifier == pageID }),
				!page.isPrivate
			else { return nil }

			return self.runtime.mediaPosition(page)
		} setMuted: { [weak self] pageID, isMuted in
			guard
				let self,
				let page = self.pages.values.first(where: { $0.identifier == pageID }),
				!page.isPrivate
			else { throw ChromiumMediaFailure.staleSource }

			try self.runtime.setAudioMuted(page, isMuted)
			if let id = self.tabID(of: page) { self.onAudioMutedChange?(id, isMuted) }
		} supportsVolume: { [weak self] in
			self?.runtime.supportsAudioVolume ?? false
		} setVolume: { [weak self] pageID, volume in
			guard
				let self,
				let page = self.pages.values.first(where: { $0.identifier == pageID }),
				!page.isPrivate
			else { throw ChromiumMediaFailure.staleSource }

			try self.runtime.setAudioVolume(page, volume)
			if let id = self.tabID(of: page) { self.onAudioVolumeChange?(id, volume) }
		}

		for (tabID, page) in pages where !page.isPrivate {
			guard let profileID = pageProfiles[tabID]
			else { continue }

			try runtime.observeMedia(page)
			service.register(
				page: page.identifier,
				tabID: tabID,
				profileID: profileID,
				isPrivate: false
			)
		}

		service.performOutside = { [weak self] tabID, action in
			self?.performOutsideMedia?(tabID, action) ?? false
		}
		service.setOutside(outsideMedia)
		service.start(events: runtime.mediaEvents(), activations: runtime.mediaActivations())
		mediaService = service
		return service.client
	}

	/// Explicit wiring hook after the ABI7 fixture gate. The predicate must query current ordinary-profile ownership.
	/// No production dependency is enabled by constructing the engine.
	public func extensions(
		ordinaryProfileExists: @escaping @MainActor @Sendable (Profile.ID) -> Bool
	) -> BrowserExtensionsClient {
		if enableExtensionViews {
			runtime.onExtensionOptionsRevoked = { [weak self] page, nativeProfileID, extensionID in
				guard let self else { return }

				let profileID = Profile.ID.chromium(nativeProfileID, legacy: self.legacyProfileID)
				self.revokeExtensionOptions(page, profileID: profileID, extensionID: extensionID)
			}
			runtime.onExtensionOptionsSettled = { [weak self] page in
				guard
					let self,
					let offer = self.initialExtensionOptions.removeValue(forKey: page.identifier)
				else { return }

				self.onExtensionOptionsSettled?(offer)
			}
			runtime.onExtensionView = { [weak self] child, nativeProfileID, extensionID in
				guard let self else { return false }

				let profileID = Profile.ID.chromium(nativeProfileID, legacy: self.legacyProfileID)
				guard ordinaryProfileExists(profileID) else { return false }

				return self.adoptExtensionOptions(child, profileID: profileID, extensionID: extensionID)
			}
		}

		let adapter = ChromiumExtensionsAdapter(
			legacyProfileID: legacyProfileID,
			optionsAvailable: { [runtime, enableExtensionViews] in
				enableExtensionViews && runtime.supportsExtensionOptions
			},
			openOptions: { [runtime] id, inventory in
				try await runtime.openExtensionOptions(extensionID: id, in: inventory)
			},
			available: { [runtime] in runtime.supportsExtensions },
			installationAvailable: { [runtime] in runtime.supportsExtensionInstallation },
			ordinaryProfileExists: ordinaryProfileExists,
			inspect: { [runtime] in try await runtime.extensions(profileID: $0) },
			manage: { [runtime] action, id, inventory in
				try await runtime.manageExtension(action, extensionID: id, in: inventory)
			},
			prepareInstallation: { [runtime] package, expectedID, inventory in
				try await runtime.prepareExtensionInstallation(
					data: package.data,
					sourceBasename: package.sourceBasename,
					expectedExtensionID: expectedID,
					in: inventory
				)
			},
			resolveInstallation: { [runtime] prompt, accept in
				try await runtime.resolveExtensionInstallation(prompt, accept: accept)
			},
			cancelInstallation: { [runtime] in runtime.cancelExtensionInstallation($0) },
			unpackedAvailable: { [runtime] in runtime.supportsUnpackedExtensions },
			loadUnpacked: { [runtime] directory, inventory in
				try await runtime.loadUnpackedExtension(directory: directory, in: inventory)
			},
			webstoreAvailable: { [runtime] in runtime.supportsWebstoreInstallation },
			prepareWebstore: { [runtime] request, inventory in
				try await runtime.prepareWebstoreInstallation(request, in: inventory)
			},
			declineWebstore: { [runtime] in runtime.declineWebstoreInstallation($0) },
			webstoreUpdateAvailable: { [runtime] in runtime.supportsWebstoreUpdates },
			prepareWebstoreUpdate: { [runtime] extensionID, inventory in
				try await runtime.prepareWebstoreUpdate(of: extensionID, in: inventory)
			},
			webstoreImportAvailable: { [runtime] in runtime.supportsWebstoreImports },
			prepareWebstoreImport: { [runtime] extensionID, inventory in
				try await runtime.prepareWebstoreImport(of: extensionID, in: inventory)
			}
		)

		// DEV-765: the Chrome Web Store's Add to Chrome in any ordinary page.
		runtime.onWebstoreInstall = { [weak adapter] _, request in
			adapter?.offerWebstore(request) ?? false
		}
		var client = adapter.client
		client.setContentBlocking = { [runtime] isOn, cookieBanners in
			runtime.setContentBlocking(enabled: isOn, blockCookieBanners: cookieBanners)
		}
		return client
	}

	public var surface: BrowserSurfaceClient {
		.init(
			attach: { [self] in attach($0, to: $1) },
			detach: { [self] in detach($0) },
			stage: { [self] in stage($0, in: $1) },
			release: { [self] id in
				unmount(id)
				hosts[id] = nil
			},
			focus: { [self] id in

				// Typing in the page's docked DevTools stays there when its pane activates.
				if
					let tools = dockedDeveloperTools[id],
					let responder = tools.window?.firstResponder as? NSView,
					responder === tools || responder.isDescendant(of: tools)
				{ return }
				pages[id]?.focusContent()
			},
			bindUnhandledEscape: { [escapeHosts] tabID, host, handler in
				escapeHosts.bind(tabID, to: host, handler: handler)
			}
		)
	}
}
