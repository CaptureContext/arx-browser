import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

internal struct AutomationApprovalView: View {
	internal let store: StoreOf<AppFeature>

	internal init(store: StoreOf<AppFeature>) {
		self.store = store
	}

	internal var body: some View {
		if let context = approvalContext {
			let pending = context.pending
			let client = context.client

			VStack(alignment: .leading, spacing: 8) {
				Text(localized: .appUI.automation.approval)
					.font(.headline)
				Text(localized: .appUI.automation.untrusted)
					.font(.caption)
					.foregroundStyle(.secondary)

				Text(client.name).bold()
				if case let .command(command) = pending.request.operation {
					Text(command.action.title)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(command.targetID)
					)

					if let source = command.sourceTabID {
						LabeledContent(String.localized(.appUI.automation.sourceTab), value: targetName(source))
					}
					if let id = command.presentationID, let handle = store.automation.hostHandles[id] {
						let tab = store.peeks[id: handle.hostID]?.tab
						?? store.littleWindows[id: handle.hostID]?.tab
						if let tab {
							LabeledContent(
								String.localized(.appUI.automation.presentation),
								value: tab.displayTitle
							)
						}
					}
					if let destination = command.destinationID {
						LabeledContent(
							String.localized(.appUI.automation.destination),
							value: targetName(destination)
						)
					}
					if let url = command.url {
						Text(url.absoluteString)
							.font(.caption.monospaced())
							.textSelection(.enabled)
							.lineLimit(4)
					}
					if command.action == .startDownload {
						Text(localized: .appUI.automation.startDownloadDetail)
							.font(.callout)
					}
					if let name = command.name {
						LabeledContent(String.localized(.appUI.automation.rename), value: name)
					}
					if let appearance = command.appearance {
						LabeledContent(
							String.localized(.appUI.automation.appearance),
							value: Self.appearanceSummary(appearance)
						)
						.lineLimit(4)
					}
					if command.focus {
						Text(localized: .appUI.automation.focus).font(.caption)
					}

				} else if case let .scroll(scroll) = pending.request.operation {
					Text(localized: .appUI.automation.scroll)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(scroll.target.targetID)
					)
					if let description = elementDescription(scroll.target, pending: pending) {
						LabeledContent(String.localized(.appUI.automation.pageElement), value: description)
							.lineLimit(4)
					}
					Text(localized: .appUI.automation.scrollWarning)
						.font(.callout)

				} else if case let .form(form) = pending.request.operation {
					Text(form.kind.title)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(form.target.targetID)
					)
					if let description = elementDescription(form.target, pending: pending) {
						LabeledContent(String.localized(.appUI.automation.pageElement), value: description)
							.lineLimit(4)
					}
					if let consequence = pending.consequence {
						consequenceWarning(consequence, targetID: form.target.targetID)
					}
					if form.kind == .upload {
						// Every file is shown; the client never sees them echoed back.
						ForEach(form.values ?? [], id: \.self) { path in
							Text(path)
								.font(.callout.monospaced())
								.lineLimit(2)
								.truncationMode(.middle)
						}
						Text(localized: form.values?.isEmpty == false ? .appUI.automation.uploadWarning : .appUI.automation.uploadCancel)
							.font(.callout)
					} else if form.kind.isPointer {
						Text(localized: .appUI.automation.pointerWarning)
							.font(.callout)
					} else {
						Text(localized: .appUI.automation.formWarning)
							.font(.callout)
					}

				} else if case let .click(click) = pending.request.operation {
					Text(localized: .appUI.automation.click)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(click.targetID)
					)
					if let description = elementDescription(click, pending: pending) {
						LabeledContent(String.localized(.appUI.automation.pageElement), value: description)
							.lineLimit(4)
					}
					if let consequence = pending.consequence {
						consequenceWarning(consequence, targetID: click.targetID)
					}
					Text(localized: .appUI.automation.clickWarning)
						.font(.callout)

				} else if case let .dialog(dialog) = pending.request.operation {
					Text(localized: dialog.action == .accept ? .appUI.automation.acceptDialog : .appUI.automation.dismissDialog)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(dialog.targetID)
					)

					// The user sees the answer they are approving; the client never gets it back.
					if let text = dialog.text {
						LabeledContent(String.localized(.appUI.automation.dialogAnswer), value: text)
							.lineLimit(4)
					}
					Text(localized: .appUI.automation.dialogWarning)
						.font(.callout)

				} else if case let .media(media) = pending.request.operation {
					Text(localized: .appUI.automation.mediaControl)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: media.targetID.map(targetName) ?? ""
					)
					LabeledContent(String.localized(.appUI.automation.mediaAction), value: Self.mediaActionTitle(media.action))
					if let seconds = media.seconds {
						LabeledContent(
							String.localized(.appUI.automation.mediaSeekTime),
							value: Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 1, fractionalSecondsLength: 2)))
						)
					}
					Text(localized: .appUI.automation.mediaWarning)
						.font(.callout)

				} else if case let .settings(settings) = pending.request.operation, let change = settings.change {
					Text(localized: .appUI.automation.settingsChange)
					LabeledContent(change.edit.name, value: settingsSummary(change.edit, clientID: pending.request.clientID))
						.lineLimit(6)
					Text(localized: .appUI.automation.settingsWarning)
						.font(.callout)

				} else if case let .script(script) = pending.request.operation {
					Text(localized: .appUI.automation.runScript)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(script.targetID)
					)

					// The user approves the exact script; the binding covers its text.
					Text(localized: .appUI.automation.scriptSource)
						.font(.callout)
					ScrollView {
						Text(verbatim: script.script)
							.font(.system(.caption, design: .monospaced))
							.textSelection(.enabled)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
					.frame(maxHeight: 180)
					if let consequence = pending.consequence {
						consequenceWarning(consequence, targetID: script.targetID)
					}
					Text(localized: .appUI.automation.scriptWarning)
						.font(.callout)

				} else if case .passwordSignIn = pending.request.operation,
					let listing = store.automation.passwordSignIns[pending.request.id]
				{
					PasswordSignInApproval(store: store, requestID: pending.request.id, listing: listing)

				} else if case let .findInPage(find) = pending.request.operation {
					Text(localized: .appUI.automation.findInPage)
					LabeledContent(
						String.localized(.appUI.automation.target),
						value: targetName(find.targetID)
					)
					if let text = find.text {
						LabeledContent(String.localized(.appUI.automation.findInPage), value: text)
							.lineLimit(2)
					}
					Text(localized: .appUI.automation.findInPageWarning)
						.font(.callout)

				} else if case let .batch(plan) = pending.request.operation {
					Text(localized: .appUI.automation.batch(plan.steps.count))
					ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
						LabeledContent("\(index + 1). " + stepTitle(step), value: stepTarget(step))
							.font(.callout)
							.lineLimit(2)
						if let consequence = pending.stepConsequences[index], let targetID = step.consequenceTargetID {
							consequenceWarning(consequence, targetID: targetID)
						}
					}
					Text(localized: .appUI.automation.batchWarning)
						.font(.callout)
				}

				HStack {
					Button(String.localized(.appUI.automation.decline)) {
						store.send(.automation(.ui(.decline(pending.request.id))))
					}
					Button(String.localized(.appUI.automation.approve)) {
						store.send(.automation(.ui(.approve(pending.request.id))))
					}
				}
			}
			.padding()
			.frame(maxWidth: 540, alignment: .leading)
			.pagePopupSurface()
		}
	}

	/// What a consequential press does, what it presses and where, and that it always asks (DEV-1008).
	private func consequenceWarning(
		_ consequence: AutomationConsequence,
		targetID: UUID
	) -> some View {
		let site = consequence.host ?? targetName(targetID)
		let effect: String = switch consequence.kind {
		case .pay: String.localized(.appUI.automation.consequencePay(site))
		case .send: String.localized(.appUI.automation.consequenceSend(site))
		case .post: String.localized(.appUI.automation.consequencePost(site))
		case .delete: String.localized(.appUI.automation.consequenceDelete(site))
		case .submit: String.localized(.appUI.automation.consequenceSubmit(site))
		}

		return VStack(alignment: .leading, spacing: 2) {
			if let label = consequence.label {
				Text(localized: .appUI.automation.consequencePresses(label))
					.lineLimit(2)
			}
			Text(verbatim: effect)
				.bold()
			Text(localized: .appUI.automation.consequenceAlwaysAsks)
				.font(.caption)
				.foregroundStyle(.secondary)
		}
		.font(.callout)
		.foregroundStyle(.red)
	}

	private func stepTitle(_ step: AutomationOperation) -> String {
		switch step {
		case let .command(command): command.action.title
		case .click: String.localized(.appUI.automation.click)
		case let .form(form): form.kind.title
		case .scroll: String.localized(.appUI.automation.scroll)
		case .findInPage: String.localized(.appUI.automation.findInPage)
		case let .dialog(dialog):
			String.localized(dialog.action == .accept ? .appUI.automation.acceptDialog : .appUI.automation.dismissDialog)
		case let .media(media): Self.mediaActionTitle(media.action)
		case .settings: String.localized(.appUI.automation.settingsChange)
		case .script: String.localized(.appUI.automation.runScript)
		case .passwordSignIn: String.localized(.appUI.automation.passwordSignIn)
		case .inventory, .inspect, .wait, .capture, .signIn, .batch, .data, .link, .load, .pdf, .logs:
			String.localized(.appUI.automation.batchRead)
		}
	}

	private func stepTarget(_ step: AutomationOperation) -> String {
		switch step {
		case let .command(command): targetName(command.targetID)
		case let .click(click): targetName(click.targetID)
		case let .form(form): targetName(form.target.targetID)
		case let .scroll(scroll): targetName(scroll.target.targetID)
		case let .inspect(request): targetName(request.targetID)
		case let .wait(request): targetName(request.targetID)
		case let .capture(request): targetName(request.targetID)
		case let .load(request): targetName(request.targetID)
		case let .pdf(request): targetName(request.targetID)
		case let .findInPage(request): targetName(request.targetID)
		case let .dialog(request): targetName(request.targetID)
		case let .media(request): request.targetID.map(targetName) ?? ""
		case let .script(request): targetName(request.targetID)
		case let .logs(request): targetName(request.targetID)
		case let .passwordSignIn(request): targetName(request.targetID)
		case .inventory, .signIn, .batch, .data, .link, .settings: ""
		}
	}

	private static func mediaActionTitle(_ action: AutomationMediaRequest.Action) -> String {
		switch action {
		case .list: String.localized(.appUI.automation.batchRead)
		case .play: String.localized(.appUI.media.play)
		case .pause: String.localized(.appUI.media.pause)
		case .enterPictureInPicture: String.localized(.appUI.media.enterPicture)
		case .exitPictureInPicture: String.localized(.appUI.media.exitPicture)
		case .seek: String.localized(.appUI.automation.mediaSeek)
		case .mute: String.localized(.appUI.automation.mediaMute)
		case .unmute: String.localized(.appUI.automation.mediaUnmute)
		case .position: String.localized(.appUI.automation.batchRead)
		}
	}

	/// The fields an appearance change chooses, inherits or clears, as the agent sent them.
	private static func appearanceSummary(_ change: AutomationAppearanceChange) -> String {
		let set = change.set
		var parts: [String] = change.clearsAll ? ["clear all"] : []
		if let theme = set.theme { parts.append("theme \(theme.rawValue)") }
		if let hue = set.tintHue { parts.append("tintHue \(hue.formatted())") }
		if let intensity = set.tintIntensity { parts.append("tintIntensity \(intensity.formatted())") }
		if let enabled = set.grainEnabled { parts.append("grainEnabled \(enabled)") }
		if let intensity = set.grainIntensity { parts.append("grainIntensity \(intensity.formatted())") }
		if let size = set.grainSize { parts.append("grainSize \(size.formatted())") }
		if let accent = set.accent { parts.append("accentColor \(ChromeAccent.automationName(of: accent))") }
		if let matchesSite = set.matchesSite { parts.append("matchesSite \(matchesSite)") }
		if let gradient = set.gradient { parts.append("gradient \(gradientSummary(gradient))") }
		parts += change.inherit.sorted().map { "\($0.rawValue) inherits" }
		return parts.joined(separator: ", ")
	}

	/// `plain`, or each added color's hue and intensity and the angle.
	private static func gradientSummary(_ gradient: ChromeGradient) -> String {
		guard !gradient.stops.isEmpty else { return "plain" }

		let stops = gradient.stops.map { "hue \($0.hue.formatted()) at \($0.intensity.formatted())" }
		return stops.joined(separator: " and ") + ", angle \(gradient.angle.formatted())"
	}

	/// What a settings change does, in Settings' own terms where Arx has them.
	private func settingsSummary(
		_ edit: AutomationSettingsEdit,
		clientID: UUID
	) -> String {
		func value(_ value: AutomationPreferenceValue) -> String {
			switch value {
			case let .bool(flag): String(flag)
			case let .string(text): text
			case let .number(number): number.formatted()
			}
		}
		func rule(_ id: UUID) -> String {
			store.settings.routingPreferences.rules.first { $0.id == id }?.name ?? id.uuidString
		}
		func destination(_ destination: AutomationRoutingDestination) -> String {
			let place = destination.id.map(targetName) ?? destination.scope.rawValue
			return "\(place) (\(destination.mode.rawValue))"
		}

		switch edit {
		case let .setPreferences(settings):
			return settings.map { "\($0.key.rawValue) → \(value($0.value))" }.joined(separator: "\n")
		case let .saveRoutingRule(value):
			return "\(value.name): \(value.host)\(value.pathPrefix ?? "") → \(destination(value.destination))"
		case let .deleteRoutingRule(id):
			return rule(id)
		case let .moveRoutingRule(id, offset):
			return "\(rule(id)) \(offset < 0 ? "↑" : "↓")"
		case let .setRoutingRuleEnabled(id, enabled):
			return "\(rule(id)) → \(enabled)"
		case let .saveSearchShortcut(shortcut, replacing):
			let replaced = replacing.map { " (replaces !\($0))" } ?? ""
			return "!\(shortcut.keyword) \(shortcut.name): \(shortcut.template)\(replaced)"
		case let .deleteSearchShortcut(keyword):
			return "!\(keyword)"
		case let .setSearchShortcutEnabled(keyword, enabled):
			return "!\(keyword) → \(enabled)"
		case let .setKeyboardShortcut(command, shortcut, replaces):
			let conflicts = shortcut.map { store.settings.keyboardShortcuts.conflicts(for: $0, excluding: command) } ?? []
			let taken = replaces && !conflicts.isEmpty
			? " (taken from " + conflicts.map(\.rawValue).joined(separator: ", ") + ")"
			: ""
			return "\(command.rawValue) → \(shortcut?.display ?? "none")\(taken)"
		case let .resetKeyboardShortcut(command, _):
			return "\(command.rawValue) → \(command.shortcut?.display ?? "none")"
		case let .setShortcutConflictResolution(command, resolution):
			return "\(command.rawValue) conflict resolution → \(resolution.rawValue)"
		case let .setExtensionEnabled(profileID, extensionID, enabled):
			return "\(extensionID) (\(targetName(profileID))) → \(enabled ? "enabled" : "disabled")"
		case let .installExtension(profileID, extensionID):
			// Approved in the Extensions sheet's review, never here; listed for completeness.
			return "\(extensionID) (\(targetName(profileID))) → install"
		case let .setSitePermission(profileID, origin, permission, setting):
			let site = origin ?? String.localized(.appUI.siteSettings.defaults)
			let value = setting.map { $0.rawValue } ?? String.localized(.appUI.siteSettings.remove)
			return "\(site) \(permission.rawValue) (\(targetName(profileID))) → \(value)"
		case let .undoPreferences(operationID):
			// DEV-1023: what the undo puts back.
			let change = store.automation.preferenceChange(operationID, clientID: clientID)
			return (change?.before ?? []).map { "\($0.key.rawValue) → \(value($0.value))" }.joined(separator: "\n")
		case let .setSiteZoom(profileID, host, factor):
			let site = host ?? String.localized(.appUI.siteSettings.defaultZoom)
			let value = factor.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? String.localized(.appUI.siteSettings.remove)
			return "\(site) (\(targetName(profileID))) → \(value)"
		}
	}

	private var approvalContext: (
		pending: AutomationState.Pending,
		client: AutomationClient
	)? {
		let pending = store.automation.pending.values.first {
			$0.awaitingApproval
			&& !$0.approved
			&& ($0.request.operation.mutationID != nil || $0.request.operation.isBatch)
		}

		let clients = store.automationPreferences.clients
		guard
			let pending,
			let client = clients.first(where: { $0.id == pending.request.clientID })
		else { return nil }

		return (pending, client)
	}

	private func elementDescription(
		_ click: AutomationClickRequest,
		pending: AutomationState.Pending
	) -> String? {
		let released = store.automation.releasedInspections.first {
			$0.request.sessionID == pending.request.sessionID
			&& $0.request.clientID == pending.request.clientID
			&& $0.result.request.targetID == click.targetID
			&& $0.result.snapshot.snapshotID == click.snapshotID
		}
		guard
			let released,
			let node = released.result.snapshot.nodes.first(where: { $0.reference == click.reference })
		else { return nil }

		return [node.role, node.name ?? node.text].compactMap { $0 }.joined(separator: ": ")
	}

	private func targetName(_ id: UUID) -> String {
		store.workspace.tabs.first(where: { $0.id.rawValue == id })?.displayTitle
		?? store.workspace.spaces.first(where: { $0.id.rawValue == id })?.name
		?? store.workspace.folders.first(where: { $0.id.rawValue == id })?.name
		?? store.workspace.profiles.first(where: { $0.id.rawValue == id })?.name
		?? id.uuidString
	}
}

