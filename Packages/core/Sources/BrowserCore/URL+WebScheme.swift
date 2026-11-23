import Foundation

extension URL {
	/// Whether the address is http or https, in any case. Says nothing about its host.
	public var hasWebScheme: Bool {
		["http", "https"].contains(scheme?.lowercased())
	}
}
