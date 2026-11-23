import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import UniformTypeIdentifiers
import _ComposableArchitecture

/// One profile's saved passwords (DEV-721), opened from its Profiles page.
public struct SavedPasswordsView: View {
	@Bindable
	public var store: StoreOf<SavedPasswordsFeature>

	/// Sites in this profile where agents sign in without asking. AppFeature owns them.
	public let agentSignInSites: [AgentSignInSite]
	public let removeAgentSignInSite: (AgentSignInSite) -> Void

	public init(
		store: StoreOf<SavedPasswordsFeature>,
		agentSignInSites: [AgentSignInSite] = [],
		removeAgentSignInSite: @escaping (AgentSignInSite) -> Void = { _ in }
	) {
		self.store = store
		self.agentSignInSites = agentSignInSites
		self.removeAgentSignInSite = removeAgentSignInSite
	}

	public var body: some View {
		ArxModalScaffold(contentPadding: SettingsSheetMetrics.contentPadding) {
			SettingsNavigationBar(
				.close { store.send(.ui(.done)) },
				title: String.localized(.appUI.savedPasswords.title),
				trail: [SettingsCategory.profiles.title, store.profileName]
			) {
				Button(String.localized(.appUI.savedPasswords.add)) {
					store.send(.ui(.addPassword))
				}
				.buttonStyle(.arxRaised(.capsule))
				Button(String.localized(.appUI.savedPasswords.import)) {
					store.send(.ui(.importPresented(true)))
				}
				.buttonStyle(.arxRaised(.capsule))
				.help(String.localized(.appUI.savedPasswords.importHelp))
				ArxHeaderSearch(
					String.localized(.appUI.savedPasswords.search),
					query: $store.query.sending(\.ui.queryChanged),
					width: 260
				)
			}
		} content: {
			VStack(alignment: .leading, spacing: 16) {
				header
				passwords
				neverSaved
				agentSites
			}
		} footer: {
			if store.notice != nil {
				footer
			}
		}
		.font(SettingsTypography.body)
		.frame(width: SettingsSheetMetrics.width, height: 560)
		.task { store.send(.ui(.appeared)) }
		.fileImporter(
			isPresented: $store.isImporting.sending(\.ui.importPresented),
			allowedContentTypes: [.commaSeparatedText, .plainText]
		) { result in
			if case let .success(file) = result {
				store.send(.ui(.importFile(file)))
			}
		}
		.sheet(
			item: Binding(
				get: { store.editor },
				set: { if $0 == nil { store.send(.ui(.cancelEditor)) } }
			)
		) { editor in
			SavedPasswordEditorView(store: store, editor: editor)
		}
		.sheet(
			item: Binding(
				get: { store.reveal },
				set: { if $0 == nil { store.send(.ui(.closeReveal)) } }
			)
		) { reveal in
			SavedPasswordRevealView(store: store, reveal: reveal)
		}
		.alert(
			removalTitle,
			isPresented: Binding(
				get: { store.removal != nil },
				set: { if !$0 { store.send(.ui(.cancelRemoval)) } }
			)
		) {
			Button(String.localized(.appUI.savedPasswords.cancel), role: .cancel) {
				store.send(.ui(.cancelRemoval))
			}
			Button(
				String.localized(store.removal?.isNeverSaved == true ? .appUI.savedPasswords.allow : .appUI.savedPasswords.remove),
				role: .destructive
			) {
				store.send(.ui(.confirmRemoval))
			}
		} message: {
			Text(localized: .appUI.savedPasswords.removeNote)
		}
		.alert(
			String.localized(.appUI.savedPasswords.importTitle),
			isPresented: Binding(
				get: { store.importSummary != nil },
				set: { if !$0 { store.send(.ui(.dismissImportSummary)) } }
			)
		) {
			Button(String.localized(.appUI.savedPasswords.ok)) {
				store.send(.ui(.dismissImportSummary))
			}
		} message: {
			Text(verbatim: store.importSummary.map(Self.summary) ?? "")
		}
	}

	/// What the sheet holds, under the bar's title.
	private var header: some View {
		Text(localized: .appUI.savedPasswords.subtitle(store.profileName))
			.foregroundStyle(.secondary)
	}

