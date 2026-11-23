import Foundation

/// The number Arx's server gives an Apple account for the identity card (DEV-701),
/// written in the card's top-right corner. The same account gets the same number on every Mac.
///
/// Each Mac keeps its own copy, claimed with its own sign-in; it doesn't sync through iCloud.
public struct MemberNumber: Codable, Hashable, Sendable {
	/// The account's number, from 1.
	public var index: Int

	/// The UTC day the account first signed in, as the server sends it: `2026-11-18`. Kept as
	/// sent; the card's Member since is the install date on this Mac instead (DEV-1323).
	public var registeredOn: String

	/// The provider whose sign-in claimed it.
	public var provider: MemberSignInProvider

	/// The day the account has been a member since, as the server sends it (DEV-1323): the
	/// earliest install day any of its Macs sent, `2026-11-11`. `nil` from a server or a saved
	/// number from before it, when the card shows this Mac's own install date instead.
	public var memberSince: String?

	public init(
		index: Int,
		registeredOn: String,
		provider: MemberSignInProvider,
		memberSince: String? = nil
	) {
		self.index = index
		self.registeredOn = registeredOn
		self.provider = provider
		self.memberSince = memberSince
	}

	private enum CodingKeys: String, CodingKey {
		case index = "idx"
		case registeredOn
		case provider
		case memberSince
	}

	/// The registration day as a date at midnight UTC, or `nil` when the server's text isn't a
	/// `yyyy-MM-dd` day, which the client refuses.
	public var registrationDate: Date? {
		Self.day(registeredOn, in: Self.utcCalendar)
	}

	/// The server's member-since day as a date to show (DEV-1323): noon of that day on this Mac's
	/// calendar, so its month and year never move with the time zone. `nil` without one, or when
	/// the text isn't a `yyyy-MM-dd` day.
	public var memberSinceDate: Date? {
		guard let memberSince else { return nil }

		var calendar: Calendar = .init(identifier: .gregorian)
		calendar.timeZone = .current
		return Self.day(memberSince, in: calendar, hour: 12)
	}

	/// `yyyy-MM-dd` as that day in `calendar`, at `hour`.
	private static func day(
		_ text: String,
		in calendar: Calendar,
		hour: Int = 0
	) -> Date? {
		let parts = text.split(separator: "-", omittingEmptySubsequences: false)
		guard
			parts.count == 3,
			parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
			let year = Int(parts[0]),
			let month = Int(parts[1]),
			let day = Int(parts[2])
		else { return nil }

		let components: DateComponents = .init(
			calendar: calendar,
			timeZone: calendar.timeZone,
			year: year,
			month: month,
			day: day,
			hour: hour
		)
		guard components.isValidDate else { return nil }
		return components.date
	}

	private static let utcCalendar: Calendar = {
		var calendar: Calendar = .init(identifier: .gregorian)
		calendar.timeZone = .gmt
		return calendar
	}()
}

/// Who confirms the account that claims a member number. The server's own names.
public enum MemberSignInProvider: String, Codable, CaseIterable, Hashable, Sendable {
	/// The only one. Google's sign-in was removed (DEV-1323): a saved number that names it doesn't
	/// decode, and the card asks for a number again.
	case apple
}

/// Why claiming a member number didn't finish, in the words the card shows.
public enum MemberNumberFailure: Error, Equatable, Sendable {
	/// The person closed the sign-in. Nothing was sent.
	case cancelled

	/// Arx's server or the provider couldn't be reached.
	case offline

	/// The server answered but gave no number: the token was refused, too many tries, or the
	/// provider isn't turned on there.
	case refused

	/// The provider's sign-in failed for a reason of its own.
	case signInFailed

	/// This build can't sign in with that provider: no entitlement or no client ID.
	case unavailable
}
