import Foundation
import Security

/// Whether this process's signature grants an iCloud container (DEV-1013).
///
/// A signed Arx Dev built before its provisioning profile exists is signed without iCloud, and
/// CloudKit stops a process that opens a container it isn't entitled to. Unsigned builds have no
/// entitlements either.
public enum ICloudEntitlement {
	public static let key: String = "com.apple.developer.icloud-container-identifiers"

	public static func grants(_ containerIdentifier: String) -> Bool {
		guard
			let task = SecTaskCreateFromSelf(nil),
			let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
		else { return false }

		return (value as? [String])?.contains(containerIdentifier) == true
	}
}