extension AutomationFormRequest.Kind {
	fileprivate var title: String {
		switch self {
		case .replaceText: String.localized(.appUI.automation.replaceText)
		case .selectValue: String.localized(.appUI.automation.selectValue)
		case .keyPress: String.localized(.appUI.automation.keypress)
		case .hover: String.localized(.appUI.automation.hover)
		case .pointerClick: String.localized(.appUI.automation.pointerClick)
		case .drag: String.localized(.appUI.automation.drag)
		case .typeText: String.localized(.appUI.automation.typeText)
		case .keyChord: String.localized(.appUI.automation.keyChord)
		case .selectValues: String.localized(.appUI.automation.selectValues)
		case .setChecked: String.localized(.appUI.automation.setChecked)
		case .upload: String.localized(.appUI.automation.upload)
		}
	}
}

extension AutomationCommand.Action {
	fileprivate var title: String {
		switch self {
		case .openTab: String.localized(.appUI.automation.openTab)
		case .selectTab: String.localized(.appUI.automation.selectTab)
		case .navigate: String.localized(.appUI.automation.navigate)
		case .reload: String.localized(.appUI.automation.reload)
		case .back: String.localized(.appUI.automation.back)
		case .forward: String.localized(.appUI.automation.forward)
		case .stop: String.localized(.appUI.automation.stop)
		case .pinTab: String.localized(.appUI.automation.pinTab)
		case .unpinTab: String.localized(.appUI.automation.unpinTab)
		case .moveTab: String.localized(.appUI.automation.moveTab)
		case .moveFolder: String.localized(.appUI.automation.moveFolder)
		case .createFolder: String.localized(.appUI.automation.createFolder)
		case .renameFolder: String.localized(.appUI.automation.renameFolder)
		case .openPeek: String.localized(.appUI.automation.openPeek)
		case .openLittleArx: String.localized(.appUI.automation.openLittleArx)
		case .promotePeekToTab: String.localized(.appUI.automation.promotePeekToTab)
		case .promotePeekToLittleArx: String.localized(.appUI.automation.promotePeekToLittleArx)
		case .promoteLittleArx: String.localized(.appUI.automation.promoteLittleArx)
		case .closeTab: String.localized(.appUI.automation.closeTab)
		case .createProfile: String.localized(.appUI.automation.createProfile)
		case .renameProfile: String.localized(.appUI.automation.renameProfile)
		case .deleteProfile: String.localized(.appUI.automation.deleteProfile)
		case .createSpace: String.localized(.appUI.automation.createSpace)
		case .renameSpace: String.localized(.appUI.automation.renameSpace)
		case .setSpaceTheme: String.localized(.appUI.automation.setSpaceTheme)
		case .setSpaceAppearance: String.localized(.appUI.automation.setSpaceAppearance)
		case .setProfileAppearance: String.localized(.appUI.automation.setProfileAppearance)
		case .moveSpace: String.localized(.appUI.automation.moveSpace)
		case .deleteSpace: String.localized(.appUI.automation.deleteSpace)
		case .selectSpace: String.localized(.appUI.automation.selectSpace)
		case .addFavorite: String.localized(.appUI.automation.addFavorite)
		case .removeFavorite: String.localized(.appUI.automation.removeFavorite)
		case .updateSavedURL: String.localized(.appUI.automation.updateSavedURL)
		case .removeSavedEntry: String.localized(.appUI.automation.removeSavedEntry)
		case .ungroupFolder: String.localized(.appUI.automation.ungroupFolder)
		case .deleteFolder: String.localized(.appUI.automation.deleteFolder)
		case .openSplit: String.localized(.appUI.automation.openSplit)
		case .swapSplit: String.localized(.appUI.automation.swapSplit)
		case .closeSplit: String.localized(.appUI.automation.closeSplit)
		case .focusWindow: String.localized(.appUI.automation.focusWindow)
		case .restoreArchived: String.localized(.appUI.automation.restoreArchived)
		case .cancelDownload: String.localized(.appUI.automation.cancelDownload)
		case .revealDownload: String.localized(.appUI.automation.revealDownload)
		case .startDownload: String.localized(.appUI.automation.startDownload)
		}
	}
}

extension AutomationOperation {
	/// The tab a step that can be consequential acts on.
	fileprivate var consequenceTargetID: UUID? {
		switch self {
		case let .click(request): request.targetID
		case let .form(request): request.target.targetID
		case let .script(request): request.targetID
		default: nil
		}
	}
}
