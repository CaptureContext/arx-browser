import Foundation

/// A security component the engine keeps updating from Google's component service
/// (DEV-874), and the version it uses.
public struct BrowserSecurityComponent: Equatable, Identifiable, Sendable {
	public enum Kind: String, CaseIterable, Sendable {
		/// The CRLSet: certificates revoked since the build.
		case revocationList

		/// Certificate Transparency logs, the Chrome Root Store and key pins.
		case pkiMetadata

		/// The explanations on certificate error pages.
		case certificateErrorAssistant

		/// Where Chromium installs it, inside the engine's user data directory.
		public var directoryName: String {
			switch self {
			case .revocationList: "CertificateRevocation"
			case .pkiMetadata: "PKIMetadata"
			case .certificateErrorAssistant: "SSLErrorAssistant"
			}
		}
	}

	public var id: Kind { kind }

	public let kind: Kind

	/// `nil` until the first download finishes.
	public let version: String?

	/// When that version was installed: its version directory's modification date.
	public let installed: Date?

	public init(
		kind: Kind,
		version: String?,
		installed: Date?
	) {
		self.kind = kind
		self.version = version
		self.installed = installed
	}
}

extension BrowserSecurityComponent {
	/// Each component's newest installed version under the engine's user data directory.
	///
	/// Chromium keeps one directory per version, named after it, holding a `manifest.json`;
	/// it loads the newest and removes the older ones after an update.
	public static func installed(
		in userDataDirectory: URL,
		fileManager: FileManager = .default
	) -> [BrowserSecurityComponent] {
		Kind.allCases.map { kind in
			let directory = userDataDirectory.appendingPathComponent(kind.directoryName, isDirectory: true)
			let versions = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
			let newest = versions
				.compactMap { name in Version(name).map { (name: name, version: $0) } }
				.filter { candidate in
					fileManager.fileExists(
						atPath: directory
							.appendingPathComponent(candidate.name, isDirectory: true)
							.appendingPathComponent("manifest.json")
							.path
					)
				}
				.max { $0.version < $1.version }

			guard let newest
			else { return .init(kind: kind, version: nil, installed: nil) }

			// The unpacked files keep the package's own timestamps; the version directory
			// is the one Chromium made here while installing it.
			let versionDirectory = directory.appendingPathComponent(newest.name, isDirectory: true)
			let attributes = try? fileManager.attributesOfItem(atPath: versionDirectory.path)
			return .init(
				kind: kind,
				version: newest.name,
				installed: attributes?[.modificationDate] as? Date
			)
		}
	}

	/// A component version: dot-separated non-negative integers, compared numerically.
	private struct Version: Comparable {
		internal let components: [Int]

		internal init?(_ name: String) {
			let parts = name.split(separator: ".", omittingEmptySubsequences: false)
			guard
				!parts.isEmpty,
				parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) })
			else { return nil }

			let components = parts.compactMap { Int($0) }
			guard components.count == parts.count
			else { return nil }

			self.components = components
		}

		internal static func < (lhs: Self, rhs: Self) -> Bool {
			for index in 0..<max(lhs.components.count, rhs.components.count) {
				let left = index < lhs.components.count ? lhs.components[index] : 0
				let right = index < rhs.components.count ? rhs.components[index] : 0
				if left != right { return left < right }
			}
			return false
		}
	}
}

extension Character {
	fileprivate var isASCIIDigit: Bool {
		isASCII && isNumber
	}
}
