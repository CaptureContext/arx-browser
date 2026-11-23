import AppKit
import AppUI
import BrowserCore
import BrowserEngineClient
import SwiftUI
import _ComposableArchitecture

/// One profile's addresses and payment cards (DEV-893), opened from its Profiles page.
public struct AutofillDataView: View {
	@Bindable
	public var store: StoreOf<AutofillDataFeature>

	public init(store: StoreOf<AutofillDataFeature>) {
		self.store = store
	}

	public var body: some View {
		ArxModalScaffold(contentPadding: SettingsSheetMetrics.contentPadding) {
			SettingsNavigationBar(
				.close { store.send(.ui(.done)) },
				title: String.localized(.appUI.autofill.title),
				trail: [SettingsCategory.profiles.title, store.profileName]
			) {
				Button(String.localized(.appUI.autofill.addAddress)) {
					store.send(.ui(.addAddress))
				}
				.buttonStyle(.arxRaised(.capsule))
				.disabled(store.isSaving)
				Button(String.localized(.appUI.autofill.addCard)) {
					store.send(.ui(.addCard))
				}
				.buttonStyle(.arxRaised(.capsule))
				.disabled(store.isSaving)
			}
		} content: {
			VStack(alignment: .leading, spacing: 16) {
				Text(localized: .appUI.autofill.subtitle(store.profileName))
					.foregroundStyle(.secondary)
				SettingsSection(String.localized(.appUI.autofill.addresses)) {
					if store.listing.addresses.isEmpty {
						Text(localized: store.isLoading ? .appUI.autofill.loading : .appUI.autofill.noAddresses)
							.foregroundStyle(.secondary)
							.settingsRow()
					}
					ForEach(store.listing.addresses) { address in
						row(
							symbol: "house",
							title: AutofillDataFeature.title(address),
							detail: [address.street, address.city, address.zip, address.country]
								.filter { !$0.isEmpty }
								.joined(separator: ", "),
							edit: { store.send(.ui(.editAddress(address.id))) },
							remove: { store.send(.ui(.remove(address.id))) }
						)
					}
				}
				SettingsSection(
					String.localized(.appUI.autofill.cards),
					footer: String.localized(.appUI.autofill.cardsFooter)
				) {
					if store.listing.cards.isEmpty {
						Text(localized: store.isLoading ? .appUI.autofill.loading : .appUI.autofill.noCards)
							.foregroundStyle(.secondary)
							.settingsRow()
					}
					ForEach(store.listing.cards) { card in
						row(
							symbol: "creditcard",
							title: AutofillDataFeature.title(card),
							detail: [card.name, String(format: "%02d/%d", card.month, card.year)]
								.filter { !$0.isEmpty }
								.joined(separator: " · "),
							edit: { store.send(.ui(.editCard(card.id))) },
							remove: { store.send(.ui(.remove(card.id))) }
						)
					}
				}
			}
		} footer: {
			if let failure = store.failure, store.addressEditor == nil, store.cardEditor == nil {
				HStack {
					Text(verbatim: Self.message(failure))
						.foregroundStyle(.red)
					Spacer()
					Button(String.localized(.appUI.savedPasswords.ok)) {
						store.send(.ui(.dismissFailure))
					}
				}
			}
		}
		.font(SettingsTypography.body)
		.frame(width: SettingsSheetMetrics.width, height: 560)
		.task { store.send(.ui(.appeared)) }
		.sheet(
			item: Binding(
				get: { store.addressEditor },
				set: { if $0 == nil { store.send(.ui(.cancelEditor)) } }
			)
		) { _ in
			AutofillAddressEditor(store: store)
		}
		.sheet(
			item: Binding(
				get: { store.cardEditor },
				set: { if $0 == nil { store.send(.ui(.cancelEditor)) } }
			)
		) { editor in
			AutofillCardEditor(store: store, numberField: editor.numberField, lastFour: editor.lastFour)
		}
		.alert(
			String.localized(.appUI.autofill.removeTitle(store.removal?.title ?? "")),
			isPresented: Binding(
				get: { store.removal != nil },
				set: { if !$0 { store.send(.ui(.cancelRemoval)) } }
			)
		) {
			Button(String.localized(.appUI.savedPasswords.cancel), role: .cancel) {
				store.send(.ui(.cancelRemoval))
			}
			Button(String.localized(.appUI.savedPasswords.remove), role: .destructive) {
				store.send(.ui(.confirmRemoval))
			}
		} message: {
			Text(localized: .appUI.autofill.removeNote)
		}
	}

	private func row(
		symbol: String,
		title: String,
		detail: String,
		edit: @escaping () -> Void,
		remove: @escaping () -> Void
	) -> some View {
		HStack(spacing: 10) {
			Image(systemName: symbol)
				.foregroundStyle(.secondary)
				.accessibilityHidden(true)
			VStack(alignment: .leading, spacing: 2) {
				Text(verbatim: title)
				if !detail.isEmpty {
					Text(verbatim: detail)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
				}
			}
			Spacer()
			Button(String.localized(.appUI.savedPasswords.edit), action: edit)
				.disabled(store.isSaving)
			Button(String.localized(.appUI.savedPasswords.remove), role: .destructive, action: remove)
				.disabled(store.isSaving)
		}
		.padding(.vertical, 4)
		.settingsRow()
		.accessibilityElement(children: .contain)
	}

