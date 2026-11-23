import BrowserAutomationClient
import BrowserCore
@testable import BrowserMCPServer
import Foundation
import MCP
import Testing

/// DEV-934: tool results are built with `Value(encoding:)`, which must give exactly what the
/// SDK's `Value(_:)` gives, much faster.
internal struct AutomationValueEncodingTests {
	private struct Sample: Codable {
		internal var flag: Bool = true
		internal var off: Bool = false
		internal var count: Int = 42
		internal var negative: Int = -7
		internal var ratio: Double = 0.25
		internal var whole: Double = 2.0
		internal var large: Double = 1e20
		internal var unsigned: UInt64 = .max
		internal var text: String = "Ünïcödé \"quoted\" text"
		internal var missing: String? = nil
		internal var list: [Int] = [1, 2, 3]
		internal var nested: [String: [String: [Bool]]] = ["a": ["b": [true]]]
		internal var date: Date = .init(timeIntervalSinceReferenceDate: 1_000.5)
		internal var empty: [String] = []
	}

	@Test
	internal func matchesTheSDKForEveryKindOfValue() async throws {
		let sample = Sample()
		try expectSame(try Value(encoding: sample), try Value(sample))
		try expectSame(try Value(encoding: [sample, sample]), try Value([sample, sample]))
		try expectSame(try Value(encoding: "fragment"), Value("fragment"))
		try expectSame(try Value(encoding: 3), Value(3))
	}

	@Test
	internal func passesAValueThrough() async throws {
		let value: Value = .object(["kind": .string("inventory"), "data": .data(mimeType: "text/plain", Data("a".utf8))])
		#expect(try Value(encoding: value) == value)
	}

	@Test
	internal func matchesTheSDKForAnInventoryPage() async throws {
		let profile = Profile.ID(rawValue: UUID())
		let space = Space.ID(rawValue: UUID())
		let tabs: [BrowserCore.Tab] = (0 ..< 100).map { index in
			.init(
				id: .init(rawValue: UUID()),
				profileID: profile,
				restoration: .init(title: "Page \(index)", url: URL(string: "https://capturecontext.dev/\(index)")!)
			)
		}
		let organization = BrowserOrganization(
			profiles: [.init(id: profile, name: "Default")],
			spaces: [.init(id: space, profileID: profile, name: "Work", unpinnedTabs: tabs.map(\.id))],
			tabs: tabs
		)
		let client = AutomationClient(
			id: UUID(),
			name: "Client",
			credentialDigest: String(repeating: "0", count: 64),
			scopes: [.space(space, profileID: profile)],
			allowsRead: true,
			grantRevision: UUID()
		)
		let items = AutomationInventoryBuilder.items(client: client, organization: organization, snapshots: [:])
		#expect(items.count == 101)
		try expectSame(try Value(encoding: items), try Value(items))
	}

	/// Equal, and the same JSON text once keys are sorted.
	private func expectSame(
		_ fast: Value,
		_ sdk: Value,
		sourceLocation: SourceLocation = #_sourceLocation
	) throws {
		#expect(fast == sdk, sourceLocation: sourceLocation)
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		let fastText = try encoder.encode(fast)
		let sdkText = try encoder.encode(sdk)
		#expect(fastText == sdkText, sourceLocation: sourceLocation)
	}
}
