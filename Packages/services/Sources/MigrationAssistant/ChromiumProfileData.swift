import Foundation

// MARK: - History

/// Reads a Chromium profile's `History` database (DEV-845): `urls(url, title,
/// last_visit_time, hidden, visit_count, typed_count)`, where `last_visit_time` counts
/// microseconds from 1 January 1601 UTC. The counts seed the command bar's ranking (DEV-1015).
///
/// The database is locked while the browser runs, so callers read a private copy
/// (`FirefoxPlaces.withCopy`) and never open the browser's own file.
internal enum ChromiumHistory {
	/// Seconds between 1 January 1601 and 1 January 1970.
	internal static let epochOffset: TimeInterval = 11_644_473_600

	internal static func date(microsecondsSince1601 value: Int64) -> Date? {
		guard value > 0 else { return nil }

		return Date(timeIntervalSince1970: Double(value) / 1_000_000 - epochOffset)
	}

	/// One record per page at its latest visit, newest first. Hidden pages (subframes and
	/// redirects Chromium doesn't show in its history) and pages never visited are left out.
	internal static func records(
		_ database: SQLiteDatabase,
		profile: MigrationSourceProfile
	) throws -> [MigrationRecord] {
		guard try database.hasTable("urls") else { return [] }

		let visitCount = try database.column("visit_count", in: "urls", or: "1")
		let typedCount = try database.column("typed_count", in: "urls", or: "0")
		return try database.rows(
			"""
			SELECT url, title, last_visit_time, \(visitCount), \(typedCount)
			FROM urls
			WHERE hidden = 0 AND last_visit_time > 0
			ORDER BY last_visit_time DESC
			"""
		) { row in
			let url = row.text(0) ?? ""
			return .init(
				sourceItemID: "history:" + profile.id + "/" + url,
				category: .history,
				title: row.text(1) ?? "",
				url: url,
				profile: profile,
				lastVisited: date(microsecondsSince1601: row.int(2)),
				visitCount: Int(row.int(3)),
				typedCount: Int(row.int(4))
			)
		}
	}
}

// MARK: - Extensions

/// Lists a Chromium profile's installed extensions from `extensions.settings` in its
/// `Preferences` and `Secure Preferences` (DEV-845). Only what Chromium recorded is read:
/// no extension is loaded or run.
///
/// Component extensions (the browser's own) and ones installed by default are left out.
/// An extension came from the Chrome Web Store when Chromium says so (`from_webstore`,
/// or the `FROM_WEBSTORE` creation flag) and it was installed as a packed extension.
internal enum ChromiumExtensionSettings {
	/// Chromium's `ManifestLocation`: the ones a user installs.
	internal enum Location: Int {
		case internalInstall = 1
		case externalPreference = 2
		case externalRegistry = 3
		case unpacked = 4
		case component = 5
		case externalPreferenceDownload = 6
		case externalPolicyDownload = 7
		case commandLine = 8
		case externalPolicy = 9
		case externalComponent = 10
	}

	/// `Extension::FROM_WEBSTORE`.
	internal static let fromWebStoreFlag: Int = 1 << 3

	/// - Parameters:
	///   - localizedName: resolves a `__MSG_name__` manifest name for an extension ID and
	///     version, from the extension's own `_locales`.
	internal static func extensions(
		preferences: Data?,
		securePreferences: Data?,
		profile: MigrationSourceProfile,
		localizedName: (
			_ id: String,
			_ version: String?,
			_ key: String,
			_ defaultLocale: String?
		) -> String? = { _, _, _, _ in nil }
	) -> [MigrationIssue.Extension] {
		var settings: [String: [String: Any]] = [:]

		// Chromium moves protected settings into Secure Preferences; its copy wins.
		for data in [preferences, securePreferences] {
			guard
				let data,
				let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				let values = (root["extensions"] as? [String: Any])?["settings"] as? [String: Any]
			else { continue }

			for (id, value) in values {
				guard let value = value as? [String: Any] else { continue }

				settings[id, default: [:]].merge(value) { _, secure in secure }
			}
		}

		return settings.keys.sorted().compactMap { id in
			guard
				validID(id),
				let entry = settings[id],
				let location = (entry["location"] as? Int).flatMap(Location.init(rawValue:)),
				location != .component,
				location != .externalComponent,
				entry["was_installed_by_default"] as? Bool != true,
				entry["was_installed_by_oem"] as? Bool != true
			else { return nil }

			let manifest = entry["manifest"] as? [String: Any] ?? [:]
			let version = manifest["version"] as? String
			let flags = entry["creation_flags"] as? Int ?? 0
			let fromWebStore = (entry["from_webstore"] as? Bool == true || flags & fromWebStoreFlag != 0)
			&& location != .unpacked
			&& location != .commandLine

			var name = (manifest["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
			if let key = messageKey(name) {
				name = localizedName(id, version, key, manifest["default_locale"] as? String) ?? ""
			}
			return .init(
				id: id,
				name: name.isEmpty ? id : name,
				fromWebStore: fromWebStore,
				version: version,
				profile: profile
			)
		}
	}

	/// The key of a `__MSG_key__` placeholder, or nil for a plain name.
	internal static func messageKey(_ name: String) -> String? {
		guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), name.count > 8 else { return nil }

		return String(name.dropFirst(6).dropLast(2))
	}

	/// A placeholder's message from `_locales/<locale>/messages.json`, matching keys
	/// without regard to case as Chromium does.
	internal static func message(
		_ key: String,
		in data: Data?
	) -> String? {
		guard
			let data,
			let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else { return nil }

		let entry = messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
		let message = (entry as? [String: Any])?["message"] as? String
		return message?.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Chromium's IDs: 32 letters from a to p.
	internal static func validID(_ id: String) -> Bool {
		id.count == 32 && id.allSatisfy { ("a"..."p").contains($0) }
	}
}
