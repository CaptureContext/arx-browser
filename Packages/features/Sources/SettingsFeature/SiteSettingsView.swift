import AppUI
import BrowserCore
import SwiftUI
import _ComposableArchitecture

/// One profile's site permissions and page zoom (DEV-716), opened from its Profiles page.
public struct SiteSettingsView: View {
	@Bindable
	public var store: StoreOf<SiteSettingsFeature>

	public init(store: StoreOf<SiteSettingsFeature>) {
		self.store = store
	}

	public var body: some View {
		ArxModalScaffold(contentPadding: SettingsSheetMetrics.contentPadding) {
			SettingsNavigationBar(
				.close { store.send(.ui(.done)) },
				title: String.localized(.appUI.siteSettings.title),
				trail: [SettingsCategory.profiles.title, store.profileName]
			) {
				ArxHeaderSearch(
					String.localized(.appUI.siteSettings.search),
					query: $store.query.sending(\.ui.queryChanged)
				)
			}
		} content: {
			VStack(alignment: .leading, spacing: 18) {
				header
				defaults
				sites
				zoom
				SiteSettingsDevicesSection(store: store)
				if store.settings.isTruncated {
					Text(localized: .appUI.siteSettings.truncated)
						.font(SettingsTypography.caption)
						.foregroundStyle(.secondary)
				}
			}
		} footer: {
			if store.notice != nil {
				footer
			}
		}
		.font(SettingsTypography.body)
		.frame(width: SettingsSheetMetrics.width, height: 620)
		.disabled(store.isApplying)
		.task { store.send(.ui(.appeared)) }
		.sheet(
			item: Binding(
				get: { store.permissionDraft },
				set: { if $0 == nil { store.send(.ui(.cancelPermissionDraft)) } }
			)
		) { draft in
			SitePermissionDraftView(store: store, draft: draft)
		}
		.sheet(
			item: Binding(
				get: { store.zoomDraft },
				set: { if $0 == nil { store.send(.ui(.cancelZoomDraft)) } }
			)
		) { draft in
			SiteZoomDraftView(store: store, draft: draft)
		}
	}

	/// What the sheet holds, under the bar's title.
	private var header: some View {
		Text(localized: .appUI.siteSettings.subtitle(store.profileName))
			.foregroundStyle(.secondary)
	}

