import Foundation

/// Arx's own web addresses, kept in one place: the privacy policy that the feedback sheet and the
/// member card link to, and the backend that files feedback and gives accounts their numbers.
public enum ArxService {
	/// The privacy policy, linked beside Send Feedback's Include diagnostics and from the member card.
	public static let privacyPolicy: URL = URL(string: "https://arxbrowser.net/privacy-policy")!

	/// The backend (`arx-browser-backend`): `POST /v1/feedback` and `/v1/accounts`.
	public static let backend: URL = URL(string: "https://api.arxbrowser.net")!

	/// GitHub's issue forms for the Arx repository, for someone who wants a public report.
	public static let publicIssueForms: URL = URL(string: "https://github.com/capturecontext/arx-browser/issues/new/choose")!

	/// The backend address the app uses: ``backend``, or `ARX_BACKEND_URL` when it's set to an
	/// `http` or `https` address, such as a local `pnpm dev` server at `http://127.0.0.1:3300`.
	public static func backendURL(
		environment: [String: String] = ProcessInfo.processInfo.environment
	) -> URL {
		guard
			let value = environment["ARX_BACKEND_URL"]?.trimmingCharacters(in: .whitespaces),
			let url = URL(string: value),
			let scheme = url.scheme?.lowercased(),
			scheme == "http" || scheme == "https",
			url.host() != nil
		else { return backend }

		return url
	}
}
