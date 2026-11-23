import AppUI
import Foundation
import SwiftUI
import WorkspaceSync

public enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
	case arx
	case general
	case profiles

	/// iCloud Sync (DEV-1336), a tab of its own since the Arx pane's section grew.
	case sync
	case assistant
	case links
	case shortcuts
	case appearance
	case privacy
	case developer
	case advanced
	case experimental

	public var id: Self { self }

	/// The categories Settings lists.
	public static var available: [Self] {
		allCases.filter(\.isListed)
	}

	/// Experimental stays out of the sidebar and search while it has no experiments, and Sync
	/// while the `ARX_ICLOUD_SYNC` feature flag is off.
	internal var isListed: Bool {
		switch self {
		case .experimental: false
		case .sync: ICloudSyncFeatureFlag.isOn(environment: ProcessInfo.processInfo.environment)
		default: true
		}
	}

	public var title: String {
		switch self {
		case .arx: String.localized(.appUI.settings.category.arx)
		case .general: String.localized(.appUI.settings.category.general)
		case .profiles: String.localized(.appUI.settings.category.profiles)
		case .sync: String.localized(.appUI.settings.category.sync)
		case .assistant: String.localized(.appUI.settings.category.assistant)
		case .links: String.localized(.appUI.settings.category.links)
		case .shortcuts: String.localized(.appUI.settings.category.shortcuts)
		case .appearance: String.localized(.appUI.settings.category.appearance)
		case .privacy: String.localized(.appUI.settings.category.privacy)
		case .developer: String.localized(.appUI.settings.category.developer)
		case .advanced: String.localized(.appUI.settings.category.advanced)
		case .experimental: String.localized(.appUI.settings.category.experimental)
		}
	}

	public var detail: String {
		switch self {
		case .arx: String.localized(.appUI.settings.categoryDetail.arx)
		case .general: String.localized(.appUI.settings.categoryDetail.general)
		case .profiles: String.localized(.appUI.settings.categoryDetail.profiles)
		case .sync: String.localized(.appUI.settings.categoryDetail.sync)
		case .assistant: String.localized(.appUI.settings.categoryDetail.assistant)
		case .links: String.localized(.appUI.settings.categoryDetail.links)
		case .shortcuts: String.localized(.appUI.settings.categoryDetail.shortcuts)
		case .appearance: String.localized(.appUI.settings.categoryDetail.appearance)
		case .privacy: String.localized(.appUI.settings.categoryDetail.privacy)
		case .developer: String.localized(.appUI.settings.categoryDetail.developer)
		case .advanced: String.localized(.appUI.settings.categoryDetail.advanced)
		case .experimental: String.localized(.appUI.settings.categoryDetail.experimental)
		}
	}

	internal var tint: Color {
		switch self {
		case .arx: .blue
		case .general: .gray
		case .profiles: .indigo
		case .sync: .cyan
		case .assistant: .purple
		case .links: .teal
		case .shortcuts: .gray
		case .appearance: .pink
		case .privacy: .blue
		case .developer: .orange
		case .advanced: .gray
		case .experimental: .green
		}
	}

	/// The Arx pane shows the Arx mark: it stands for Arx itself, not a website (DEV-829).
	public var glyph: ArxGlyph {
		switch self {
		case .arx: .arxMark
		case .general: .symbol("gearshape.fill")
		case .profiles: .symbol("person.crop.circle.fill")
		case .sync: .symbol("icloud.fill")
		case .assistant: .symbol("sparkles")
		case .links: .symbol("rectangle.on.rectangle")
		case .shortcuts: .symbol("command")
		case .appearance: .symbol("paintpalette.fill")
		case .privacy: .symbol("hand.raised.fill")
		case .developer: .symbol("hammer.fill")
		case .advanced: .symbol("slider.horizontal.3")
		case .experimental: .symbol("flask.fill")
		}
	}
}

/// A sheet opened from a pane's row. Lists that grow open as pages instead (DEV-1114).
public enum SettingsPanel: String, Identifiable, Sendable {
	case previews

	public var id: Self { self }

	internal var title: String {
		switch self {
		case .previews: String.localized(.appUI.settings.previews)
		}
	}
}