	private var defaults: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(localized: .appUI.siteSettings.defaults)
				.font(SettingsTypography.heading)
			Text(localized: .appUI.siteSettings.defaultsDetail)
				.font(SettingsTypography.caption)
				.foregroundStyle(.secondary)
			SettingsCard {
				ForEach(SitePermission.allCases, id: \.self) { permission in
					if permission != SitePermission.allCases.first { Divider() }
					let current = store.settings.defaultSetting(for: permission)

					// The label leads and the pop-up trails, so the pop-ups line up down the card.
					HStack {
						Text(verbatim: Self.name(permission))
						Spacer(minLength: 16)
						if current?.isManaged == true {
							managedBadge
						}
						Picker(
							Self.name(permission),
							selection: Binding(
								get: { current?.setting ?? permission.defaultSettings[0] },
								set: { store.send(.ui(.apply(.setPermission(origin: nil, permission, $0)))) }
							)
						) {
							ForEach(permission.defaultSettings, id: \.self) { setting in
								Text(verbatim: Self.name(setting)).tag(setting)
							}
						}
						.labelsHidden()
						.fixedSize()
						.disabled(current == nil || current?.isManaged == true)
					}
					.padding(.vertical, 4)
				}
			}
		}
	}

	@ViewBuilder
	private var sites: some View {
		let visible = store.visibleSites
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(localized: .appUI.siteSettings.sites)
					.font(SettingsTypography.heading)
				Spacer()
				Button(String.localized(.appUI.siteSettings.addPermission)) {
					store.send(.ui(.addPermission))
				}
			}
			if visible.isEmpty {
				Text(
					localized: store.isLoading
					? .appUI.siteSettings.loading
					: store.settings.exceptions.isEmpty ? .appUI.siteSettings.empty : .appUI.siteSettings.noMatches
				)
				.foregroundStyle(.secondary)
				.frame(maxWidth: .infinity, minHeight: 48)
			} else {
				SettingsCard {
					ForEach(visible) { site in
						if site.id != visible.first?.id { Divider() }
						SitePermissionsRow(store: store, site: site)
					}
				}
			}
		}
	}

	private var zoom: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Text(localized: .appUI.siteSettings.zoom)
					.font(SettingsTypography.heading)
				Spacer()
				Button(String.localized(.appUI.siteSettings.addZoom)) {
					store.send(.ui(.addZoom))
				}
			}
			SettingsCard {
				HStack {
					Text(localized: .appUI.siteSettings.defaultZoom)
					Spacer(minLength: 16)
					Picker(
						String.localized(.appUI.siteSettings.defaultZoom),
						selection: Binding(
							get: { Self.closest(store.settings.defaultZoom) },
							set: { store.send(.ui(.apply(.setZoom(host: nil, factor: $0)))) }
						)
					) {
						ForEach(SiteSettings.zoomFactors, id: \.self) { factor in
							Text(verbatim: Self.percent(factor)).tag(factor)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
				.padding(.vertical, 4)
				ForEach(store.visibleZoom, id: \.host) { zoom in
					Divider()
					HStack {
						Text(verbatim: zoom.host)
							.lineLimit(1)
							.truncationMode(.middle)
						Spacer()
						Picker(
							String.localized(.appUI.siteSettings.zoomFor(zoom.host)),
							selection: Binding(
								get: { Self.closest(zoom.factor) },
								set: { store.send(.ui(.apply(.setZoom(host: zoom.host, factor: $0)))) }
							)
						) {
							ForEach(SiteSettings.zoomFactors, id: \.self) { factor in
								Text(verbatim: Self.percent(factor)).tag(factor)
							}
						}
						.labelsHidden()
						.fixedSize()
						Button {
							store.send(.ui(.apply(.setZoom(host: zoom.host, factor: nil))))
						} label: {
							Image(systemName: "minus.circle")
						}
						.buttonStyle(.arx(.plain, size: .small))
						.help(String.localized(.appUI.siteSettings.remove))
						.accessibilityLabel(String.localized(.appUI.siteSettings.removeZoom(zoom.host)))
					}
					.padding(.vertical, 4)
				}
			}
		}
	}

	private var footer: some View {
		HStack(alignment: .firstTextBaseline) {
			if let notice = store.notice {
				Text(verbatim: Self.message(notice))
					.foregroundStyle(.red)
					.font(SettingsTypography.caption)
			}
			Spacer(minLength: 0)
		}
	}

	fileprivate var managedBadge: some View {
		Text(localized: .appUI.siteSettings.managed)
			.font(SettingsTypography.caption)
			.foregroundStyle(.secondary)
	}

	internal static func name(_ permission: SitePermission) -> String {
		switch permission {
		case .camera: String.localized(.appUI.siteSettings.permission.camera)
		case .microphone: String.localized(.appUI.siteSettings.permission.microphone)
		case .location: String.localized(.appUI.siteSettings.permission.location)
		case .notifications: String.localized(.appUI.siteSettings.permission.notifications)
		case .popups: String.localized(.appUI.siteSettings.permission.popups)
		case .clipboard: String.localized(.appUI.siteSettings.permission.clipboard)
		}
	}

	internal static func name(_ setting: SitePermissionSetting) -> String {
		switch setting {
		case .allow: String.localized(.appUI.siteSettings.setting.allow)
		case .block: String.localized(.appUI.siteSettings.setting.block)
		case .ask: String.localized(.appUI.siteSettings.setting.ask)
		}
	}

	internal static func message(_ failure: SiteSettingsFailure) -> String {
		switch failure {
		case .unavailable: String.localized(.appUI.siteSettings.error.unavailable)
		case .invalid: String.localized(.appUI.siteSettings.error.invalid)
		case .managed: String.localized(.appUI.siteSettings.error.managed)
		case .failed: String.localized(.appUI.siteSettings.error.failed)
		}
	}

	internal static func percent(_ factor: Double) -> String {
		factor.formatted(.percent.precision(.fractionLength(0)))
	}

	/// The offered factor nearest a stored one, so a picker always has a selection.
	internal static func closest(_ factor: Double) -> Double {
		SiteSettings.zoomFactors.min { abs($0 - factor) < abs($1 - factor) } ?? 1
	}
}