	internal static func message(_ failure: BrowserAutofillDataFailure) -> String {
		switch failure {
		case .unavailable: String.localized(.appUI.autofill.unavailable)
		case .invalid: String.localized(.appUI.autofill.invalid)
		case .notFound: String.localized(.appUI.autofill.notFound)
		case .busy: String.localized(.appUI.autofill.busy)
		case .disabled: String.localized(.appUI.autofill.disabled)
		}
	}
}

extension AutofillDataFeature.CardEditor: Identifiable {}

private struct AutofillAddressEditor: View {
	internal let store: StoreOf<AutofillDataFeature>

	internal var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: store.addressEditor?.id.isEmpty ?? true ? .appUI.autofill.addAddress : .appUI.autofill.editAddress)
				.font(.title3.bold())
			VStack(alignment: .leading, spacing: 10) {
				field(String.localized(.appUI.autofill.name), \.name)
				field(String.localized(.appUI.autofill.organization), \.organization)
				field(String.localized(.appUI.autofill.street), \.street)
				HStack(spacing: 10) {
					field(String.localized(.appUI.autofill.city), \.city)
					field(String.localized(.appUI.autofill.state), \.state)
				}
				HStack(spacing: 10) {
					field(String.localized(.appUI.autofill.zip), \.zip)
					field(String.localized(.appUI.autofill.country), \.country)
				}
				field(String.localized(.appUI.autofill.phone), \.phone)
				field(String.localized(.appUI.autofill.email), \.email)
			}
			if let failure = store.failure {
				Text(verbatim: AutofillDataView.message(failure))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			AutofillEditorButtons(store: store, save: .saveAddress)
		}
		.padding(20)
		.frame(width: 460)
		.arxModalSheet()
		.settingsControls()
	}

	private func field(
		_ title: String,
		_ keyPath: WritableKeyPath<BrowserAutofillAddress, String>
	) -> some View {
		SettingsTextField(
			title,
			text: Binding(
				get: { store.addressEditor?[keyPath: keyPath] ?? "" },
				set: { value in
					guard var address = store.addressEditor else { return }
					address[keyPath: keyPath] = value
					store.send(.ui(.addressChanged(address)))
				}
			)
		)
	}
}

private struct AutofillCardEditor: View {
	internal let store: StoreOf<AutofillDataFeature>
	internal let numberField: BrowserPasswordFieldID
	internal let lastFour: String

	internal var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: lastFour.isEmpty ? .appUI.autofill.addCard : .appUI.autofill.editCard)
				.font(.title3.bold())
			VStack(alignment: .leading, spacing: 10) {
				SettingsFieldFrame(String.localized(.appUI.autofill.number)) {
					LentPasswordField(id: numberField, kind: .entry)
						.accessibilityLabel(Text(localized: .appUI.autofill.number))
				}
				if !lastFour.isEmpty {
					Text(localized: .appUI.autofill.keepNumber(lastFour))
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
						.padding(.horizontal, 12)
				}
				text(String.localized(.appUI.autofill.cardName), \.name)
				HStack(spacing: 10) {
					Picker(String.localized(.appUI.autofill.month), selection: number(\.month)) {
						ForEach(1...12, id: \.self) { Text(verbatim: String(format: "%02d", $0)).tag($0) }
					}
					Picker(String.localized(.appUI.autofill.year), selection: number(\.year)) {
						ForEach(years, id: \.self) { Text(verbatim: String($0)).tag($0) }
					}
				}
				text(String.localized(.appUI.autofill.nickname), \.nickname)
			}
			if let failure = store.failure {
				Text(verbatim: AutofillDataView.message(failure))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			AutofillEditorButtons(store: store, save: .saveCard)
		}
		.padding(20)
		.frame(width: 460)
		.arxModalSheet()
		.settingsControls()
	}

	private var years: [Int] {
		let current = Calendar(identifier: .gregorian).component(.year, from: .now)
		let saved = store.cardEditor?.year ?? current
		return Array(min(current, saved)...max(current + 15, saved))
	}

	private func text(
		_ title: String,
		_ keyPath: WritableKeyPath<AutofillDataFeature.CardEditor, String>
	) -> some View {
		SettingsTextField(
			title,
			text: Binding(
				get: { store.cardEditor?[keyPath: keyPath] ?? "" },
				set: { value in
					guard var editor = store.cardEditor else { return }
					editor[keyPath: keyPath] = value
					store.send(.ui(.cardChanged(editor)))
				}
			)
		)
	}

	private func number(_ keyPath: WritableKeyPath<AutofillDataFeature.CardEditor, Int>) -> Binding<Int> {
		Binding(
			get: { store.cardEditor?[keyPath: keyPath] ?? 1 },
			set: { value in
				guard var editor = store.cardEditor else { return }
				editor[keyPath: keyPath] = value
				store.send(.ui(.cardChanged(editor)))
			}
		)
	}
}

private struct AutofillEditorButtons: View {
	internal let store: StoreOf<AutofillDataFeature>
	internal let save: AutofillDataFeature.Action.UI

	internal var body: some View {
		HStack(spacing: ArxModalMetrics.buttonSpacing) {
			Spacer()
			ArxModalButton.cancel(String.localized(.appUI.savedPasswords.cancel)) {
				store.send(.ui(.cancelEditor))
			}
			ArxModalButton(String.localized(.appUI.savedPasswords.save)) {
				store.send(.ui(save))
			}
			.disabled(store.isSaving)
		}
	}
}
