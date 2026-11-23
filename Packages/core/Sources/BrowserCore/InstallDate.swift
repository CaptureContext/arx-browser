import Foundation

/// When this Arx was first installed on this Mac (DEV-1323): the identity card's "Member since".
///
/// Once the person claims a member number, the sign-in sends that day (only the day) to Arx's
/// server, which keeps the earliest day any of the account's Macs sent and returns it; from then
/// on the card shows the account's day (``shown(member:installedAt:)``), so every Mac agrees.
///
/// It's recorded once, at the first launch that has none, in ``BrowserPreferences/installedAt``,
/// which lives in the edition's workspace beside its profiles. Arx, Arx Dev and Arx Preview each
/// keep their own, as they keep their own data folders. It isn't synced through iCloud and
/// isn't part of the member number; only its day goes to Arx's server, with a member number's
/// sign-in.
///
/// An install from before this was recorded has no date yet, so the first launch takes the
/// earliest evidence already on the Mac: when the edition's data folder, or the Chromium profile
/// folder inside it, was created. Both appear at the first launch and stay until the person
/// deletes them. Today is used only when there's no evidence, or when the evidence is in the
/// future (a clock that was wrong).
public enum InstallDate {
	/// The one date the identity card's Member since shows: the account's day from Arx's server
	/// once this Mac has a member number and the server sent one, else this Mac's own install
	/// date. Signing in on a second Mac hands the card over to the account's earlier day.
	public static func shown(
		member: MemberNumber?,
		installedAt: Date?
	) -> Date? {
		member?.memberSinceDate ?? installedAt
	}

	/// `date` as the `yyyy-MM-dd` day it was on this Mac, the only part of the install date the
	/// member number's sign-in sends (DEV-1323): no time of day, no time zone.
	public static func dayText(
		_ date: Date,
		timeZone: TimeZone = .current
	) -> String {
		var calendar: Calendar = .init(identifier: .gregorian)
		calendar.timeZone = timeZone
		let parts: DateComponents = calendar.dateComponents([.year, .month, .day], from: date)
		return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
	}

	/// The date to keep: the one `recorded` already, else the earliest `evidence` that isn't later
	/// than `now`, else `now`.
	public static func resolved(
		recorded: Date?,
		evidence: [Date],
		now: Date
	) -> Date {
		if let recorded { return recorded }

		return evidence.filter { $0 <= now }.min() ?? now
	}

	/// The folders whose creation dates are evidence of an earlier install: the edition's data
	/// folder and the Chromium profile folder in it.
	public static func evidenceFolders(
		edition: ArxEdition,
		home: URL
	) -> [URL] {
		let support: URL = edition.applicationSupport(home: home)
		return [support, support.appending(path: "Browser", directoryHint: .isDirectory)]
	}

	/// The creation dates of the `folders` that exist. Reads only their metadata.
	public static func creationDates(
		of folders: [URL],
		fileManager: FileManager = .default
	) -> [Date] {
		folders.compactMap { folder in
			(try? fileManager.attributesOfItem(atPath: folder.path(percentEncoded: false)))?[.creationDate] as? Date
		}
	}
}
