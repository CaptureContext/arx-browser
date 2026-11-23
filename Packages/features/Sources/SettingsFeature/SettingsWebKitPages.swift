import BrowserCore
import Foundation
import _ComposableArchitecture

/// Settings › Advanced › WebKit (DEV-877): the switch and the sites that open in WebKit pages,
/// where protected video and music play, and how protected media plays (DEV-1144). A shared
/// key: AppFeature saves the edits.
@Reducer
internal struct SettingsWebKitPages {
	internal typealias State = SettingsFeature.State
	internal typealias Action = SettingsFeature.Action

	internal var body: some ReducerOf<Self> {
		Pullback(\.ui.webKitPagesEnabled) { state, isEnabled in
			state.$webKitPages.withLock { $0.isEnabled = isEnabled }
			return .none
		}

		Pullback(\.ui.addWebKitSite) { state, input in
			guard let site = WebKitPagePreferences.site(from: input) else { return .none }
			state.$webKitPages.withLock { preferences in
				guard !preferences.sites.contains(site) else { return }
				preferences.sites.append(site)
				preferences.declinedSites.removeAll { WebKitPagePreferences.covers($0, host: site) }
			}
			return .none
		}

		Pullback(\.ui.editWebKitSite) { state, value in
			let (old, input) = value
			guard let site = WebKitPagePreferences.site(from: input) else { return .none }
			state.$webKitPages.withLock { preferences in
				guard let index = preferences.sites.firstIndex(of: old) else { return }
				if site != old, preferences.sites.contains(site) {
					preferences.sites.remove(at: index)
				} else {
					preferences.sites[index] = site
				}
			}
			return .none
		}

		Pullback(\.ui.removeWebKitSite) { state, site in
			state.$webKitPages.withLock { $0.sites.removeAll { $0 == site } }
			return .none
		}

		Pullback(\.ui.restoreWebKitSites) { state in
			state.$webKitPages.withLock { $0.restoreDefaults() }
			return .none
		}

		Pullback(\.ui.protectedMediaPlayback) { state, playback in
			state.$webKitPages.withLock { $0.protectedMedia = playback }
			return .none
		}

		Pullback(\.ui.widevineAnswer) { state, isOn in
			state.$webKitPages.withLock { $0.answersWidevine = isOn }
			return .none
		}
	}
}