	@ViewBuilder
	private var passwords: some View {
		let visible = store.visiblePasswords
		if visible.isEmpty {
			Text(
				localized: store.isLoading
				? .appUI.savedPasswords.loading
				: store.list.passwords.isEmpty ? .appUI.savedPasswords.empty : .appUI.savedPasswords.noMatches
			)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, minHeight: 80)

		} else {
			SettingsCard {
				ForEach(visible) { password in
					if password.id != visible.first?.id { Divider() }
					SavedPasswordRow(store: store, password: password)
				}
			}
		}
	}

	@ViewBuilder
	private var neverSaved: some View {
		if !store.list.neverSaved.isEmpty {
			VStack(alignment: .leading, spacing: 6) {
				Text(localized: .appUI.savedPasswords.neverSaved)
					.font(SettingsTypography.heading)
				Text(localized: .appUI.savedPasswords.neverSavedDetail)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
				SettingsCard {
					ForEach(store.list.neverSaved) { site in
						if site.id != store.list.neverSaved.first?.id { Divider() }
						HStack {
							Text(verbatim: site.site)
							Spacer()
							Button(String.localized(.appUI.savedPasswords.remove)) {
								store.send(.ui(.removeNeverSavedSite(site.id)))
							}
						}
						.padding(.vertical, 4)
					}
				}
			}
		}
	}

	@ViewBuilder
	private var agentSites: some View {
		if !agentSignInSites.isEmpty {
			VStack(alignment: .leading, spacing: 6) {
				Text(localized: .appUI.automation.passwordSites)
					.font(SettingsTypography.heading)
				Text(localized: .appUI.automation.passwordSitesDetail)
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
				SettingsCard {
					ForEach(agentSignInSites, id: \.self) { site in
						if site != agentSignInSites.first { Divider() }
						HStack {
							Text(verbatim: site.origin)
							Spacer()
							Button(String.localized(.appUI.automation.passwordSiteRemove)) {
								removeAgentSignInSite(site)
							}
						}
						.padding(.vertical, 4)
					}
				}
			}
		}
	}

	private var footer: some View {
		HStack(alignment: .firstTextBaseline) {
			if let notice = store.notice {
				Text(verbatim: Self.message(notice))
					.foregroundStyle(notice == .copied ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
					.font(SettingsTypography.caption)
			}
			Spacer(minLength: 0)
		}
	}

	private var removalTitle: String {
		guard let removal = store.removal
		else { return "" }

		return String.localized(
			removal.isNeverSaved
			? .appUI.savedPasswords.removeSiteTitle(removal.site)
			: .appUI.savedPasswords.removeTitle(removal.site)
		)
	}

	internal static func message(_ notice: SavedPasswordsFeature.Notice) -> String {
		switch notice {
		case .copied: String.localized(.appUI.savedPasswords.copied)
		case let .failure(failure): message(failure)
		}
	}

	internal static func message(_ failure: BrowserSavedPasswordFailure) -> String {
		switch failure {
		case .unavailable: String.localized(.appUI.savedPasswords.error.unavailable)
		case .invalid: String.localized(.appUI.savedPasswords.error.invalid)
		case .stale: String.localized(.appUI.savedPasswords.error.stale)
		case .notFound: String.localized(.appUI.savedPasswords.error.notFound)
		case .exists: String.localized(.appUI.savedPasswords.error.exists)
		case .denied: String.localized(.appUI.savedPasswords.error.denied)
		case .busy: String.localized(.appUI.savedPasswords.error.busy)
		case .unreadableFile: String.localized(.appUI.savedPasswords.error.unreadableFile)
		case .badFormat: String.localized(.appUI.savedPasswords.error.badFormat)
		case .fileTooLarge: String.localized(.appUI.savedPasswords.error.fileTooLarge)
		case .tooManyPasswords: String.localized(.appUI.savedPasswords.error.tooManyPasswords)
		case .failed: String.localized(.appUI.savedPasswords.error.failed)
		}
	}

	internal static func summary(_ summary: BrowserPasswordImportSummary) -> String {
		var lines = [String.localized(.appUI.savedPasswords.imported(String(summary.imported)))]
		if summary.conflictCount > 0 {
			lines.append(String.localized(.appUI.savedPasswords.conflicts(String(summary.conflictCount))))
			lines += summary.conflicts.prefix(5).map { "• \($0.site) — \(username($0.username))" }
		}
		if summary.skippedCount > 0 {
			lines.append(String.localized(.appUI.savedPasswords.skipped(String(summary.skippedCount))))
			lines += summary.skipped.prefix(5).map { row in
				"• \(row.site.isEmpty ? "—" : row.site): \(reason(row.reason ?? .unknown))"
			}
		}
		return lines.joined(separator: "\n")
	}

	internal static func username(_ username: String) -> String {
		username.isEmpty ? String.localized(.appUI.passwords.noUsername) : username
	}

	private static func reason(_ reason: BrowserPasswordImportSummary.Row.Reason) -> String {
		switch reason {
		case .missingPassword: String.localized(.appUI.savedPasswords.skip.missingPassword)
		case .missingURL: String.localized(.appUI.savedPasswords.skip.missingURL)
		case .invalidURL: String.localized(.appUI.savedPasswords.skip.invalidURL)
		case .tooLong: String.localized(.appUI.savedPasswords.skip.tooLong)
		case .unknown: String.localized(.appUI.savedPasswords.skip.unknown)
		}
	}
}

