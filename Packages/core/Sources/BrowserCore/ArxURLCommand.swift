import Foundation

/// An `arx://` address another app opens to drive Arx: the Shortcuts app, Raycast, scripts
/// and `open` (DEV-929). Only these verbs are taken from outside Arx; any other `arx://`
/// address, such as `arx://chat` or `arx://version`, is Arx's own and is ignored when it
/// comes from another app.
///
/// - `arx://open?url=<web address>[&space=<name or ID>][&profile=<name or ID>][&little=1]`
/// - `arx://little[?url=<web address>][&space=<name or ID>]`
/// - `arx://space?name=<name or ID>`
public enum ArxURLCommand: Equatable, Sendable {
	case open(URL, space: String?, profile: String?)
	case littleArx(URL?, space: String?)
	case switchSpace(String)

	/// Nil for an address that isn't one of the verbs above, or whose page isn't http(s).
	public init?(_ url: URL) {
		guard
			url.scheme?.lowercased() == "arx",
			let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
			components.user == nil,
			components.password == nil
		else { return nil }

		var values: [String: String] = [:]
		for item in components.queryItems ?? [] {
			guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
			else { continue }

			// The first value wins; a repeated name can't override it.
			if values[item.name] == nil { values[item.name] = value }
		}
		let page = values["url"].map(Self.webPage)

		switch components.host?.lowercased() {
		case "open":
			guard let page, let page else { return nil }
			if ["1", "true", "yes"].contains(values["little"]?.lowercased()) {
				self = .littleArx(page, space: values["space"])
			} else {
				self = .open(page, space: values["space"], profile: values["profile"])
			}

		case "little":
			if let page, page == nil { return nil }
			self = .littleArx(page ?? nil, space: values["space"])

		case "space":
			guard let name = values["name"] ?? values["space"] else { return nil }
			self = .switchSpace(name)

		default:
			return nil
		}
	}

	/// An http(s) address with a host and no credentials, else nil.
	private static func webPage(_ text: String) -> URL? {
		guard
			text.utf8.count <= 32_768,
			let url = URL(string: text, encodingInvalidCharacters: false),
			let scheme = url.scheme?.lowercased(),
			["http", "https"].contains(scheme),
			url.host() != nil,
			url.user() == nil,
			url.password() == nil
		else { return nil }

		return url
	}
}

extension BrowserOrganization {
	/// The space `reference` names: its ID, else its name, ignoring case, in `profile` when one
	/// is named the same way (DEV-929).
	public func space(
		named reference: String,
		in profile: Profile.ID? = nil
	) -> Space? {
		let candidates = spaces.filter { profile == nil || $0.profileID == profile }
		if let id = UUID(uuidString: reference), let space = candidates.first(where: { $0.id.rawValue == id }) {
			return space
		}
		return candidates.first { $0.name.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
	}

	/// The profile `reference` names: its ID, else its name, ignoring case (DEV-929).
	public func profile(named reference: String) -> Profile? {
		if let id = UUID(uuidString: reference), let profile = profiles.first(where: { $0.id.rawValue == id }) {
			return profile
		}
		return profiles.first { $0.name.compare(reference, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
	}
}
