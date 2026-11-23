import Foundation

// MARK: - What's New

extension AppUpdaterClient {
	/// What the first launch after an update shows (DEV-888): the notes the appcast gave for the
	/// build now running, and a link to the full release notes in the manual.
	public struct WhatsNew: Equatable, Sendable {
		/// The marketing version, such as `0.3.0`.
		public var version: String

		/// The build number, `CFBundleVersion`.
		public var build: String

		/// The appcast's release notes for this build, as plain text or Markdown. `nil` when Arx
		/// was updated another way, such as from a downloaded disk image, and never saw them.
		public var notes: String?

		/// The full release notes.
		public var fullNotesURL: URL

		public init(
			version: String,
			build: String,
			notes: String?,
			fullNotesURL: URL
		) {
			self.version = version
			self.build = build
			self.notes = notes
			self.fullNotesURL = fullNotesURL
		}
	}

	/// The release notes of an update Sparkle found, kept until the launch that runs it.
	public struct ReleaseNotes: Codable, Equatable, Sendable {
		public var version: String
		public var build: String
		public var notes: String?
		public var fullNotesURL: URL?

		public init(
			version: String,
			build: String,
			notes: String?,
			fullNotesURL: URL?
		) {
			self.version = version
			self.build = build
			self.notes = notes
			self.fullNotesURL = fullNotesURL
		}
	}

	/// The manual's release notes page, used when the appcast names no full release notes.
	public static let releaseNotesPage: URL = URL(string: "https://manual.arx.capturecontext.dev/help/release-notes")!

	/// The longest release notes the sheet shows. Longer notes are cut at a line break and the
	/// link to the full notes covers the rest.
	public static let whatsNewNotesLimit: Int = 1_200

	/// What to show at this launch, or `nil` when this isn't the first launch of a newer build.
	///
	/// A first install, a relaunch of the same build and a downgrade show nothing. Notes are
	/// only used when they're for exactly this build.
	public static func whatsNew(
		currentVersion: String,
		currentBuild: String,
		lastLaunchedBuild: String?,
		pending: ReleaseNotes?
	) -> WhatsNew? {
		guard
			let lastLaunchedBuild,
			isUpgrade(candidate: currentBuild, current: lastLaunchedBuild)
		else { return nil }

		let matching: ReleaseNotes? = pending.flatMap { notes in
			notes.build.trimmingCharacters(in: .whitespacesAndNewlines)
				== currentBuild.trimmingCharacters(in: .whitespacesAndNewlines)
			? notes
			: nil
		}
		return WhatsNew(
			version: currentVersion,
			build: currentBuild,
			notes: matching?.notes.flatMap(shortNotes),
			fullNotesURL: matching?.fullNotesURL ?? releaseNotesPage
		)
	}

	/// Trimmed notes no longer than ``whatsNewNotesLimit``, cut at the last line break before it.
	internal static func shortNotes(_ notes: String) -> String? {
		let trimmed: String = notes.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty
		else { return nil }
		guard trimmed.count > whatsNewNotesLimit
		else { return trimmed }

		let prefix: Substring = trimmed.prefix(whatsNewNotesLimit)
		let cut: Substring = prefix.lastIndex(of: "\n").map { prefix[..<$0] } ?? prefix
		return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\n…"
	}

	/// Plain text from an appcast `<description>`. Markdown and plain text are kept; HTML loses
	/// its tags, with block ends and `<br>` turned into line breaks and common entities decoded.
	public static func releaseNotesText(
		_ description: String?,
		format: String?
	) -> String? {
		guard let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty
		else { return nil }

		switch format?.lowercased() {
		case "plain-text", "markdown":
			return description

		default:
			return plainText(fromHTML: description)
		}
	}

	internal static func plainText(fromHTML html: String) -> String? {
		var text: String = html
		let breaks: [String] = ["<br>", "<br/>", "<br />", "</p>", "</li>", "</h1>", "</h2>", "</h3>", "</h4>", "</div>"]
		for tag in breaks {
			text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
		}
		text = text.replacingOccurrences(of: "<li>", with: "• ", options: .caseInsensitive)
		text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
		let entities: [(String, String)] = [
			("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&"),
		]
		for (entity, character) in entities {
			text = text.replacingOccurrences(of: entity, with: character)
		}
		let lines: [String] = text
			.components(separatedBy: .newlines)
			.map { $0.trimmingCharacters(in: .whitespaces) }
		var collapsed: [String] = []
		for line in lines where !(line.isEmpty && (collapsed.last?.isEmpty ?? true)) {
			collapsed.append(line)
		}
		let result: String = collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
		return result.isEmpty ? nil : result
	}
}

// MARK: - Launch record

extension AppUpdaterClient {
	/// What Arx remembers between launches to know it was updated: the build that last ran and
	/// the notes of an update Sparkle found. Kept in the app's user defaults; holds no URLs of
	/// pages, only release metadata from the update feed.
	public struct LaunchRecord: Sendable {
		public static let lastLaunchedBuildKey: String = "ArxLastLaunchedBuild"
		public static let pendingReleaseNotesKey: String = "ArxPendingReleaseNotes"

		public var load: @Sendable (String) -> Data?
		public var loadString: @Sendable (String) -> String?
		public var save: @Sendable (String, Data?) -> Void
		public var saveString: @Sendable (String, String?) -> Void

		public init(
			load: @escaping @Sendable (String) -> Data?,
			loadString: @escaping @Sendable (String) -> String?,
			save: @escaping @Sendable (String, Data?) -> Void,
			saveString: @escaping @Sendable (String, String?) -> Void
		) {
			self.load = load
			self.loadString = loadString
			self.save = save
			self.saveString = saveString
		}

		/// The app's standard user defaults.
		public static var standard: Self {
			.init(
				load: { UserDefaults.standard.data(forKey: $0) },
				loadString: { UserDefaults.standard.string(forKey: $0) },
				save: { key, value in
					if let value { UserDefaults.standard.set(value, forKey: key) }
					else { UserDefaults.standard.removeObject(forKey: key) }
				},
				saveString: { key, value in
					if let value { UserDefaults.standard.set(value, forKey: key) }
					else { UserDefaults.standard.removeObject(forKey: key) }
				}
			)
		}

		/// Keeps the notes of an update Sparkle found, replacing older ones.
		public func remember(_ notes: ReleaseNotes) {
			save(Self.pendingReleaseNotesKey, try? JSONEncoder().encode(notes))
		}

		/// Records this launch and returns What's New if this is the first launch of a newer build.
		/// Notes for this build or an older one are used up; notes for a newer build stay.
		public func launch(
			version: String,
			build: String
		) -> WhatsNew? {
			let pending: ReleaseNotes? = load(Self.pendingReleaseNotesKey)
				.flatMap { try? JSONDecoder().decode(ReleaseNotes.self, from: $0) }
			let whatsNew: WhatsNew? = AppUpdaterClient.whatsNew(
				currentVersion: version,
				currentBuild: build,
				lastLaunchedBuild: loadString(Self.lastLaunchedBuildKey),
				pending: pending
			)
			saveString(Self.lastLaunchedBuildKey, build)
			if let pending, !AppUpdaterClient.isUpgrade(candidate: pending.build, current: build) {
				save(Self.pendingReleaseNotesKey, nil)
			}
			return whatsNew
		}
	}
}