private struct SavedPasswordRow: View {
	internal let store: StoreOf<SavedPasswordsFeature>
	internal let password: BrowserSavedPassword

	internal var body: some View {
		HStack(spacing: 10) {
			Image(systemName: "key.fill")
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(verbatim: password.site)
				Text(verbatim: SavedPasswordsView.username(password.username))
					.font(SettingsTypography.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Button(String.localized(.appUI.savedPasswords.copy)) {
				store.send(.ui(.copyPassword(password.id)))
			}
			Menu {
				Button(String.localized(.appUI.savedPasswords.show)) {
					store.send(.ui(.showPassword(password.id)))
				}
				Button(String.localized(.appUI.savedPasswords.edit)) {
					store.send(.ui(.editPassword(password.id)))
				}
				Divider()
				Button(String.localized(.appUI.savedPasswords.remove), role: .destructive) {
					store.send(.ui(.removePassword(password.id)))
				}
			} label: {
				Image(systemName: "ellipsis.circle")
			}
			.menuStyle(.borderlessButton)
			.fixedSize()
			.accessibilityLabel(String.localized(.appUI.savedPasswords.actions(password.site)))
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .contain)
	}
}

private struct SavedPasswordEditorView: View {
	internal let store: StoreOf<SavedPasswordsFeature>
	internal let editor: SavedPasswordsFeature.Editor

	internal var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: editor.mode == .add ? .appUI.savedPasswords.addTitle : .appUI.savedPasswords.editTitle)
				.font(.title3.bold())
			VStack(alignment: .leading, spacing: 10) {
				if editor.mode == .add {
					SettingsTextField(
						String.localized(.appUI.savedPasswords.site),
						text: Binding(
							get: { store.editor?.site ?? "" },
							set: { store.send(.ui(.editorSiteChanged($0))) }
						),
						prompt: String.localized(.appUI.savedPasswords.sitePlaceholder)
					)
				} else {
					SettingsSection {
						SettingsRow(String.localized(.appUI.savedPasswords.site)) {
							Text(editor.site).foregroundStyle(.secondary)
						}
					}
				}
				SettingsTextField(
					String.localized(.appUI.savedPasswords.username),
					text: Binding(
						get: { store.editor?.username ?? "" },
						set: { store.send(.ui(.editorUsernameChanged($0))) }
					),
					prompt: String.localized(.appUI.settings.example.username)
				)
				SettingsFieldFrame(String.localized(.appUI.savedPasswords.password)) {
					LentPasswordField(id: editor.passwordField, kind: .entry)
						.accessibilityLabel(Text(localized: .appUI.savedPasswords.password))
				}
				if editor.mode != .add {
					Text(localized: .appUI.savedPasswords.keepPassword)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
						.padding(.horizontal, 12)
				}
			}
			if let notice = store.notice {
				Text(verbatim: SavedPasswordsView.message(notice))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer()
				ArxModalButton.cancel(String.localized(.appUI.savedPasswords.cancel)) {
					store.send(.ui(.cancelEditor))
				}
				ArxModalButton(String.localized(.appUI.savedPasswords.save)) {
					store.send(.ui(.saveEditor))
				}
				.disabled(store.editor?.isSaving ?? true)
			}
		}
		.padding(20)
		.frame(width: 440)
		.arxModalSheet()
		.settingsControls()
	}
}

