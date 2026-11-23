import Foundation

/// The Arx repository's GitHub "new issue" page for Help › Report a Problem (DEV-887).
///
/// The page opens the issue form `.github/ISSUE_TEMPLATE/problem-report.yml`, prefilled through
/// query parameters with the person's description, the versions and, when Arx saved a report
/// file for them to attach, that file's name. Nothing else goes in the address: no
/// diagnostics, crash reports, paths, URLs or page content. Filing the issue needs the
/// person's GitHub account, which is also how the maintainers reach them.
public enum GitHubIssue {
	/// The Arx repository, `owner/name`.
	public static let repository: String = "capturecontext/arx-browser"

	/// The issue form's file name in `.github/ISSUE_TEMPLATE`.
	public static let template: String = "problem-report.yml"

	/// The issue form's field IDs. `.github/ISSUE_TEMPLATE/problem-report.yml` must keep them.
	public enum Field {
		public static let description: String = "description"
		public static let app: String = "arx-version"
		public static let engine: String = "engine-version"
		public static let system: String = "macos-version"
		public static let attachment: String = "attachment"
	}

	/// GitHub answers longer addresses with an error, so a long description is cut to fit;
	/// the saved report file keeps all of it.
	public static let addressLimit: Int = 8_000

	/// Marks a description cut to fit the address.
	public static let cutMarker: String = "\n\n[…]"

	/// The new issue page for a report. `attachment` is the saved report file's name, never its
	/// path, which names the person's home folder.
	public static func newIssueURL(
		description: String,
		environment: DiagnosticsEnvironment,
		attachment: String?,
		repository: String = repository
	) -> URL {
		let (base, room) = prefix(environment: environment, attachment: attachment, repository: repository)
		let text: String = fitting(description, room: room)
		return URL(string: base + query([(Field.description, text)]))!
	}

	/// Whether the whole description fits in the address; when it doesn't, Report a Problem saves
	/// the report as a file so nothing the person wrote is lost.
	public static func fits(
		description: String,
		environment: DiagnosticsEnvironment
	) -> Bool {
		encode(description).count <= prefix(environment: environment, attachment: nil, repository: repository).room
	}

	/// The address up to the description, and the room left for the encoded description.
	private static func prefix(
		environment: DiagnosticsEnvironment,
		attachment: String?,
		repository: String
	) -> (base: String, room: Int) {
		let fixed: [(String, String)] = [
			("template", template),
			(Field.app, appVersion(environment)),
			(Field.engine, engineVersion(environment)),
			(Field.system, "\(environment.macOSVersion), \(environment.architecture)"),
		] + (attachment.map { [(Field.attachment, $0)] } ?? [])
		let base: String = "https://github.com/\(repository)/issues/new?" + query(fixed) + "&"

		// "description=" comes before the encoded description.
		return (base, addressLimit - base.count - Field.description.count - 1)
	}

	public static func appVersion(_ environment: DiagnosticsEnvironment) -> String {
		"\(environment.appVersion) (\(environment.appBuild))"
	}

	public static func engineVersion(_ environment: DiagnosticsEnvironment) -> String {
		let helium: String = environment.engineVersion.map { "Helium \($0)" } ?? "Helium unknown"
		return environment.chromiumVersion.map { "\(helium), Chromium \($0)" } ?? helium
	}

	// MARK: - Encoding

	/// RFC 3986's unreserved characters; everything else is percent-encoded, so `&`, `=`, `+`
	/// and `#` in a description can't change the address.
	private static let unreserved: CharacterSet = .init(
		charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	)

	private static func encode(_ value: String) -> String {
		value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
	}

	private static func query(_ items: [(String, String)]) -> String {
		items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
	}

	/// The description, or as much of it as fits in `room` encoded characters, with ``cutMarker``.
	private static func fitting(
		_ description: String,
		room: Int
	) -> String {
		guard encode(description).count > room
		else { return description }

		let budget: Int = room - encode(cutMarker).count
		var used: Int = 0
		var kept: String = ""
		for character in description {
			let size: Int = encode(String(character)).count
			guard used + size <= budget
			else { break }

			used += size
			kept.append(character)
		}
		return kept + cutMarker
	}
}
