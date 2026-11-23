import Foundation

/// The elements hidden on sites in a profile (DEV-1019), by hostname: each a line of uBlock
/// Origin's My filters, such as `example.com##.banner`, which Hide Element's picker wrote.
public struct BrowserHiddenElements: Equatable, Sendable {
	public var sites: [String: [String]]

	public init(sites: [String: [String]] = [:]) {
		self.sites = sites
	}

	/// The filters that hide elements on `host`: its own and its parent domains', as uBlock
	/// applies them, in My filters' order, each once.
	public func filters(for host: String) -> [String] {
		var labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
		var filters: [String] = []
		while !labels.isEmpty {
			for filter in sites[labels.joined(separator: ".")] ?? [] where !filters.contains(filter) {
				filters.append(filter)
			}
			labels.removeFirst()
		}
		return filters
	}

	/// What a filter hides, for the site menu: its selector, without the sites before `##`.
	public static func selector(of filter: String) -> String {
		guard let range = filter.range(of: "##") else { return filter }
		return String(filter[range.upperBound...])
	}
}
