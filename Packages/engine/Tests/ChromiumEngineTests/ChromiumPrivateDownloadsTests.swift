import ChromiumBridge
import Foundation
import Testing

@testable
import ChromiumEngine

/// ABI45 (DEV-729). A private profile can follow the downloads of the profile that opened it.
@MainActor
@Suite(.serialized)
internal struct ChromiumPrivateDownloadsTests {
	@MainActor
	private enum Calls {
		internal static var plain: [String] = []
		internal static var linked: [(String, String)] = []
	}

	@Test
	internal func openerKeyReachesNativeAndDefaultIsTheEmptyKey() throws {
		Calls.plain = []
		Calls.linked = []
		var api = ArxEngineAPI()
		api.prepare_private_profile = { key in
			MainActor.assumeIsolated { Calls.plain.append(String(cString: key!)) }
			return true
		}
		api.prepare_private_profile_for = { key, opener in
			MainActor.assumeIsolated {
				Calls.linked.append((String(cString: key!), String(cString: opener!)))
			}
			return true
		}
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }

		let opener = UUID()
		let first = UUID()
		let second = UUID()
		try runtime.preparePrivateProfile(first, followingDownloadsOf: opener)
		try runtime.preparePrivateProfile(second, followingDownloadsOf: nil)

		#expect(Calls.plain.isEmpty)
		#expect(Calls.linked.map(\.0) == [first, second].map { $0.uuidString.lowercased() })
		#expect(Calls.linked.map(\.1) == [opener.uuidString.lowercased(), ""])

		// A private profile can't be an opener; native isn't asked.
		#expect(throws: ChromiumError.self) {
			try runtime.preparePrivateProfile(UUID(), followingDownloadsOf: first)
		}
		#expect(Calls.linked.count == 2)
	}

	@Test
	internal func enginesWithoutTheEntryPrepareWithoutFollowing() throws {
		Calls.plain = []
		Calls.linked = []
		var api = ArxEngineAPI()
		api.prepare_private_profile = { key in
			MainActor.assumeIsolated { Calls.plain.append(String(cString: key!)) }
			return true
		}
		let runtime = ChromiumRuntime(api: api)
		runtime.didBecomeReady()
		defer { runtime.finish() }

		let profile = UUID()
		try runtime.preparePrivateProfile(profile, followingDownloadsOf: UUID())

		#expect(Calls.plain == [profile.uuidString.lowercased()])
		#expect(Calls.linked.isEmpty)
	}
}