private struct SavedPasswordRevealView: View {
	internal let store: StoreOf<SavedPasswordsFeature>
	internal let reveal: SavedPasswordsFeature.Reveal

	internal var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text(localized: .appUI.savedPasswords.revealTitle(reveal.site))
				.font(.title3.bold())
			Text(verbatim: SavedPasswordsView.username(reveal.username))
				.foregroundStyle(.secondary)
			LentPasswordField(id: reveal.field, kind: .reveal) {
				store.send(.ui(.revealFieldReady))
			}
			.frame(minWidth: 320, minHeight: 24)
			Text(localized: .appUI.savedPasswords.revealNote)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			HStack {
				Spacer()
				ArxModalButton(String.localized(.appUI.savedPasswords.close)) {
					store.send(.ui(.closeReveal))
				}
			}
		}
		.padding(20)
		.frame(width: 400)
		.arxModalSheet()
		.settingsControls()
	}
}

/// An AppKit field lent to the engine for one password (DEV-721). Swift never
/// reads or sets its value: the engine reads a typed password from it, or
/// writes a revealed one into it. It's emptied when it goes away.
internal struct LentPasswordField: NSViewRepresentable {
	internal enum Kind {
		/// A secure field the user types a password into.
		case entry

		/// A read-only field the engine writes a revealed password into.
		case reveal
	}

	internal let id: BrowserPasswordFieldID
	internal let kind: Kind

	/// Called once the field is in a window, so the engine can write to it.
	internal var inWindow: @MainActor () -> Void = {}

	internal init(
		id: BrowserPasswordFieldID,
		kind: Kind,
		inWindow: @escaping @MainActor () -> Void = {}
	) {
		self.id = id
		self.kind = kind
		self.inWindow = inWindow
	}

	internal func makeCoordinator() -> Coordinator {
		.init(id: id)
	}

	internal func makeNSView(context: Context) -> NSTextField {
		let field: NSTextField
		switch kind {
		case .entry:
			field = NSSecureTextField()
			field.contentType = .password

			// Drawn inside a Settings field frame, keeping the native focus ring.
			field.isBordered = false
			field.drawsBackground = false

		case .reveal:
			let reveal = WindowAwareTextField()
			reveal.isEditable = false
			reveal.isSelectable = true
			reveal.isBordered = false
			reveal.drawsBackground = false
			reveal.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize + 2, weight: .regular)
			reveal.onWindow = inWindow
			field = reveal
		}
		BrowserPasswordFields.register(field, as: id)
		return field
	}

	internal func updateNSView(
		_ field: NSTextField,
		context: Context
	) {}

	internal static func dismantleNSView(
		_ field: NSTextField,
		coordinator: Coordinator
	) {
		field.stringValue = ""
		BrowserPasswordFields.unregister(coordinator.id)
	}

	internal final class Coordinator {
		internal let id: BrowserPasswordFieldID

		internal init(id: BrowserPasswordFieldID) {
			self.id = id
		}
	}

	private final class WindowAwareTextField: NSTextField {
		internal var onWindow: (@MainActor () -> Void)?

		internal override func viewDidMoveToWindow() {
			super.viewDidMoveToWindow()
			guard window != nil, let onWindow
			else { return }

			self.onWindow = nil
			onWindow()
		}
	}
}

extension SavedPasswordsFeature.Editor: Identifiable {
	public var id: BrowserPasswordFieldID { passwordField }
}

extension SavedPasswordsFeature.Reveal: Identifiable {}