private struct SitePermissionsRow: View {
	internal let store: StoreOf<SiteSettingsFeature>
	internal let site: SiteSettingsFeature.Site

	internal var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack {
				Image(systemName: "globe")
					.foregroundStyle(.secondary)
					.accessibilityHidden(true)
				Text(verbatim: site.origin)
					.lineLimit(1)
					.truncationMode(.middle)
				Spacer()
				Button(String.localized(.appUI.siteSettings.removeSite)) {
					store.send(.ui(.removeSite(site.origin)))
				}
				.disabled(site.exceptions.allSatisfy(\.isManaged))
			}
			ForEach(site.exceptions, id: \.permission) { exception in
				HStack {
					Text(verbatim: SiteSettingsView.name(exception.permission))
						.foregroundStyle(.secondary)
						.padding(.leading, 26)
					Spacer()
					if exception.isManaged {
						Text(localized: .appUI.siteSettings.managed)
							.font(SettingsTypography.caption)
							.foregroundStyle(.secondary)
					}
					Picker(
						String.localized(.appUI.siteSettings.settingFor(SiteSettingsView.name(exception.permission), site.origin)),
						selection: Binding(
							get: { exception.setting },
							set: { store.send(.ui(.apply(.setPermission(origin: site.origin, exception.permission, $0)))) }
						)
					) {
						ForEach(Self.choices(exception), id: \.self) { setting in
							Text(verbatim: SiteSettingsView.name(setting)).tag(setting)
						}
					}
					.labelsHidden()
					.fixedSize()
					.disabled(exception.isManaged || SiteSettings.origin(site.origin) != site.origin)
					Button {
						store.send(.ui(.apply(.setPermission(origin: site.origin, exception.permission, nil))))
					} label: {
						Image(systemName: "minus.circle")
					}
					.buttonStyle(.arx(.plain, size: .small))
					.disabled(exception.isManaged)
					.help(String.localized(.appUI.siteSettings.remove))
					.accessibilityLabel(
						String.localized(.appUI.siteSettings.removeSetting(SiteSettingsView.name(exception.permission), site.origin))
					)
				}
			}
		}
		.padding(.vertical, 4)
		.accessibilityElement(children: .contain)
	}

	/// What the site may be set to, keeping an `ask` Chromium stored even where Settings
	/// wouldn't offer it.
	private static func choices(_ exception: SitePermissionException) -> [SitePermissionSetting] {
		let offered = exception.permission.siteSettings
		return offered.contains(exception.setting) ? offered : offered + [exception.setting]
	}
}

private struct SitePermissionDraftView: View {
	internal let store: StoreOf<SiteSettingsFeature>
	internal let draft: SiteSettingsFeature.PermissionDraft

	internal var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: .appUI.siteSettings.addPermissionTitle)
				.font(.title3.bold())
			SettingsTextField(
				String.localized(.appUI.siteSettings.site),
				text: Binding(
					get: { store.permissionDraft?.origin ?? "" },
					set: { update { $0.origin = $1 }($0) }
				),
				prompt: String.localized(.appUI.siteSettings.sitePlaceholder)
			)
			SettingsSection {
				SettingsRow(String.localized(.appUI.siteSettings.permissionLabel)) {
					Picker(
						String.localized(.appUI.siteSettings.permissionLabel),
						selection: Binding(
							get: { store.permissionDraft?.permission ?? .camera },
							set: { update { $0.permission = $1 }($0) }
						)
					) {
						ForEach(SitePermission.allCases, id: \.self) { permission in
							Text(verbatim: SiteSettingsView.name(permission)).tag(permission)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
				SettingsRow(String.localized(.appUI.siteSettings.settingLabel)) {
					Picker(
						String.localized(.appUI.siteSettings.settingLabel),
						selection: Binding(
							get: { store.permissionDraft?.setting ?? .allow },
							set: { update { $0.setting = $1 }($0) }
						)
					) {
						ForEach((store.permissionDraft?.permission ?? .camera).siteSettings, id: \.self) { setting in
							Text(verbatim: SiteSettingsView.name(setting)).tag(setting)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
			}
			if let notice = store.notice {
				Text(verbatim: SiteSettingsView.message(notice))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer()
				ArxModalButton.cancel(String.localized(.appUI.siteSettings.cancel)) {
					store.send(.ui(.cancelPermissionDraft))
				}
				ArxModalButton(String.localized(.appUI.siteSettings.add)) {
					store.send(.ui(.savePermissionDraft))
				}
			}
		}
		.padding(20)
		.frame(width: 440)
		.arxModalSheet()
		.settingsControls()
	}

	private func update<Value>(
		_ change: @escaping (inout SiteSettingsFeature.PermissionDraft, Value) -> Void
	) -> (Value) -> Void {
		{ value in
			var next = store.permissionDraft ?? draft
			change(&next, value)
			store.send(.ui(.permissionDraftChanged(next)))
		}
	}
}

private struct SiteZoomDraftView: View {
	internal let store: StoreOf<SiteSettingsFeature>
	internal let draft: SiteSettingsFeature.ZoomDraft

	internal var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text(localized: .appUI.siteSettings.addZoomTitle)
				.font(.title3.bold())
			SettingsTextField(
				String.localized(.appUI.siteSettings.site),
				text: Binding(
					get: { store.zoomDraft?.host ?? "" },
					set: { update { $0.host = $1 }($0) }
				),
				prompt: String.localized(.appUI.siteSettings.sitePlaceholder)
			)
			SettingsSection {
				SettingsRow(String.localized(.appUI.siteSettings.zoomLabel)) {
					Picker(
						String.localized(.appUI.siteSettings.zoomLabel),
						selection: Binding(
							get: { store.zoomDraft?.factor ?? 1.25 },
							set: { update { $0.factor = $1 }($0) }
						)
					) {
						ForEach(SiteSettings.zoomFactors, id: \.self) { factor in
							Text(verbatim: SiteSettingsView.percent(factor)).tag(factor)
						}
					}
					.labelsHidden()
					.fixedSize()
				}
			}
			if let notice = store.notice {
				Text(verbatim: SiteSettingsView.message(notice))
					.font(SettingsTypography.caption)
					.foregroundStyle(.red)
			}
			HStack(spacing: ArxModalMetrics.buttonSpacing) {
				Spacer()
				ArxModalButton.cancel(String.localized(.appUI.siteSettings.cancel)) {
					store.send(.ui(.cancelZoomDraft))
				}
				ArxModalButton(String.localized(.appUI.siteSettings.add)) {
					store.send(.ui(.saveZoomDraft))
				}
			}
		}
		.padding(20)
		.frame(width: 440)
		.arxModalSheet()
		.settingsControls()
	}

	private func update<Value>(
		_ change: @escaping (inout SiteSettingsFeature.ZoomDraft, Value) -> Void
	) -> (Value) -> Void {
		{ value in
			var next = store.zoomDraft ?? draft
			change(&next, value)
			store.send(.ui(.zoomDraftChanged(next)))
		}
	}
}
